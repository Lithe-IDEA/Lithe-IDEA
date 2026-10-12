import CryptoKit
import Foundation
@testable import Lithe
import LitheApplicationKernel
import LitheCoreContracts
import LitheModuleAPI
import LithePluginPackageSigning
import Testing

/// Exercises the production signature verifier with an injected publisher key
/// and an ad-hoc signed fixture bundle, covering the local development install
/// path that lets plugin authors test without the release key.
struct PluginLocalDevelopmentTests {
    @Test
    func publisherPackageSignedWithATrustedKeyIDIsAccepted() throws {
        let fixture = try PluginTrustFixture()
        defer { fixture.remove() }
        try fixture.signPackage(keyID: "test-publisher-v1")

        let verifier = MacOfficialPluginSignatureVerifier(
            trustedPublisherKeys: ["test-publisher-v1": fixture.privateKey.publicKey],
            allowsLocalDevelopmentPackages: false,
            hostBundleURL: fixture.hostBundleURL
        )

        try verifier.verify(packageAt: fixture.packageURL, manifest: fixture.manifest, origin: .marketplace)
    }

    @Test
    func publisherPackageSignedWithAnUnknownKeyIDIsRejected() throws {
        let fixture = try PluginTrustFixture()
        defer { fixture.remove() }
        try fixture.signPackage(keyID: "test-publisher-retired")

        let verifier = MacOfficialPluginSignatureVerifier(
            trustedPublisherKeys: ["test-publisher-v1": fixture.privateKey.publicKey],
            allowsLocalDevelopmentPackages: true,
            hostBundleURL: fixture.hostBundleURL
        )

        #expect(throws: PluginPackageStoreError.invalidPackageSignature(
            PluginPackageSignature.Error.untrustedKey("test-publisher-retired").localizedDescription
        )) {
            try verifier.verify(packageAt: fixture.packageURL, manifest: fixture.manifest, origin: .marketplace)
        }
    }

    @Test
    func unsignedPackageIsAcceptedOnlyAsALocalDevelopmentPackage() throws {
        let fixture = try PluginTrustFixture()
        defer { fixture.remove() }
        let developmentVerifier = MacOfficialPluginSignatureVerifier(
            trustedPublisherKeys: [:],
            allowsLocalDevelopmentPackages: true,
            hostBundleURL: fixture.hostBundleURL
        )

        try developmentVerifier.verify(
            packageAt: fixture.packageURL,
            manifest: fixture.manifest,
            origin: .localDevelopment
        )
        #expect(throws: PluginPackageStoreError.missingPackageSignature) {
            try developmentVerifier.verify(
                packageAt: fixture.packageURL,
                manifest: fixture.manifest,
                origin: .marketplace
            )
        }
    }

    @Test
    func releaseBuildsRejectLocalDevelopmentPackages() throws {
        let fixture = try PluginTrustFixture()
        defer { fixture.remove() }
        let releaseVerifier = MacOfficialPluginSignatureVerifier(
            trustedPublisherKeys: [:],
            allowsLocalDevelopmentPackages: false,
            hostBundleURL: fixture.hostBundleURL
        )

        #expect(throws: PluginPackageStoreError.developmentPackageNotAllowed(fixture.manifest.id)) {
            try releaseVerifier.verify(
                packageAt: fixture.packageURL,
                manifest: fixture.manifest,
                origin: .localDevelopment
            )
        }
    }

    @Test
    func developmentOriginDoesNotBypassAPresentPublisherSignature() throws {
        let fixture = try PluginTrustFixture()
        defer { fixture.remove() }
        try fixture.signPackage(keyID: "test-publisher-v1")
        try Data("changed".utf8).write(
            to: fixture.packageURL.appendingPathComponent("notes.txt"),
            options: .atomic
        )
        let verifier = MacOfficialPluginSignatureVerifier(
            trustedPublisherKeys: ["test-publisher-v1": fixture.privateKey.publicKey],
            allowsLocalDevelopmentPackages: true,
            hostBundleURL: fixture.hostBundleURL
        )

        #expect(throws: PluginPackageStoreError.invalidPackageSignature(
            PluginPackageSignature.Error.fileListMismatch.localizedDescription
        )) {
            try verifier.verify(
                packageAt: fixture.packageURL,
                manifest: fixture.manifest,
                origin: .localDevelopment
            )
        }
    }

    @Test
    func storeKeepsTheDevelopmentOriginAcrossRescans() throws {
        let fixture = try PluginTrustFixture()
        defer { fixture.remove() }
        let installedRoot = fixture.root.appendingPathComponent("installed", isDirectory: true)
        let developmentStore = MacPluginPackageStore(
            rootURL: installedRoot,
            verifier: MacOfficialPluginSignatureVerifier(
                trustedPublisherKeys: [:],
                allowsLocalDevelopmentPackages: true,
                hostBundleURL: fixture.hostBundleURL
            )
        )

        let installed = try developmentStore.installPackage(
            from: fixture.packageURL,
            origin: .localDevelopment
        )
        #expect(installed.installation.origin == .localDevelopment)
        let developmentScan = try developmentStore.scanInstalledPlugins()
        #expect(developmentScan.packages.map(\.installation.origin) == [.localDevelopment])
        #expect(developmentScan.issues.isEmpty)

        let releaseScan = try MacPluginPackageStore(
            rootURL: installedRoot,
            verifier: MacOfficialPluginSignatureVerifier(
                trustedPublisherKeys: [:],
                allowsLocalDevelopmentPackages: false,
                hostBundleURL: fixture.hostBundleURL
            )
        ).scanInstalledPlugins()
        #expect(releaseScan.packages.isEmpty)
        #expect(releaseScan.issues == [PluginPackageScanIssue(
            pluginID: fixture.manifest.id,
            message: PluginPackageStoreError.developmentPackageNotAllowed(fixture.manifest.id)
                .localizedDescription
        )])
    }

    @Test
    @MainActor
    func managerInstallsAnUnsignedDiskPackageAsADevelopmentPackage() throws {
        let fixture = try PluginTrustFixture()
        defer { fixture.remove() }
        let configuration = MacModuleConfigurationStore(store: PluginLocalDevelopmentKeyValueStore())
        let manager = MacPluginManager(
            packageStore: MacPluginPackageStore(
                rootURL: fixture.root.appendingPathComponent("installed", isDirectory: true),
                verifier: MacOfficialPluginSignatureVerifier(
                    trustedPublisherKeys: [:],
                    allowsLocalDevelopmentPackages: true,
                    hostBundleURL: fixture.hostBundleURL
                )
            ),
            moduleRuntime: ModuleRuntime(configurationStore: configuration, recoveryStore: configuration),
            configurationStore: configuration,
            launchMode: .normal,
            startup: MacPluginStartupResult(
                installedPlugins: [],
                activeNativeManifests: [],
                factoriesByPlugin: [:],
                issues: []
            ),
            allowsLocalDevelopmentPackages: true
        )

        try manager.installPackage(at: fixture.packageURL)
        // A rebuilt package with the same version replaces the previous one.
        try manager.installPackage(at: fixture.packageURL)

        let snapshot = try #require(manager.snapshots.first { $0.id == fixture.manifest.id })
        #expect(snapshot.origin == .localDevelopment)
        #expect(snapshot.requiresRestart)
    }
}

