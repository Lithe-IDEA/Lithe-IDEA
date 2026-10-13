//! Opt-in loopback proxy between an API-key Agent and its model provider.
//!
//! The Agent receives `http://127.0.0.1:<port>/<launch token>` instead of the
//! configured endpoint. Every request is forwarded to that endpoint with the
//! Agent's own headers and body; responses stream back byte for byte. Only
//! generation requests are observed through [`crate::model_calls`]. The proxy
//! never stores, logs or emits request content or credentials, binds only the
//! loopback interface and rejects paths without the per-launch token. Its
//! lifetime is one Agent connection; it writes no files.
//! Decision: .agents/notes/implemented/architecture/2026-10-13-agent-model-call-observation.md

use std::convert::Infallible;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use bytes::Bytes;
use futures::{Stream, StreamExt};
use http_body_util::{combinators::UnsyncBoxBody, BodyExt, Full, Limited, StreamBody};
use hyper::body::{Frame, Incoming};
use hyper::header::{HeaderMap, HeaderName, HeaderValue};
use hyper::{Request, Response, StatusCode};

use crate::model_calls::{self, ModelApi, ModelCall, RequestShape, ResponseObserver};

/// Request bodies are buffered to measure their composition. Agents send
/// conversation history, images and tool definitions, which stay far below this.
const MAX_REQUEST_BYTES: usize = 256 * 1024 * 1024;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);

/// Headers that describe one hop and must not be forwarded (RFC 9110 §7.6.1),
/// plus fields the forwarding client recomputes for the upstream request.
const HOP_HEADERS: [&str; 10] = [
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "proxy-connection",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
    "host",
];

/// Called once per completed or abandoned generation request, with the
/// session that had the only running prompt when the request started.
pub(crate) type CallSink = Arc<dyn Fn(Option<String>, ModelCall) + Send + Sync>;
/// Resolves the session a new request belongs to, or `None` when ambiguous.
pub(crate) type SessionResolver = Arc<dyn Fn() -> Option<String> + Send + Sync>;

/// A running proxy. Dropping it stops accepting connections and aborts
/// in-flight exchanges together with the Agent connection that used them.
pub(crate) struct ModelCallProxy {
    base_url: String,
    accept: tokio::task::JoinHandle<()>,
    connections: Arc<Mutex<tokio::task::JoinSet<()>>>,
}

impl ModelCallProxy {
    /// Base URL to hand to the Agent in place of the configured endpoint.
    pub(crate) fn base_url(&self) -> &str {
        &self.base_url
    }
}

impl Drop for ModelCallProxy {
    fn drop(&mut self) {
        self.accept.abort();
        if let Ok(mut connections) = self.connections.lock() {
            connections.abort_all();
        }
    }
}

struct State {
    /// Path prefix the Agent must use, e.g. `/lithe-<uuid>`.
    prefix: String,
    /// Configured endpoint without a trailing slash.
    upstream: String,
    client: reqwest::Client,
    session: SessionResolver,
    sink: CallSink,
}

/// Bind an ephemeral loopback port and forward to `upstream`.
pub(crate) async fn start(
    upstream: &str,
    session: SessionResolver,
    sink: CallSink,
) -> Result<ModelCallProxy, String> {
    let client = reqwest::Client::builder()
        .connect_timeout(CONNECT_TIMEOUT)
        // Redirects and compression are the Agent's concern; forward them as-is.
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|error| format!("Could not prepare model call statistics: {error}"))?;
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .map_err(|error| format!("Could not start model call statistics: {error}"))?;
    let port = listener
        .local_addr()
        .map_err(|error| format!("Could not start model call statistics: {error}"))?
        .port();
    let prefix = format!("/lithe-{}", uuid::Uuid::new_v4().simple());
    let state = Arc::new(State {
        prefix: prefix.clone(),
        upstream: upstream.trim_end_matches('/').to_owned(),
        client,
        session,
        sink,
    });
    let connections = Arc::new(Mutex::new(tokio::task::JoinSet::new()));
    let accepted = connections.clone();
    let accept = tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                continue;
            };
            let state = state.clone();
            let service = hyper::service::service_fn(move |request| handle(request, state.clone()));
            let connection = async move {
                let _ = hyper::server::conn::http1::Builder::new()
                    .serve_connection(hyper_util::rt::TokioIo::new(stream), service)
                    .await;
            };
            if let Ok(mut connections) = accepted.lock() {
                // Reap finished exchanges so a long session does not accumulate handles.
                while connections.try_join_next().is_some() {}
                connections.spawn(connection);
            }
        }
    });
    Ok(ModelCallProxy {
        base_url: format!("http://127.0.0.1:{port}{prefix}"),
        accept,
        connections,
    })
}

