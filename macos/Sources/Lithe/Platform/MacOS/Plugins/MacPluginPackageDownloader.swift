import CryptoKit
import Darwin
import Foundation
import LitheModuleAPI

struct MacDownloadedPluginPackage {
    let packageURL: URL
    let temporaryDirectory: URL
}

/// Downloads a marketplace archive, checks it against the index checksum,
/// and extracts it into a private temporary directory. The package store
/// still validates the declaration, trust, and executables before install.
protocol MacPluginPackageDownloading {
    func download(
        archiveURL: URL,
        expectedSHA256: String,
        pluginID: PluginID
    ) async throws -> MacDownloadedPluginPackage
}

enum MacPluginPackageDownloadError: Error, Equatable, LocalizedError {
    case invalidEndpoint
    case httpStatus(Int)
    case archiveTooLarge(Int64)
    /// `plugin.archive.checksumMismatch`
    case checksumMismatch(expected: String, actual: String)
    case invalidArchive
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The plugin download address is invalid."
        case .httpStatus(let status):
            return "The plugin server returned HTTP \(status)."
        case .archiveTooLarge(let limit):
            return "The plugin archive is larger than \(limit / 1_048_576) MB."
        case .checksumMismatch(let expected, let actual):
            return "The downloaded plugin archive does not match the plugin repository (SHA-256 \(actual), expected \(expected))."
        case .invalidArchive:
            return "The downloaded plugin archive does not contain a valid plugin package."
        case .extractionFailed(let detail):
            return "The downloaded plugin archive could not be extracted: \(detail)"
        }
    }
}

/// Where marketplace HTTPS requests go. Production uses URLSession; debug
/// verification builds may map them onto a local fixture mirror.
protocol MacPluginMarketplaceTransport: Sendable {
    func data(from url: URL, maximumBytes: Int64) async throws -> Data
    /// Downloads to a temporary file owned by the caller.
    func download(from url: URL, maximumBytes: Int64) async throws -> URL
}

struct MacURLSessionPluginMarketplaceTransport: MacPluginMarketplaceTransport {
    private static let requestTimeout: TimeInterval = 60
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(from url: URL, maximumBytes: Int64) async throws -> Data {
        let fileURL = try await download(from: url, maximumBytes: maximumBytes)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        return try Data(contentsOf: fileURL)
    }

    func download(from url: URL, maximumBytes: Int64) async throws -> URL {
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            throw MacPluginPackageDownloadError.invalidEndpoint
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = Self.requestTimeout
        let (fileURL, response) = try await session.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            try? FileManager.default.removeItem(at: fileURL)
            throw MacPluginPackageDownloadError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size <= maximumBytes else {
            try? FileManager.default.removeItem(at: fileURL)
            throw MacPluginPackageDownloadError.archiveTooLarge(maximumBytes)
        }
        // URLSession deletes its file when this call returns, so hand the
        // caller a copy it owns.
        let owned = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-plugin-transfer-\(UUID().uuidString)", isDirectory: false)
        try FileManager.default.moveItem(at: fileURL, to: owned)
        return owned
    }
}

final class MacPluginPackageDownloader: MacPluginPackageDownloading {
    static let maximumArchiveBytes: Int64 = 512 * 1_048_576
    private static let extractionTimeout: TimeInterval = 5 * 60
    private static let extractionPollInterval: TimeInterval = 0.05
    private let transport: any MacPluginMarketplaceTransport
    private let fileManager: FileManager
    private let temporaryDirectory: URL

    init(
        transport: any MacPluginMarketplaceTransport = MacURLSessionPluginMarketplaceTransport(),
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.transport = transport
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
    }

    func download(
        archiveURL: URL,
        expectedSHA256: String,
        pluginID: PluginID
    ) async throws -> MacDownloadedPluginPackage {
        try Task.checkCancellation()
        let archiveOnDisk = try await transport.download(from: archiveURL, maximumBytes: Self.maximumArchiveBytes)
        defer { try? fileManager.removeItem(at: archiveOnDisk) }
        // The checksum comes from the index the user browsed; nothing from an
        // archive that does not match it is extracted.
        let actual = try Self.sha256(of: archiveOnDisk)
        guard actual == expectedSHA256.lowercased() else {
            throw MacPluginPackageDownloadError.checksumMismatch(expected: expectedSHA256, actual: actual)
        }
        try Task.checkCancellation()

        let extractionRoot = temporaryDirectory
            .appendingPathComponent("lithe-plugin-download-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
        do {
            try extract(archiveOnDisk, into: extractionRoot)
            let packageURL = try Self.findPackage(in: extractionRoot, pluginID: pluginID, fileManager: fileManager)
            return MacDownloadedPluginPackage(
                packageURL: packageURL,
                temporaryDirectory: extractionRoot
            )
        } catch {
            try? fileManager.removeItem(at: extractionRoot)
            throw error
        }
    }

    /// Streams the file so a large archive is never held in memory at once.
    static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func extract(_ archiveURL: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, directory.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw MacPluginPackageDownloadError.extractionFailed(error.localizedDescription)
        }
        // `ditto` is an external process, so waiting without a local deadline
        // would leave a cancelled or wedged download task alive indefinitely.
        // Poll on a bounded interval and terminate the process before
        // propagating cancellation or timeout to the caller.
        let deadline = Date().addingTimeInterval(Self.extractionTimeout)
        while process.isRunning {
            do {
                try Task.checkCancellation()
            } catch {
                terminateExtractionProcess(process)
                throw error
            }
            guard Date() < deadline else {
                terminateExtractionProcess(process)
                throw MacPluginPackageDownloadError.extractionFailed(
                    "ditto did not finish within \(Int(Self.extractionTimeout)) seconds"
                )
            }
            Thread.sleep(forTimeInterval: Self.extractionPollInterval)
        }
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MacPluginPackageDownloadError.extractionFailed(detail ?? "ditto exited with status \(process.terminationStatus)")
        }
    }

    private func terminateExtractionProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: Self.extractionPollInterval)
        }
        if process.isRunning {
            process.interrupt()
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    /// Identifies the package by its `id` only. Any manifest schema is
    /// accepted here; the package store owns schema, signature, and trust
    /// validation, so a declarative (schema 2) package is found as reliably
    /// as a retired native one.
    static func findPackage(in root: URL, pluginID: PluginID, fileManager: FileManager = .default) throws -> URL {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw MacPluginPackageDownloadError.invalidArchive
        }
        var matches: [URL] = []
        for case let candidate as URL in enumerator {
            guard candidate.lastPathComponent == "plugin.json",
                  let isDirectory = try? candidate.deletingLastPathComponent()
                    .resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                  isDirectory == true else { continue }
            let packageURL = candidate.deletingLastPathComponent().standardizedFileURL
            guard let data = try? Data(contentsOf: candidate),
                  let identity = try? JSONDecoder().decode(PackageIdentity.self, from: data),
                  identity.id == pluginID.rawValue else { continue }
            matches.append(packageURL)
        }
        guard matches.count == 1 else {
            throw MacPluginPackageDownloadError.invalidArchive
        }
        return matches[0]
    }

    private struct PackageIdentity: Decodable {
        let id: String
    }
}
