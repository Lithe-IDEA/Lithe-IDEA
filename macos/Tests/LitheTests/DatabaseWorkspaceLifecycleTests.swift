import AppKit
import LitheApplicationKernel
@testable import LitheDatabaseModule
import LitheModuleAPI
import SwiftUI
import Testing
@testable import Lithe

@Suite("Database workspace lifecycle")
@MainActor
struct DatabaseWorkspaceLifecycleTests {
    @Test(arguments: [false, true], [DatabaseKind.sqlite, .redis])
    func retainedViewsRenderAfterProjectSessionShutdown(hasSelectedConnection: Bool, kind: DatabaseKind) async throws {
        let preferences = DatabaseLifecyclePreferences()
        let connectionStore = DatabaseConnectionStore(store: preferences, secureStore: DatabaseLifecycleSecrets())
        let profile = DatabaseProfile(name: "Lifecycle fixture", kind: kind, path: "/fixture/lifecycle.sqlite")
        try connectionStore.save([profile])
        let settings = AppSettings(store: preferences)
        let services = MacServiceContainer(
            store: preferences, settings: settings, moduleLaunchMode: .safeMode
        ).services
        let model = AppModel(settings: settings, services: services)
        let feature = DatabaseFeatureModel(
            operations: DatabaseSidecarService(processRunner: DatabaseLifecycleProcessRunner(), executableURL: nil),
            connectionStore: connectionStore
        )
        defer { feature.prepareForModuleRelease() }
        #expect(DatabaseWorkspaceTabTitle(feature: feature, profileID: feature.selectedProfileID).title == "SQL History")
        feature.selectedProfileID = profile.id
        for section in DatabaseWorkspaceSection.allCases {
            feature.workspaceSection = section
            #expect(DatabaseWorkspaceTabTitle(feature: feature, profileID: profile.id).title == profile.name)
        }
        feature.selectedProfileID = nil
        if hasSelectedConnection {
            feature.selectedProfileID = profile.id
            feature.workspaceSection = .sql
        }
        let databaseTab = EditorTabItem.database(feature.selectedProfileID)
        model.cacheModuleCapability(DatabaseModuleCapability(feature: feature), id: .databaseWorkspace, moduleID: .database)
        model.workbenchFeature.setVisibility(.database, isVisible: true)
        #expect(model.selectedSidebar == .project)
        #expect(!model.editorTabItems.contains(databaseTab))
        model.openDatabaseWorkspace()
        model.openDatabaseWorkspace()
        #expect(model.editorTabItems.filter { $0 == databaseTab }.count == 1)
        #expect(model.isDatabaseWorkspaceSelected)
        model.workbenchFeature.setVisibility(.database, isVisible: false)
        #expect(model.isDatabaseWorkspaceSelected)
        #expect(model.requestCloseActiveWorkbenchItem())
        #expect(!model.editorTabItems.contains(databaseTab))
        model.openDatabaseWorkspace()
        feature.addSQLTab(sql: "SELECT 'retained draft'")
        let draftID = feature.selectedSQLTabID
        model.openDatabaseWorkspace(overview: true)
        model.openDatabaseWorkspace(overview: true)
        #expect(model.editorTabItems.filter { $0 == .databaseOverview }.count == 1)
        #expect(model.editorTabItems.contains(databaseTab))
        #expect(model.editorTabOrderFeature.databaseOverviewSelected)
        model.editorTabOrderFeature.reconcileDocuments(orderedIDs: [])
        #expect(model.editorTabItems.contains(.databaseOverview))
        #expect(model.requestCloseActiveWorkbenchItem())
        #expect(!model.editorTabItems.contains(.databaseOverview))
        #expect(model.editorTabItems.contains(databaseTab))
        #expect(model.isDatabaseWorkspaceSelected)
        #expect(!model.editorTabOrderFeature.databaseOverviewSelected)
        #expect(feature.selectedSQLTabID == draftID)
        #expect(feature.selectedSQLTab?.sql == "SELECT 'retained draft'")
        model.openDatabaseWorkspace(overview: true)
        model.closeDatabaseWorkspace(overview: false)
        #expect(model.isDatabaseWorkspaceSelected)
        #expect(model.editorTabOrderFeature.databaseOverviewSelected)
        model.openDatabaseWorkspace()

        func content(revision: Int) -> AnyView {
            AnyView(HStack(spacing: 0) {
                DatabaseSidebarView().frame(width: 280)
                VStack {
                    DatabaseWorkspaceView()
                    DatabaseOverviewView()
                }.frame(width: 760, height: 550)
            }
            .id(revision)
            .environmentObject(feature)
            .environmentObject(model)
            .environmentObject(settings))
        }
        let host = NSHostingView(rootView: content(revision: 0))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 550),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
        #expect(model.databaseFeatureIfActive === feature)
        // The same native host must survive all four page renderers, including
        // their empty states, without starting a database process.
        if hasSelectedConnection {
            for section in DatabaseWorkspaceSection.allCases {
                feature.workspaceSection = section
                host.rootView = content(revision: 2)
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.width > 0)
            }
        }

        // Keep the native host alive across cache teardown, then force another
        // body evaluation. A parent sidebar guard cannot protect this ordering.
        feature.prepareForModuleRelease()
        await model.shutdownProjectSession()
        #expect(model.databaseFeatureIfActive == nil)
        #expect(!model.editorTabItems.contains(databaseTab))
        #expect(!model.editorTabItems.contains(.databaseOverview))
        host.rootView = content(revision: 1)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)

        // Connection and schema sheets can also outlive the workspace subtree.
        host.rootView = AnyView(VStack {
            DatabaseConnectionEditor(isPresented: .constant(true))
            DatabaseSchemaDiffView()
        }.environmentObject(feature)
            .environmentObject(model)
            .environmentObject(settings))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
    }

    @Test
    func connectionTabsDeduplicateAndRestoreNavigationAndQueryDrafts() async throws {
        let preferences = DatabaseLifecyclePreferences()
        let store = DatabaseConnectionStore(store: preferences, secureStore: DatabaseLifecycleSecrets())
        let first = DatabaseProfile(name: "First", kind: .sqlite, database: "first_db")
        let second = DatabaseProfile(name: "Second", kind: .sqlite, database: "second_db")
        try store.save([first, second])
        let settings = AppSettings(store: preferences)
        let model = AppModel(settings: settings, services: MacServiceContainer(
            store: preferences, settings: settings, moduleLaunchMode: .safeMode
        ).services)
        let feature = DatabaseFeatureModel(
            operations: DatabaseSidecarService(processRunner: EmptyDatabaseWorkspaceRunner(), executableURL: URL(fileURLWithPath: "/fixture/database")),
            connectionStore: store
        )
        defer { feature.prepareForModuleRelease() }
        model.cacheModuleCapability(DatabaseModuleCapability(feature: feature), id: .databaseWorkspace, moduleID: .database)
        await feature.select(first)
        feature.workspaceSection = .sql
        feature.addSQLTab(sql: "SELECT 'first draft'")
        let firstQueryID = feature.selectedSQLTabID
        model.openDatabaseWorkspace()
        model.openDatabaseWorkspace()
        await feature.select(second)
        feature.workspaceSection = .structure
        feature.addSQLTab(sql: "SELECT 'second draft'")
        let secondQueryID = feature.selectedSQLTabID
        model.openDatabaseWorkspace()
        #expect(model.editorTabItems == [.database(first.id), .database(second.id)])
        #expect(DatabaseWorkspaceTabTitle(feature: feature, profileID: first.id).title == "first_db")
        #expect(DatabaseWorkspaceTabTitle(feature: feature, profileID: second.id).title == "second_db")
        await feature.select(first)
        model.openDatabaseWorkspace()
        #expect(model.activeDatabaseEditorTab == .database(first.id))
        #expect(feature.workspaceSection == .sql)
        #expect(feature.selectedSQLTabID == firstQueryID)
        #expect(feature.selectedSQLTab?.sql == "SELECT 'first draft'")
        feature.showGlobalHistory()
        model.openDatabaseWorkspace()
        #expect(model.editorTabItems.last == .database(nil))
        await feature.select(second)
        model.openDatabaseWorkspace()
        #expect(feature.workspaceSection == .structure)
        #expect(feature.selectedSQLTabID == secondQueryID)
        #expect(feature.selectedSQLTab?.sql == "SELECT 'second draft'")
        model.closeDatabaseTab(.database(first.id))
        #expect(model.isDatabaseWorkspaceSelected)
        #expect(model.activeDatabaseEditorTab == .database(second.id))
        model.closeDatabaseWorkspace()
        #expect(model.editorTabItems.isEmpty)
        await model.shutdownProjectSession()
    }

    @Test
    func sleepingModuleStopsResourcesWhileOldPresentationSurvivesAndWakeUsesNewFeature() async throws {
        let runtime = ModuleRuntime()
        let preferences = DatabaseLifecyclePreferences()
        try runtime.register(ModuleFactory(manifest: ModuleManifest(id: .workspace, displayName: "Workspace", scope: .workspace)) {
            DatabaseLifecycleWorkspaceModule()
        })
        try runtime.register(ModuleFactory(manifest: DatabaseModule.moduleManifest, contributions: DatabaseModule.moduleContributions) {
            DatabaseModule(
                processRunner: DatabaseLifecycleProcessRunner(), executableURL: nil,
                preferenceStore: preferences, secureStore: DatabaseLifecycleSecrets(),
                recoveryStore: UnavailableDatabaseRecoveryStore(), fileStorage: UnavailableDatabaseFileStorage()
            )
        })
        var notifications: [String] = []
        let coordinator = DatabaseModuleCoordinator(runtime: runtime, store: ModuleCapabilityStore(), onChange: {}, onError: { notifications.append($0) })
        do {
            var retained: DatabaseFeatureModel? = try #require(await coordinator.activate())
            #expect(await coordinator.activate() === retained)
            retained?.errorMessage = "Connection failed"
            #expect(notifications == ["Connection failed"])
            retained?.errorMessage = nil
            #expect(notifications.count == 1)
            weak var released = retained
            retained?.addSQLTab(sql: "SELECT 'old presentation'")

            await coordinator.sleep()
            retained?.errorMessage = "Late failure after sleep"
            #expect(notifications == ["Connection failed"])
            #expect(runtime.capability(.databaseWorkspace) == nil)
            #expect(try runtime.snapshot(for: .database).activity.activeResourceCount == 0)
            #expect(retained?.hasActiveModuleWork == false)
            #expect(retained?.selectedSQLTab?.sql == "SELECT 'old presentation'")

            let next = try #require(await coordinator.activate())
            next.errorMessage = "New connection failed"
            #expect(notifications == ["Connection failed", "New connection failed"])
            #expect(next !== retained)
            #expect(next.selectedSQLTab?.sql == "")
            retained?.updateSQL("SELECT 'late edit'", in: try #require(retained?.selectedSQLTabID))
            #expect(next.selectedSQLTab?.sql == "")
            retained = nil
            #expect(released == nil, "The old feature must be released when its presentation goes away")
        } catch {
            await runtime.shutdownAll()
            throw error
        }
        await runtime.shutdownAll()
    }

    @Test(arguments: ["document", "overview", "close", "closeAll", "closeBeforeLoad"], [false, true])
    func delayedConnectionLoadPreservesLaterNavigation(destination: String, fails: Bool) async throws {
        let preferences = DatabaseLifecyclePreferences()
        let store = DatabaseConnectionStore(store: preferences, secureStore: DatabaseLifecycleSecrets())
        let first = DatabaseProfile(name: "First", kind: .redis)
        let second = DatabaseProfile(name: "Second", kind: .sqlite)
        try store.save([first, second])
        let settings = AppSettings(store: preferences)
        let model = AppModel(settings: settings, services: MacServiceContainer(
            store: preferences, settings: settings, moduleLaunchMode: .safeMode
        ).services)
        let runner = GatedDatabaseWorkspaceRunner(fails: fails)
        let feature = DatabaseFeatureModel(
            operations: DatabaseSidecarService(processRunner: runner, executableURL: URL(fileURLWithPath: "/fixture/database")),
            connectionStore: store
        )
        defer { runner.release.open(); feature.prepareForModuleRelease() }
        model.cacheModuleCapability(DatabaseModuleCapability(feature: feature), id: .databaseWorkspace, moduleID: .database)
        feature.activateProfile(first)
        #expect(!feature.isLoading && feature.connectionStatus(for: first) == .connected)
        model.documentFeature.openVirtualDocument(URL(string: "lithe-test://documents/Navigation.txt")!, text: "fixture", displayPath: nil)
        do {
            let document = try #require(model.openDocuments.first)
            model.selectDatabaseWorkspace(profileID: second.id)
            // The tab must become selected before I/O starts, so even a loading
            // connection is immediately closable. This fails with the old await-then-open path.
            #expect(feature.selectedProfileID == second.id)
            #expect(model.isDatabaseWorkspaceSelected)
            #expect(model.activeDatabaseEditorTab == .database(second.id))
            if destination == "closeBeforeLoad" { model.closeDatabaseTab(.database(second.id)) }
            #expect(await runner.entered.waitUntilOpen())
            #expect(feature.isLoading)
            switch destination {
            case "document": model.selectEditorDocument(document)
            case "overview": model.openDatabaseWorkspace(overview: true)
            case "close": model.closeDatabaseTab(.database(second.id))
            case "closeBeforeLoad": break
            default: model.closeDatabaseWorkspace()
            }
            let expectedTabs = model.editorTabItems
            let expectedSelected = model.isDatabaseWorkspaceSelected
            let expectedOverview = model.editorTabOrderFeature.databaseOverviewSelected
            runner.release.open()
            #expect(await awaitChange(on: feature, until: { !feature.isLoading }))
            #expect((feature.errorMessage != nil) == fails)
            #expect(model.editorTabItems == expectedTabs)
            #expect(model.isDatabaseWorkspaceSelected == expectedSelected)
            #expect(model.editorTabOrderFeature.databaseOverviewSelected == expectedOverview)
            if destination == "document" { #expect(model.activeDocumentID == document.id) }
        } catch {
            runner.release.open()
            _ = await awaitChange(on: feature, until: { !feature.isLoading })
            await model.shutdownProjectSession()
            throw error
        }
        await model.shutdownProjectSession()
    }
}

@MainActor
private final class DatabaseLifecycleWorkspaceModule: LitheModule {
    let manifest = ModuleManifest(id: .workspace, displayName: "Workspace", scope: .workspace)
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}

private struct DatabaseLifecycleProcessRunner: DatabaseProcessRunning {
    func runDatabaseProcess(_ request: DatabaseProcessRequest) -> DatabaseProcessResult {
        Issue.record("Rendering database views must not launch a database process")
        return DatabaseProcessResult(output: "", exitCode: 1)
    }
}

private final class DatabaseLifecyclePreferences: KeyValueStore, DatabasePreferenceStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private struct DatabaseLifecycleSecrets: DatabaseSecureStore {
    func read(key: String) -> String? { nil }
    func write(_ value: String, key: String) throws {}
    func delete(key: String) throws {}
}

private struct EmptyDatabaseWorkspaceRunner: DatabaseProcessRunning {
    func runDatabaseProcess(_ request: DatabaseProcessRequest) -> DatabaseProcessResult {
        guard let data = request.standardInput,
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = input["id"] as? String,
              let output = try? JSONSerialization.data(withJSONObject: ["id": id, "ok": true, "result": []]) else {
            return DatabaseProcessResult(output: "Invalid fixture request", exitCode: 1)
        }
        return DatabaseProcessResult(output: String(decoding: output, as: UTF8.self), exitCode: 0)
    }
}

private struct GatedDatabaseWorkspaceRunner: DatabaseProcessRunning {
    let fails: Bool
    let entered = TestGate()
    let release = TestGate()

    func runDatabaseProcess(_ request: DatabaseProcessRequest) -> DatabaseProcessResult {
        guard let data = request.standardInput,
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = input["id"] as? String else {
            return DatabaseProcessResult(output: "Invalid fixture request", exitCode: 1)
        }
        if input["method"] as? String == "listTables" {
            entered.open()
            // This synchronous port runs on the production-owned worker, never MainActor.
            guard release.waitSynchronously(timeout: 2) else {
                Issue.record("Database navigation test did not release its request")
                return DatabaseProcessResult(output: "Fixture deadline exceeded", exitCode: 1)
            }
            if fails { return DatabaseProcessResult(output: "Fixture connection failed", exitCode: 1) }
        }
        guard let output = try? JSONSerialization.data(withJSONObject: ["id": id, "ok": true, "result": []]) else {
            return DatabaseProcessResult(output: "Invalid fixture response", exitCode: 1)
        }
        return DatabaseProcessResult(output: String(decoding: output, as: UTF8.self), exitCode: 0)
    }
}