struct NodeLanguageToolEnvironmentTests {
    @Test
    func nodeFromVersionManagersIsDiscoveredNewestFirst() {
        let home = URL(fileURLWithPath: "/fixture-home", isDirectory: true)
        let executables: Set<String> = [
            "/fixture-home/.nvm/versions/node/v9.11.2/bin/node",
            "/fixture-home/.nvm/versions/node/v24.14.0/bin/node",
            "/fixture-home/.nvm/versions/node/v18.20.8/bin/node"
        ]
        let discovery = MacRuntimeToolDiscovery(
            homeDirectoryURL: home,
            resourceDirectoryURL: nil,
            isExecutable: { executables.contains($0.path) },
            directoryNames: { url in
                url.path == "/fixture-home/.nvm/versions/node"
                    ? ["v9.11.2", "v24.14.0", "notes", "v18.20.8"]
                    : []
            }
        )

        let candidates = discovery.candidates(for: "node", projectURL: nil, environment: ["PATH": "/usr/bin:/bin"])

        #expect(candidates.map(\.executableURL.path) == [
            "/fixture-home/.nvm/versions/node/v24.14.0/bin/node",
            "/fixture-home/.nvm/versions/node/v18.20.8/bin/node",
            "/fixture-home/.nvm/versions/node/v9.11.2/bin/node"
        ])
    }

    @Test
    @MainActor
    func languageToolEnvironmentCarriesTheDiscoveredNodeExecutable() {
        let node = URL(fileURLWithPath: "/fixture-tools/node")
        let service = ProjectRuntimeService(
            runtimeLocator: NodeEnvironmentTestRuntimeLocator(environment: ["PATH": "/usr/bin:/bin"]),
            store: PluginLocalDevelopmentKeyValueStore(),
            toolDiscovery: FixedNodeToolDiscovery(node: node)
        )

        #expect(service.languageToolProcessEnvironment()["LITHE_NODE_PATH"] == node.path)
    }

    @Test
    @MainActor
    func explicitNodePathOverrideIsPreserved() {
        let service = ProjectRuntimeService(
            runtimeLocator: NodeEnvironmentTestRuntimeLocator(environment: [
                "PATH": "/usr/bin:/bin",
                "LITHE_NODE_PATH": "/custom/node"
            ]),
            store: PluginLocalDevelopmentKeyValueStore(),
            toolDiscovery: FixedNodeToolDiscovery(node: URL(fileURLWithPath: "/fixture-tools/node"))
        )

        #expect(service.languageToolProcessEnvironment()["LITHE_NODE_PATH"] == "/custom/node")
    }
}