type ProxyBody = UnsyncBoxBody<Bytes, Box<dyn std::error::Error + Send + Sync>>;

async fn handle(
    request: Request<Incoming>,
    state: Arc<State>,
) -> Result<Response<ProxyBody>, Infallible> {
    let path = request
        .uri()
        .path_and_query()
        .map(|value| value.as_str())
        .unwrap_or("/");
    let Some(rest) = path
        .strip_prefix(&state.prefix)
        .filter(|rest| rest.is_empty() || rest.starts_with(['/', '?']))
    else {
        return Ok(failure(StatusCode::NOT_FOUND, "Unknown model call route"));
    };
    let url = format!("{}{rest}", state.upstream);
    let api = (request.method() == hyper::Method::POST)
        .then(|| ModelApi::from_path(rest))
        .flatten();
    let method = request.method().clone();
    let compressed_request = request
        .headers()
        .contains_key(hyper::header::CONTENT_ENCODING);
    let headers = forwarded_headers(request.headers(), api.is_some());
    let body = match Limited::new(request.into_body(), MAX_REQUEST_BYTES)
        .collect()
        .await
    {
        Ok(body) => body.to_bytes(),
        Err(_) => {
            return Ok(failure(
                StatusCode::PAYLOAD_TOO_LARGE,
                "The model request is too large to forward",
            ))
        }
    };
    let shape = api
        .filter(|_| !compressed_request)
        .and_then(|api| model_calls::request_shape(api, &body));
    let session = api.and_then(|_| (state.session)());
    let started = Instant::now();
    let upstream = state
        .client
        .request(method, &url)
        .headers(headers)
        .body(body)
        .send()
        .await;
    let upstream = match upstream {
        Ok(response) => response,
        Err(error) => {
            if let Some(api) = api {
                let observer =
                    ResponseObserver::new(api, StatusCode::BAD_GATEWAY.as_u16(), false, started);
                (state.sink)(session, observer.finish(shape.as_ref(), Instant::now()));
            }
            // reqwest errors carry the URL and cause, never request headers.
            return Ok(failure(
                StatusCode::BAD_GATEWAY,
                &format!("Lithe could not reach the model provider: {error}"),
            ));
        }
    };
    let status = upstream.status();
    let mut response = Response::builder().status(status);
    let streaming = upstream
        .headers()
        .get(hyper::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.starts_with("text/event-stream"));
    if let Some(headers) = response.headers_mut() {
        for (name, value) in upstream.headers() {
            if !is_hop_header(name) {
                headers.append(name.clone(), value.clone());
            }
        }
    }
    let stream = upstream.bytes_stream();
    let body: ProxyBody = match api {
        Some(api) => {
            let observed = ObservedStream {
                inner: stream.boxed(),
                observer: Some(ResponseObserver::new(
                    api,
                    status.as_u16(),
                    streaming,
                    started,
                )),
                shape,
                session,
                sink: state.sink.clone(),
            };
            BodyExt::boxed_unsync(StreamBody::new(
                observed.map(|chunk| chunk.map(Frame::data)),
            ))
        }
        None => BodyExt::boxed_unsync(StreamBody::new(stream.map(|chunk| {
            chunk
                .map(Frame::data)
                .map_err(|error| Box::new(error) as Box<dyn std::error::Error + Send + Sync>)
        }))),
    };
    Ok(response.body(body).unwrap_or_else(|_| {
        failure(
            StatusCode::BAD_GATEWAY,
            "Lithe could not forward the model response",
        )
    }))
}

