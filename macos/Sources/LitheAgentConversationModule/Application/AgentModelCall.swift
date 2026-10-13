import Foundation

/// One provider request observed by the Host's opt-in loopback proxy.
/// Shape fixed by the `modelCall` event in `shared/fixtures/agent/acp-events-v1.json`.
public struct AgentModelCall: Decodable, Equatable, Sendable {
    /// Provider counters normalized to disjoint input buckets.
    public struct Usage: Decodable, Equatable, Sendable {
        public let inputTokens: UInt64
        public let cacheReadTokens: UInt64
        public let cacheWriteTokens: UInt64
        public let outputTokens: UInt64
        public let reasoningTokens: UInt64?

        public var promptTokens: UInt64 { inputTokens + cacheReadTokens + cacheWriteTokens }
    }

    /// Estimated split of the request prompt; see `scaledToUsage`.
    public struct Context: Decodable, Equatable, Sendable {
        public let systemPromptTokens: UInt64
        public let toolTokens: UInt64
        public let mcpToolTokens: UInt64
        public let messageTokens: UInt64
        public let toolCount: Int
        public let mcpToolCount: Int
        /// Section sizes were scaled to the provider's prompt counters rather
        /// than approximated from byte length.
        public let scaledToUsage: Bool

        public var totalTokens: UInt64 { systemPromptTokens + toolTokens + mcpToolTokens + messageTokens }
    }

    public let api: String
    public let model: String?
    public let status: Int
    public let streaming: Bool
    public let firstTokenMs: UInt64?
    public let durationMs: UInt64
    public let usage: Usage?
    public let context: Context?

    static func parse(_ value: Any?) -> Self? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// Bounded aggregate of observed model calls for a turn or a session.
public struct AgentModelCallTotals: Equatable, Sendable {
    public private(set) var callCount = 0
    public private(set) var failedCount = 0
    public private(set) var nonStreamingCount = 0
    /// Sum of complete request durations, including time to first token.
    public private(set) var duration: TimeInterval = 0
    public private(set) var inputTokens: UInt64 = 0
    public private(set) var cacheReadTokens: UInt64 = 0
    public private(set) var cacheWriteTokens: UInt64 = 0
    public private(set) var outputTokens: UInt64 = 0
    public private(set) var reasoningTokens: UInt64?
    public private(set) var hasUsage = false
    /// Composition of the latest main-loop request, i.e. one that carried tools.
    public private(set) var latestContext: AgentModelCall.Context?
    private var firstTokenTotal: TimeInterval = 0
    private var firstTokenCount = 0
    /// Streaming time after the first token, and the output produced in it.
    private var generationTime: TimeInterval = 0
    private var generatedTokens: UInt64 = 0

    public init() {}

    public var averageFirstToken: TimeInterval? {
        firstTokenCount > 0 ? firstTokenTotal / Double(firstTokenCount) : nil
    }

    /// Output rate while streaming, excluding the wait for the first token.
    public var outputTokensPerSecond: Double? {
        generationTime > 0 && generatedTokens > 0 ? Double(generatedTokens) / generationTime : nil
    }

    mutating func record(_ call: AgentModelCall) {
        callCount += 1
        if call.status >= 400 { failedCount += 1 }
        if !call.streaming && call.status < 400 { nonStreamingCount += 1 }
        let duration = Double(call.durationMs) / 1000
        self.duration += duration
        if let usage = call.usage {
            hasUsage = true
            inputTokens += usage.inputTokens
            cacheReadTokens += usage.cacheReadTokens
            cacheWriteTokens += usage.cacheWriteTokens
            outputTokens += usage.outputTokens
            if let reasoning = usage.reasoningTokens { reasoningTokens = (reasoningTokens ?? 0) + reasoning }
        }
        if call.streaming, let firstToken = call.firstTokenMs.map({ Double($0) / 1000 }) {
            firstTokenTotal += firstToken
            firstTokenCount += 1
            if let output = call.usage?.outputTokens, duration > firstToken {
                generationTime += duration - firstToken
                generatedTokens += output
            }
        }
        // Auxiliary requests such as title generation carry no tools and must
        // not replace the main conversation's composition.
        if let context = call.context, context.toolCount + context.mcpToolCount > 0 || latestContext == nil {
            latestContext = context
        }
    }
}
