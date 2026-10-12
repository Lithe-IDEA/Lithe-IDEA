import Foundation
import LitheCoreContracts
import LitheModuleAPI
import Testing
@testable import Lithe

struct MacPluginPackageDownloaderTests {
    /// The release archive holds a declarative (schema 2) package. The
    /// downloader must verify the index checksum, find the package by `id`,
    /// and hand it to the package store, which performs the full validation.
    @Test
    func downloadedDeclarativePackageIsFoundAndInstallable() async throws {
        let root = PluginMarketplaceTestSupport.temporaryRoot("download")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("archive/dev.lithe.plugin.php-support", isDirectory: true)
        try DeclarativePluginTestSupport.writeOfficialPackage("PhpSupport", at: source)
        let archive = try PluginMarketplaceTestSupport.zip(source, to: root.appendingPathComponent("php.zip"))
        let downloader = MacPluginPackageDownloader(
            transport: PluginMarketplaceTestSupport.LocalFileTransport(files: [
                "https://github.com/Lithe-IDEA/Lithe-IDEA/releases/download/t/php.zip": archive
            ]),
            temporaryDirectory: root
        )

        let downloaded = try await downloader.download(
            archiveURL: URL(string: "https://github.com/Lithe-IDEA/Lithe-IDEA/releases/download/t/php.zip")!,
            expectedSHA256: try MacPluginPackageDownloader.sha256(of: archive),
            pluginID: OfficialPluginCatalog.phpPluginID
        )
        defer { try? FileManager.default.removeItem(at: downloaded.temporaryDirectory) }
        #expect(downloaded.packageURL.lastPathComponent == "dev.lithe.plugin.php-support")

        let store = MacPluginPackageStore(
            rootURL: root.appendingPathComponent("installed", isDirectory: true),
            validator: DeclarativePluginTestSupport.operations,
            verifier: MacOfficialPluginSignatureVerifier(
                trustedPublisherKeys: [:],
                allowsLocalDevelopmentPackages: true,
                hostBundleURL: root.appendingPathComponent("host/Lithe.app", isDirectory: true)
            )
        )
        let installed = try store.installPackage(from: downloaded.packageURL, origin: .localDevelopment)
        #expect(installed.descriptor.id == OfficialPluginCatalog.phpPluginID)
        #expect(installed.descriptor.pluginManifest.entrypoint.kind == .declarative)
    }

    /// Nothing from an archive that differs from the index is extracted.
    @Test
    func checksumMismatchIsRefusedBeforeExtraction() async throws {
        let root = PluginMarketplaceTestSupport.temporaryRoot("checksum")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("archive/dev.lithe.plugin.php-support", isDirectory: true)
        try DeclarativePluginTestSupport.writeOfficialPackage("PhpSupport", at: source)
        let archive = try PluginMarketplaceTestSupport.zip(source, to: root.appendingPathComponent("php.zip"))
        let extractionRoot = root.appendingPathComponent("extract", isDirectory: true)
        let url = "https://github.com/Lithe-IDEA/Lithe-IDEA/releases/download/t/php.zip"
        let downloader = MacPluginPackageDownloader(
            transport: PluginMarketplaceTestSupport.LocalFileTransport(files: [url: archive]),
            temporaryDirectory: extractionRoot
        )
        let expected = String(repeating: "0", count: 64)

        await #expect(throws: MacPluginPackageDownloadError.checksumMismatch(
            expected: expected,
            actual: try MacPluginPackageDownloader.sha256(of: archive)
        )) {
            _ = try await downloader.download(
                archiveURL: URL(string: url)!,
                expectedSHA256: expected,
                pluginID: OfficialPluginCatalog.phpPluginID
            )
        }
        #expect(!FileManager.default.fileExists(atPath: extractionRoot.path))
    }

    @Test
    func urlSessionTransportRefusesPlainHTTP() async {
        let transport = MacURLSessionPluginMarketplaceTransport()
        await #expect(throws: MacPluginPackageDownloadError.invalidEndpoint) {
            _ = try await transport.download(
                from: URL(string: "http://github.com/example/plugin.zip")!,
                maximumBytes: 1
            )
        }
    }
}