/// Copy the Agent's headers. For observed calls, ask for an identity-encoded
/// response so usage events remain readable; the content is unchanged.
fn forwarded_headers(source: &HeaderMap, observed: bool) -> HeaderMap {
    let mut headers = HeaderMap::with_capacity(source.len());
    for (name, value) in source {
        if !is_hop_header(name) && name != hyper::header::CONTENT_LENGTH {
            headers.append(name.clone(), value.clone());
        }
    }
    if observed {
        headers.insert(
            hyper::header::ACCEPT_ENCODING,
            HeaderValue::from_static("identity"),
        );
    }
    headers
}

fn is_hop_header(name: &HeaderName) -> bool {
    HOP_HEADERS.contains(&name.as_str())
}

fn failure(status: StatusCode, message: &str) -> Response<ProxyBody> {
    // Use the provider error envelope shape both Anthropic and OpenAI clients read.
    let body = serde_json::json!({"error": {"type": "api_error", "message": message}}).to_string();
    let mut response = Response::new(BodyExt::boxed_unsync(
        Full::new(Bytes::from(body)).map_err(|never| match never {}),
    ));
    *response.status_mut() = status;
    response.headers_mut().insert(
        hyper::header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    );
    response
}

/// Forwards upstream chunks unchanged while feeding the observer. The call is
/// reported at end of stream, upstream error, or when the Agent disconnects.
struct ObservedStream {
    inner: futures::stream::BoxStream<'static, reqwest::Result<Bytes>>,
    observer: Option<ResponseObserver>,
    shape: Option<RequestShape>,
    session: Option<String>,
    sink: CallSink,
}

impl ObservedStream {
    fn report(&mut self) {
        if let Some(observer) = self.observer.take() {
            (self.sink)(
                self.session.take(),
                observer.finish(self.shape.as_ref(), Instant::now()),
            );
        }
    }
}

impl Stream for ObservedStream {
    type Item = Result<Bytes, Box<dyn std::error::Error + Send + Sync>>;

    fn poll_next(mut self: Pin<&mut Self>, context: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        match self.inner.poll_next_unpin(context) {
            Poll::Ready(Some(Ok(chunk))) => {
                if let Some(observer) = self.observer.as_mut() {
                    observer.feed(&chunk, Instant::now());
                }
                Poll::Ready(Some(Ok(chunk)))
            }
            Poll::Ready(Some(Err(error))) => {
                self.report();
                Poll::Ready(Some(Err(Box::new(error))))
            }
            Poll::Ready(None) => {
                self.report();
                Poll::Ready(None)
            }
            Poll::Pending => Poll::Pending,
        }
    }
}