private struct PluginTrustFixture {
    let root: URL
    let packageURL: URL
    /// The test runner is not a signed app, so an ad-hoc bundle stands in
    /// for the host whose code signature the verifier inspects.
    var hostBundleURL: URL { packageURL.appendingPathComponent("Feature.bundle") }
    let manifest: PluginManifest
    let privateKey: Curve25519.Signing.PrivateKey

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-plugin-trust-\(UUID().uuidString)", isDirectory: true)
        packageURL = root.appendingPathComponent("sources/dev.example.publisher", isDirectory: true)
        privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        manifest = PluginManifest(
            id: PluginID("dev.example.publisher"),
            displayName: "Example Publisher Plugin",
            version: PluginVersion(major: 0, minor: 3, patch: 0),
            hostCompatibility: PluginHostCompatibility(
                minimum: PluginVersion(major: 0, minor: 3, patch: 0),
                maximumExclusive: PluginVersion(major: 0, minor: 4, patch: 0)
            ),
            vendor: PluginVendor(
                id: "dev.example",
                displayName: "Example",
                signatureRequirement: .publisherPackage
            ),
            entrypoint: PluginEntrypoint(
                kind: .nativeBundle,
                bundleIdentifier: "dev.example.publisher.bundle",
                principalClass: "ExamplePublisherPlugin",
                bundlePath: "Feature.bundle"
            ),
            modules: [PluginModuleDeclaration(manifest: ModuleManifest(
                id: ModuleID("dev.example.publisher.feature"),
                displayName: "Example Publisher Feature",
                scope: .application,
                defaultState: .disabled,
                activationPolicy: .onDemand,
                providedCapabilities: [ModuleCapabilityID("dev.example.publisher.capability")]
            ))]
        )
        do {
            try writePackage()
        } catch {
            remove()
            throw error
        }
    }

    func signPackage(keyID: String) throws {
        let document = try PluginPackageSignature.makeDocument(
            packageAt: packageURL,
            pluginID: manifest.id.rawValue,
            pluginVersion: manifest.version.description,
            privateKey: privateKey,
            keyID: keyID
        )
        try PluginPackageSignature.write(document, to: packageURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func writePackage() throws {
        let contents = packageURL.appendingPathComponent("Feature.bundle/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let infoPlist: [String: Any] = [
            "CFBundleIdentifier": "dev.example.publisher.bundle",
            "CFBundlePackageType": "BNDL"
        ]
        try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: packageURL.appendingPathComponent("plugin.json"),
            options: .atomic
        )
        // The verifier requires a valid code signature; an ad-hoc signature
        // matches what development builds produce.
        let result = MacProcessRunner().run(ProcessRequest(
            executablePath: "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", packageURL.appendingPathComponent("Feature.bundle").path],
            timeoutMilliseconds: 10_000
        ))
        guard result.succeeded else {
            throw PluginTrustFixtureError.codesignFailed(result.output)
        }
    }
}

private enum PluginTrustFixtureError: Error {
    case codesignFailed(String)
}

private final class PluginLocalDevelopmentKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

private struct NodeEnvironmentTestRuntimeLocator: RuntimeLocator {
    let environmentValues: [String: String]

    init(environment: [String: String]) {
        environmentValues = environment
    }

    func environment() -> [String: String] { environmentValues }
    func discover() -> RuntimeDiscoveryResult { RuntimeDiscoveryResult(javaRuntimes: [], mavenRuntimes: []) }
    func validJavaHome(path: String) -> URL? { nil }
    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? { nil }
    func isExecutable(at url: URL) -> Bool { false }
    func systemMavenExecutable() -> URL? { nil }
    func mavenExecutable(forHomePath path: String) -> URL? { nil }
    func mavenRuntime(at executableURL: URL) -> MavenRuntimeCandidate? { nil }
}

private struct FixedNodeToolDiscovery: RuntimeToolDiscovery {
    let node: URL

    func candidates(for command: String, projectURL: URL?, environment: [String: String]) -> [RuntimeToolCandidate] {
        guard command == "node" else { return [] }
        return [RuntimeToolCandidate(command: command, executableURL: node, source: .environment, detail: nil)]
    }

    func guidance(for command: String, projectURL: URL?, environment: [String: String]) -> RuntimeToolGuidance {
        DefaultRuntimeToolDiscovery().guidance(for: command, projectURL: projectURL, environment: environment)
    }
}