impl Drop for ObservedStream {
    fn drop(&mut self) {
        self.report();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    /// Minimal HTTP/1.1 upstream that records one request and replies with `reply`.
    async fn upstream(reply: &'static str) -> (String, tokio::task::JoinHandle<String>) {
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        let address = listener.local_addr().unwrap();
        let task = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut received = Vec::new();
            let mut buffer = [0u8; 4096];
            // Read headers, then the declared body length.
            loop {
                let read = stream.read(&mut buffer).await.unwrap();
                received.extend_from_slice(&buffer[..read]);
                let text = String::from_utf8_lossy(&received).to_string();
                if let Some(end) = text.find("\r\n\r\n") {
                    let length = text[..end]
                        .lines()
                        .find_map(|line| {
                            line.to_ascii_lowercase()
                                .strip_prefix("content-length:")
                                .map(|value| value.trim().parse::<usize>().unwrap())
                        })
                        .unwrap_or(0);
                    if received.len() >= end + 4 + length || read == 0 {
                        break;
                    }
                }
            }
            stream.write_all(reply.as_bytes()).await.unwrap();
            stream.shutdown().await.unwrap();
            String::from_utf8_lossy(&received).to_string()
        });
        (format!("http://{address}/api"), task)
    }

    async fn send(base: &str, path: &str, body: &str) -> (u16, String) {
        let client = reqwest::Client::new();
        let response = client
            .post(format!("{base}{path}"))
            .header("x-api-key", "secret-key")
            .header("content-type", "application/json")
            .body(body.to_owned())
            .send()
            .await
            .unwrap();
        (response.status().as_u16(), response.text().await.unwrap())
    }

    /// Calls reported by the proxy, in completion order.
    type Collected = Arc<Mutex<Vec<(Option<String>, ModelCall)>>>;

    fn collecting() -> (CallSink, Collected) {
        let calls = Arc::new(Mutex::new(Vec::new()));
        let sink = calls.clone();
        (
            Arc::new(move |session, call| sink.lock().unwrap().push((session, call))),
            calls,
        )
    }

    #[tokio::test]
    async fn streams_are_forwarded_unchanged_and_observed() {
        let stream = "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":5,\"output_tokens\":1}}}\n\ndata: {\"type\":\"content_block_delta\"}\n\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":9}}\n\n";
        let reply: &'static str = Box::leak(format!(
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nretry-after: 7\r\ncontent-length: {}\r\n\r\n{stream}",
            stream.len()
        ).into_boxed_str());
        let (base, request) = upstream(reply).await;
        let (sink, calls) = collecting();
        let proxy = start(&base, Arc::new(|| Some("session-1".into())), sink)
            .await
            .unwrap();
        let (status, body) = send(
            proxy.base_url(),
            "/v1/messages",
            r#"{"model":"m","messages":[]}"#,
        )
        .await;
        assert_eq!((status, body.as_str()), (200, stream));
        let request = request.await.unwrap();
        // The Agent's credentials and body reach the configured path unchanged.
        assert!(request.starts_with("POST /api/v1/messages HTTP/1.1"));
        assert!(request
            .to_ascii_lowercase()
            .contains("x-api-key: secret-key"));
        assert!(request.ends_with(r#"{"model":"m","messages":[]}"#));
        drop(proxy);
        let calls = calls.lock().unwrap();
        assert_eq!(calls.len(), 1);
        let (session, call) = &calls[0];
        assert_eq!(session.as_deref(), Some("session-1"));
        assert!(call.streaming);
        assert_eq!(call.model.as_deref(), Some("m"));
        assert_eq!(call.usage.map(|usage| usage.output_tokens), Some(9));
    }

    #[tokio::test]
    async fn auxiliary_requests_and_foreign_paths_are_not_observed() {
        let (base, request) =
            upstream("HTTP/1.1 404 Not Found\r\ncontent-length: 2\r\n\r\n{}").await;
        let (sink, calls) = collecting();
        let proxy = start(&base, Arc::new(|| None), sink).await.unwrap();
        let (status, _) = send(proxy.base_url(), "/v1/messages/count_tokens", "{}").await;
        assert_eq!(status, 404);
        request.await.unwrap();
        // Without the per-launch token another local process cannot use the route.
        let origin = proxy.base_url().rsplit_once('/').unwrap().0.to_owned();
        let (status, body) = send(&origin, "/v1/messages", "{}").await;
        assert_eq!(status, 404);
        assert!(body.contains("Unknown model call route"));
        assert!(calls.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn unreachable_providers_return_an_error_envelope_and_a_failed_call() {
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        let closed = format!("http://{}", listener.local_addr().unwrap());
        drop(listener);
        let (sink, calls) = collecting();
        let proxy = start(&closed, Arc::new(|| None), sink).await.unwrap();
        let (status, body) = send(proxy.base_url(), "/v1/responses", "{}").await;
        assert_eq!(status, 502);
        assert!(body.contains("\"api_error\""));
        assert!(!body.contains("secret-key"));
        assert_eq!(calls.lock().unwrap()[0].1.status, 502);
    }
}
