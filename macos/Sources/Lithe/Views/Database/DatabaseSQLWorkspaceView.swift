import AppKit
import SwiftUI
import LitheDatabaseModule

/// Observe the feature directly so changing sections updates an already open tab.
struct DatabaseWorkspaceTabTitle: View {
    @ObservedObject var feature: DatabaseFeatureModel

    var profileID: UUID?

    var title: String {
        guard let profileID, let profile = feature.profiles.first(where: { $0.id == profileID }) else {
            return "SQL History"
        }
        return profile.database.isEmpty ? profile.name : profile.database
    }

    var body: some View { Text(verbatim: title) }
}

struct DatabaseWorkspaceView: View {
    @EnvironmentObject private var feature: DatabaseFeatureModel

    var body: some View {
        Group {
            if feature.selectedProfile == nil || (feature.workspaceSection == .history && feature.selectedProfile?.kind.isSQLDatabase != true) {
                DatabaseHistoryView()
            } else if feature.selectedProfile?.kind == .redis {
                RedisWorkspaceView()
            } else if feature.selectedProfile?.kind == .nacos {
                NacosWorkspaceView()
            } else if feature.selectedProfile?.kind == .mongodb {
                mongoWorkspace
            } else {
                sqlWorkspace
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
        .id(feature.selectedProfileID)
    }

    private var sqlWorkspace: some View { DatabaseTableView() }

    private var mongoWorkspace: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                if let profile = feature.selectedProfile {
                    DatabaseBrandIcon(kind: .mongodb, size: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("MongoDB Documents").font(LitheTheme.uiFont(size: 12, weight: .semibold))
                        Text(profile.database.isEmpty ? "admin" : profile.database)
                            .font(LitheTheme.uiFont(size: 9.5))
                            .foregroundStyle(LitheTheme.secondaryText)
                    }
                }
                Spacer()
                Text("Collection data can be edited directly in the grid.")
                    .font(LitheTheme.uiFont(size: 10.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .litheWorkbenchSurface(LitheTheme.toolHeader)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            DatabaseTableView()
        }
    }
}

extension DatabaseWorkspaceSection {
    var titleKey: LocalizedStringKey {
        switch self {
        case .data: "Data"
        case .sql: "SQL"
        case .structure: "Structure"
        case .history: "History"
        }
    }
    var iconPath: String {
        switch self {
        case .data: "database/expui/table.svg"
        case .sql: "expui/fileTypes/shell.svg"
        case .structure: "expui/toolwindows/structure.svg"
        case .history: "expui/general/history.svg"
        }
    }
}

struct DatabaseHistoryView: View {
    @EnvironmentObject private var feature: DatabaseFeatureModel

    private var entries: [DatabaseSQLHistoryEntry] {
        guard let profileID = feature.selectedProfileID else { return feature.sqlHistory }
        return feature.sqlHistory.filter { $0.profileID == profileID }
    }

    var body: some View {
        VStack(spacing: 0) {
            LitheToolWindowHeader(title: "SQL History") {
                Text("\(entries.count) statements")
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            LitheToolWindowHeaderDivider()
            if entries.isEmpty {
                LitheUnavailableView("No query history", systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(LitheTheme.secondaryText)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            Button {
                                Task {
                                    guard let profile = feature.profiles.first(where: { $0.id == entry.profileID }) else { return }
                                    if feature.selectedProfileID != profile.id { await feature.select(profile) }
                                    guard feature.selectedProfileID == profile.id else { return }
                                    feature.restoreSQLHistory(entry)
                                    feature.workspaceSection = .sql
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.sql.replacingOccurrences(of: "\n", with: " "))
                                            .font(LitheTheme.codeFont)
                                            .foregroundStyle(LitheTheme.primaryText)
                                            .lineLimit(2)
                                        Text(entry.executedAt, format: .dateTime.year().month().day().hour().minute().second())
                                            .font(LitheTheme.uiFont(size: 12))
                                            .foregroundStyle(LitheTheme.secondaryText)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.litheNoPress)
                            .litheRowHover()
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(12)
                }
                .litheScrollViewChrome()
            }
        }
    }
}

private extension DatabaseKind {
    var displayName: String {
        switch self {
        case .mysql: "MySQL"
        case .mariadb: "MariaDB"
        case .postgresql: "PostgreSQL"
        case .sqlite: "SQLite"
        case .sqlserver: "SQL Server"
        case .mongodb: "MongoDB"
        case .redis: "Redis"
        case .nacos: "Nacos"
        }
    }

    var symbolName: String {
        switch self {
        case .mysql: "cylinder.split.1x2"
        case .mariadb: "cylinder.split.1x2"
        case .postgresql: "cylinder.split.1x2"
        case .sqlite: "externaldrive"
        case .sqlserver: "server.rack"
        case .mongodb: "leaf"
        case .redis: "square.stack.3d.up.fill"
        case .nacos: "slider.horizontal.3"
        }
    }
}

struct DatabaseSQLWorkspaceView: View {
    @EnvironmentObject private var feature: DatabaseFeatureModel
    @State private var pendingRisk: DatabaseSQLAnalysis?
    @State private var pendingScope: DatabaseSQLExecutionScope = .all
    @State private var pendingTabID: UUID?
    @State private var showsRiskConfirmation = false
    @State private var sqlSelection = ""
    @State private var queryIsActive = false

    var body: some View {
        VStack(spacing: 0) {
            queryTabs
            LitheToolWindowHeaderDivider()
            commandBar
            editor
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            results
        }
        .litheWorkbenchSurface(LitheTheme.editor)
        .background(LitheToolWindowActivityTracker(isActive: $queryIsActive))
        .workbenchHoverTooltipScope()
        .alert("Confirm database change", isPresented: $showsRiskConfirmation, presenting: pendingRisk) { analysis in
            Button("Cancel", role: .cancel) {
                pendingRisk = nil
                pendingTabID = nil
            }
            Button(analysis.statementCount > 1 ? "Run batch" : "Run statement", role: .destructive) {
                if let tabID = pendingTabID {
                    Task { await feature.runSQL(in: tabID, scope: pendingScope, confirmedRisk: true) }
                }
                pendingRisk = nil
                pendingTabID = nil
            }
        } message: { analysis in
            DatabaseLocalization.text(analysis.warning ?? "This statement can change the database.")
        }
        .onChange(of: feature.selectedSQLTabID) { _ in
            sqlSelection = ""
        }
    }

    private var queryTabs: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(feature.sqlTabs) { tab in
                        HStack(spacing: 2) {
                            Button { feature.selectedSQLTabID = tab.id } label: {
                                HStack(spacing: 6) {
                                    LitheIDEAIcon(resourcePath: tab.isRunning ? "expui/general/refresh.svg" : "expui/fileTypes/shell.svg", size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
                                    DatabaseLocalization.queryTabTitle(tab.title).lineLimit(1)
                                }
                                .font(LitheTheme.uiFont(size: 13))
                                .foregroundStyle(feature.selectedSQLTabID == tab.id ? LitheTheme.primaryText : LitheTheme.secondaryText)
                                .padding(.leading, 8)
                            }
                            .buttonStyle(.litheNoPress)
                            LitheToolWindowTabCloseButton { feature.closeSQLTab(tab.id) }
                                .accessibilityLabel("Close query tab")
                        }
                        .modifier(LitheToolWindowTabStyle(isSelected: feature.selectedSQLTabID == tab.id, isActive: queryIsActive))
                    }
                }
            }
            Button { feature.addSQLTab() } label: {
                LitheIDEAIcon(resourcePath: "expui/general/add.svg", size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
            }
            .litheToolbarIconButton()
            .workbenchHoverHelp(Text("New query tab"))
            .accessibilityLabel("New query tab")
        }
        .padding(.horizontal, 8)
        .frame(height: LitheTheme.Metrics.toolbarHeight)
        .litheWorkbenchSurface(LitheTheme.editor)
    }

    private var commandBar: some View {
        HStack(spacing: 5) {
            Button(action: runSelectedQuery) {
                LitheIDEAIcon(resourcePath: "expui/run/run.svg", size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
            }
            .litheToolbarIconButton()
            .accessibilityLabel("Run")
            .disabled(feature.selectedSQLTab?.isRunning == true || feature.selectedProfile == nil)
            .help(hasSQLSelection ? "Run selected SQL (Command-Return)" : "Run all SQL (Command-Return)")

            LitheMenu {
                LitheContextMenuItem.action("Run All", systemImage: "play.fill") { runAllQuery() }
                LitheContextMenuItem.action("Run Selection", systemImage: "text.cursor") { runSelectionQuery() }
                    .disabled(!hasSQLSelection)
            } label: {
                LitheIDEAIcon(resourcePath: "expui/general/chevronDown.svg", size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
            }
            .litheToolbarIconButton()
            .disabled(feature.selectedSQLTab?.isRunning == true || feature.selectedProfile == nil)
            .workbenchHoverHelp(Text("Choose SQL execution scope"))
            .accessibilityLabel("Choose SQL execution scope")

            Button { if let id = feature.selectedSQLTabID { feature.formatSQL(in: id) } } label: {
                LitheIDEAIcon(resourcePath: "expui/actions/reformatCode.svg", size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
            }
            .litheToolbarIconButton()
            .disabled(feature.selectedSQLTab?.sql.isEmpty != false)
            .workbenchHoverHelp(Text("Format SQL"))
            .accessibilityLabel("Format SQL")

            LitheMenu {
                let history = historyForSelectedProfile
                if history.isEmpty {
                    LitheContextMenuItem.heading("No query history")
                } else {
                    for entry in history {
                        LitheContextMenuItem.action(historyLabel(entry)) {
                            feature.restoreSQLHistory(entry)
                        }
                    }
                }
            } label: {
                LitheIDEAIcon(resourcePath: "expui/general/history.svg", size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
            }
            .litheToolbarIconButton()
            .workbenchHoverHelp(Text("Query history"))
            .accessibilityLabel("Query history")

            if let execution = feature.selectedSQLTab?.execution {
                executionLabel(execution)
                    .font(LitheTheme.uiFont(size: 12, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            Spacer()
            if let profile = feature.selectedProfile {
                Text(profile.database.isEmpty ? (profile.path.isEmpty ? profile.name : profile.path) : profile.database)
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
            } else {
                Text("No connection")
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(LitheTheme.warning)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: LitheTheme.Metrics.toolbarHeight)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    @ViewBuilder
    private var editor: some View {
        if let tab = feature.selectedSQLTab {
            SQLSyntaxEditor(
                text: Binding(
                    get: { feature.selectedSQLTab?.sql ?? "" },
                    set: { feature.updateSQL($0, in: tab.id) }
                ),
                completions: feature.sqlCompletionItems,
                onRun: runSelectedQuery,
                onSelectionChange: { sqlSelection = $0 }
            )
            .id(tab.id)
            .frame(minHeight: 180, idealHeight: 240, maxHeight: 320)
            .overlay(alignment: .bottomLeading) {
                if let error = tab.errorMessage {
                    Label {
                        DatabaseLocalization.error(error)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                        .font(LitheTheme.uiFont(size: 11))
                        .foregroundStyle(LitheTheme.error)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LitheTheme.toolHeader)
                }
            }
        } else {
            LitheUnavailableView("No Query Tab", systemImage: "terminal")
        }
    }

    @ViewBuilder
    private var results: some View {
        if let tab = feature.selectedSQLTab,
           let result = tab.result {
            DatabaseQueryResultGrid(columns: tab.resultColumns, rows: result.rows)
                .overlay(alignment: .topTrailing) {
                    if result.truncated {
                        Text("Limited to 10,000 rows")
                            .font(LitheTheme.uiFont(size: 10.5))
                            .foregroundStyle(LitheTheme.warning)
                            .padding(8)
                    }
                }
        } else if let affected = feature.selectedSQLTab?.rowsAffected {
            let count = feature.selectedSQLTab.map { feature.analysis(forSQLTab: $0.id).statementCount } ?? 1
            LitheUnavailableView(count > 1 ? "Statements completed" : "Statement completed", systemImage: "checkmark.circle", description: Text("Rows affected: \(affected)"))
                .foregroundStyle(LitheTheme.secondaryText)
        } else {
            LitheUnavailableView("Query Results", systemImage: "tablecells", description: Text("Run a SELECT, SHOW, DESCRIBE, or EXPLAIN statement to inspect results."))
                .foregroundStyle(LitheTheme.secondaryText)
        }
    }

    private var historyForSelectedProfile: [DatabaseSQLHistoryEntry] {
        guard let profileID = feature.selectedProfileID else { return feature.sqlHistory }
        return feature.sqlHistory.filter { $0.profileID == profileID }
    }

    private func runSelectedQuery() {
        if hasSQLSelection {
            run(scope: .selection(sqlSelection))
        } else {
            runAllQuery()
        }
    }

    private func runAllQuery() {
        run(scope: .all)
    }

    private func runSelectionQuery() {
        guard hasSQLSelection else { return }
        run(scope: .selection(sqlSelection))
    }

    private func run(scope: DatabaseSQLExecutionScope) {
        guard let tabID = feature.selectedSQLTabID else { return }
        let analysis = feature.analysis(forSQLTab: tabID, scope: scope)
        if analysis.requiresConfirmation {
            pendingRisk = analysis
            pendingScope = scope
            pendingTabID = tabID
            showsRiskConfirmation = true
        } else {
            Task { await feature.runSQL(in: tabID, scope: scope) }
        }
    }

    private var hasSQLSelection: Bool {
        !sqlSelection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func executionLabel(_ execution: DatabaseSQLExecution) -> Text {
        if let rows = execution.rowsReturned, let affected = execution.rowsAffected {
            return Text("\(rows) rows, \(affected) affected  \(execution.durationMilliseconds) ms")
        }
        if let rows = execution.rowsReturned { return Text("\(rows) rows  \(execution.durationMilliseconds) ms") }
        if let affected = execution.rowsAffected { return Text("\(affected) affected  \(execution.durationMilliseconds) ms") }
        return Text("\(execution.durationMilliseconds) ms")
    }

    private func historyLabel(_ entry: DatabaseSQLHistoryEntry) -> String {
        let singleLine = entry.sql.replacingOccurrences(of: "\n", with: " ")
        return singleLine.count > 72 ? "\(singleLine.prefix(72))..." : singleLine
    }
}

private struct DatabaseQueryResultGrid: View {
    let columns: [String]
    let rows: [DatabaseRow]

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            HStack(spacing: 0) {
                                Text("\(index + 1)")
                                    .font(LitheTheme.codeFont)
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .frame(width: 44, height: LitheTheme.Metrics.rowHeight)
                                    .background(LitheTheme.toolHeader)
                                ForEach(columns, id: \.self) { column in
                                    Text(display(row[column]))
                                        .font(LitheTheme.codeFont)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .padding(.horizontal, 7)
                                        .frame(width: 180, height: LitheTheme.Metrics.rowHeight, alignment: .leading)
                                        .overlay(alignment: .trailing) { Rectangle().fill(LitheTheme.divider).frame(width: 1) }
                                }
                            }
                            .overlay(alignment: .bottom) { Rectangle().fill(LitheTheme.divider).frame(height: 1) }
                        }
                    } header: {
                        HStack(spacing: 0) {
                            Text("#").frame(width: 44, height: LitheTheme.Metrics.toolWindowHeaderHeight)
                            ForEach(columns, id: \.self) { column in
                                Text(column)
                                    .font(LitheTheme.uiFont(size: 13))
                                    .lineLimit(1)
                                    .padding(.horizontal, 7)
                                    .frame(width: 180, height: LitheTheme.Metrics.toolWindowHeaderHeight, alignment: .leading)
                                    .overlay(alignment: .trailing) { Rectangle().fill(LitheTheme.divider).frame(width: 1) }
                            }
                        }
                        .foregroundStyle(LitheTheme.secondaryText)
                        .background(LitheTheme.toolHeader)
                    }
                }
                .frame(minWidth: max(geometry.size.width, CGFloat(columns.count) * 180 + 44), minHeight: geometry.size.height, alignment: .topLeading)
            }
            .litheScrollViewChrome()
        }
    }

    private func display(_ value: DatabaseValue?) -> String {
        value?.displayText ?? "NULL"
    }
}

struct DatabaseStructureView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var feature: DatabaseFeatureModel
    @State private var editor: DatabaseSchemaEditorKind?
    @State private var pendingChange: DatabaseSchemaChange?
    @State private var showsDestructiveConfirmation = false

    var body: some View {
        if let table = feature.selectedTable {
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    Text(table).font(LitheTheme.uiFont(size: 13))
                    Spacer()
                    Button { editor = .column } label: { Image(systemName: "plus") }.litheToolbarIconButton().help("Add column")
                    Button { editor = .index } label: { Image(systemName: "plus.square.on.square") }.litheToolbarIconButton().help("Add index")
                    Button { editor = .foreignKey } label: { Image(systemName: "link.badge.plus") }.litheToolbarIconButton().help("Add foreign key")
                    Button { Task { await feature.openTable(table) } } label: { Image(systemName: "arrow.clockwise") }.litheToolbarIconButton().help("Refresh structure")
                }
                .padding(.horizontal, 8).frame(height: LitheTheme.Metrics.toolbarHeight).background(LitheTheme.editor)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        LitheToolWindowHeader(title: "Columns")
                        LitheToolWindowHeaderDivider()
                        Group {
                            ForEach(feature.columns, id: \.self) { column in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(column)
                                        Text(feature.columnTypes[column] ?? "")
                                            .font(LitheTheme.codeFont)
                                            .foregroundStyle(LitheTheme.secondaryText)
                                    }
                                    Spacer()
                                    HStack(spacing: 2) {
                                        Button {
                                            editor = .renameColumn(column)
                                        } label: {
                                            Image(systemName: "pencil")
                                        }
                                        .litheToolbarIconButton()
                                        .help("Rename Column…")

                                        Button(role: .destructive) {
                                            pendingChange = DatabaseSchemaChange(operation: "dropColumn", table: table, name: column)
                                            showsDestructiveConfirmation = true
                                        } label: {
                                            Image(systemName: "trash")
                                                .foregroundStyle(LitheTheme.error)
                                        }
                                        .litheToolbarIconButton()
                                        .help("Drop Column")
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                            }
                        }
                        LitheToolWindowHeader(title: "Indexes")
                        LitheToolWindowHeaderDivider()
                        Group {
                            if feature.indexes.isEmpty { Text("No indexes").foregroundStyle(LitheTheme.secondaryText) }
                            ForEach(Array(feature.indexes.enumerated()), id: \.offset) { _, row in
                                Text(metadata(row))
                            }
                        }
                        LitheToolWindowHeader(title: "Foreign Keys")
                        LitheToolWindowHeaderDivider()
                        Group {
                            if feature.foreignKeys.isEmpty { Text("No foreign keys").foregroundStyle(LitheTheme.secondaryText) }
                            ForEach(Array(feature.foreignKeys.enumerated()), id: \.offset) { _, row in
                                Text(metadata(row))
                            }
                        }
                    }
                    .font(LitheTheme.uiFont(size: 13))
                    .padding(16)
                }
                .litheScrollViewChrome()
            }
            .sheet(item: $editor) { editor in
                DatabaseSchemaEditorView(
                    kind: editor,
                    table: table,
                    columns: feature.columns,
                    onSave: { change in
                        self.editor = nil
                        Task { _ = await feature.applySchemaChange(change, confirmed: false) }
                    }
                )
                .environment(\.locale, model.settings.language.locale)
                .id(model.settings.language)
            }
            .alert("Drop database object?", isPresented: $showsDestructiveConfirmation, presenting: pendingChange) { change in
                Button("Cancel", role: .cancel) { pendingChange = nil }
                Button("Drop", role: .destructive) {
                    Task { _ = await feature.applySchemaChange(change, confirmed: true) }
                    pendingChange = nil
                }
            } message: { change in
                Text("Dropping \(change.name) cannot be undone by the table editor. A recovery snapshot should be taken before this operation.")
            }
        } else {
            LitheUnavailableView("No Table Selected", systemImage: "list.bullet.rectangle", description: Text("Choose a table to inspect its columns, indexes, and foreign keys."))
                .foregroundStyle(LitheTheme.secondaryText)
        }
    }

    private func metadata(_ row: DatabaseRow) -> String {
        row.keys.sorted().compactMap { key in
            guard let value = row[key] else { return nil }
            return "\(key): \(display(value))"
        }.joined(separator: "  ")
    }

    private func display(_ value: DatabaseValue) -> String {
        value.displayText
    }
}

private enum DatabaseSchemaEditorKind: Identifiable {
    case column
    case renameColumn(String)
    case index
    case foreignKey

    var id: String {
        switch self {
        case .column: "column"
        case let .renameColumn(name): "rename-\(name)"
        case .index: "index"
        case .foreignKey: "foreign-key"
        }
    }
}

private struct DatabaseSchemaEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let kind: DatabaseSchemaEditorKind
    let table: String
    let columns: [String]
    let onSave: (DatabaseSchemaChange) -> Void
    @State private var name = ""
    @State private var oldName = ""
    @State private var dataType = "TEXT"
    @State private var nullable = true
    @State private var defaultValue = ""
    @State private var indexName = ""
    @State private var indexColumns: Set<String> = []
    @State private var constraintName = ""
    @State private var referencedTable = ""
    @State private var referencedColumns = ""

    var body: some View {
        VStack(spacing: 0) {
            Text(LocalizedStringKey(title)).font(LitheTheme.uiFont(size: 15, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            Form {
                switch kind {
                case .column:
                    TextField("Column name", text: $name)
                    TextField("SQL type", text: $dataType)
                    Toggle("Allow NULL", isOn: $nullable)
                    TextField("Default expression (optional)", text: $defaultValue)
                case let .renameColumn(column):
                    TextField("Current name", text: Binding(get: { column }, set: { oldName = $0 })).disabled(true)
                    TextField("New name", text: $name)
                case .index:
                    TextField("Index name", text: $indexName)
                    ForEach(columns, id: \.self) { column in
                        Toggle(column, isOn: Binding(get: { indexColumns.contains(column) }, set: { value in if value { indexColumns.insert(column) } else { indexColumns.remove(column) } }))
                    }
                case .foreignKey:
                    TextField("Constraint name", text: $constraintName)
                    TextField("Referenced table", text: $referencedTable)
                    TextField("Referenced columns (comma separated)", text: $referencedColumns)
                    ForEach(columns, id: \.self) { column in
                        Toggle(column, isOn: Binding(get: { indexColumns.contains(column) }, set: { value in if value { indexColumns.insert(column) } else { indexColumns.remove(column) } }))
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") { onSave(makeChange()); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
            .padding(16)
        }
        .frame(width: 480, height: editorHeight)
        .onAppear {
            if case let .renameColumn(column) = kind { oldName = column }
        }
    }

    private var title: String {
        switch kind {
        case .column: "Add Column"
        case .renameColumn: "Rename Column"
        case .index: "Add Index"
        case .foreignKey: "Add Foreign Key"
        }
    }

    private var editorHeight: CGFloat {
        if case .foreignKey = kind { return 430 }
        return 330
    }

    private var isValid: Bool {
        switch kind {
        case .column: !name.isEmpty && !dataType.isEmpty
        case .renameColumn: !oldName.isEmpty && !name.isEmpty
        case .index: !indexName.isEmpty && !indexColumns.isEmpty
        case .foreignKey: !constraintName.isEmpty && !referencedTable.isEmpty && !indexColumns.isEmpty && !referencedColumns.isEmpty
        }
    }

    private func makeChange() -> DatabaseSchemaChange {
        switch kind {
        case .column:
            return DatabaseSchemaChange(operation: "addColumn", table: table, name: name, dataType: dataType, nullable: nullable, defaultValue: defaultValue)
        case .renameColumn:
            return DatabaseSchemaChange(operation: "renameColumn", table: table, name: name, oldName: oldName)
        case .index:
            return DatabaseSchemaChange(operation: "createIndex", table: table, indexName: indexName, indexColumns: columns.filter { indexColumns.contains($0) })
        case .foreignKey:
            return DatabaseSchemaChange(operation: "addForeignKey", table: table, indexColumns: columns.filter { indexColumns.contains($0) }, constraintName: constraintName, referencedTable: referencedTable, referencedColumns: referencedColumns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
    }
}

private struct DatabaseDiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var feature: DatabaseFeatureModel
    @State private var diagnosticKind = "tableSize"
    @State private var pendingRollback: DatabaseRecoveryPoint?
    @State private var showsRollbackConfirmation = false
    @State private var showsBackupSchedule = false

    var body: some View {
        let tab = feature.selectedSQLTab
        let analysis = tab.map { feature.analysis(forSQLTab: $0.id) }
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                LitheSettingsSelect(selection: $diagnosticKind, options: ["tableSize", "locks", "slowQueries", "indexes", "dataQuality", "schemaImpact"], width: 170, accessibilityLabel: "Diagnostic", title: { ["tableSize": "Table size", "locks": "Locks", "slowQueries": "Slow queries", "indexes": "Indexes", "dataQuality": "Data quality", "schemaImpact": "Schema impact"][$0] ?? $0 })
                .frame(width: 170)
                Button { loadDiagnostics() } label: { Image(systemName: "arrow.clockwise") }.litheIconButton().help("Run diagnostic")
                Button { if let profileID = feature.selectedProfileID { Task { _ = await feature.createBackup(profileID: profileID) } } } label: { Image(systemName: "archivebox") }.litheIconButton().help("Create database backup")
                Button { showsBackupSchedule = true } label: { Image(systemName: "calendar.badge.clock") }.litheIconButton().help("Configure backup schedule")
                if let progress = feature.backupProgress {
                    ProgressView(value: progress)
                        .frame(width: 90)
                        .help("Backing up database")
                }
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 36).background(LitheTheme.toolHeader)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            List {
                Section("SQL safety") {
                    LabeledContent("Selected statement") { DatabaseLocalization.statementKind(analysis?.kind) }
                    LabeledContent("Statements") { Text("\(analysis?.statementCount ?? 0)") }
                    if let warning = analysis?.warning {
                        Label {
                            DatabaseLocalization.text(warning)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                            .foregroundStyle(LitheTheme.warning)
                    } else {
                        Label("No destructive pattern detected", systemImage: "checkmark.shield")
                            .foregroundStyle(LitheTheme.success)
                    }
                }
                Section("Execution log") {
                    let events = feature.executionEvents
                        .filter { $0.profileID == feature.selectedProfileID }
                        .prefix(20)
                    if events.isEmpty {
                        Text("No execution events yet").foregroundStyle(LitheTheme.secondaryText)
                    } else {
                        ForEach(events) { event in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: event.status == .succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(event.status == .succeeded ? LitheTheme.success : LitheTheme.error)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text("\(event.source.rawValue.uppercased()) · \(event.operation)")
                                            .font(LitheTheme.uiFont(size: 11, weight: .medium))
                                        Spacer()
                                        Text("\(event.durationMilliseconds) ms")
                                            .font(LitheTheme.uiFont(size: 10, design: .monospaced))
                                            .foregroundStyle(LitheTheme.secondaryText)
                                    }
                                    if let error = event.errorMessage {
                                        Text(error)
                                            .font(LitheTheme.uiFont(size: 10))
                                            .foregroundStyle(LitheTheme.error)
                                            .lineLimit(2)
                                    } else if let rows = event.rowsReturned {
                                        Text("\(rows) rows returned")
                                            .font(LitheTheme.uiFont(size: 10))
                                            .foregroundStyle(LitheTheme.secondaryText)
                                    }
                                }
                            }
                        }
                    }
                }
                Section("Recent executions") {
                    let entries = feature.sqlHistory
                        .filter { $0.profileID == feature.selectedProfileID }
                        .prefix(10)
                    if entries.isEmpty {
                        Text("No executed SQL yet").foregroundStyle(LitheTheme.secondaryText)
                    } else {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    DatabaseLocalization.statementKind(entry.kind)
                                    Spacer()
                                    Text("\(entry.durationMilliseconds) ms")
                                        .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                                        .foregroundStyle(LitheTheme.secondaryText)
                                }
                                Text(entry.sql.replacingOccurrences(of: "\n", with: " "))
                                    .font(LitheTheme.uiFont(size: 10, design: .monospaced))
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .lineLimit(1)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                Section("Recovery points") {
                    let points = feature.recoveryPoints.prefix(10)
                    if points.isEmpty { Text("No recovery point yet").foregroundStyle(LitheTheme.secondaryText) }
                    ForEach(points) { point in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                DatabaseLocalization.text(point.reason)
                                Text("\(point.byteCount) bytes")
                                    .font(LitheTheme.uiFont(size: 10.5, design: .monospaced))
                                    .foregroundStyle(LitheTheme.secondaryText)
                            }
                            Spacer()
                            Button { pendingRollback = point; showsRollbackConfirmation = true } label: { Image(systemName: "arrow.uturn.backward") }
                                .litheIconButton().help("Restore recovery point")
                        }
                    }
                }
                Section("Audit") {
                    let entries = feature.auditEntries
                        .filter { $0.profileID == feature.selectedProfileID }
                        .prefix(10)
                    if entries.isEmpty {
                        Text("No audit entries yet").foregroundStyle(LitheTheme.secondaryText)
                    }
                    ForEach(entries) { entry in
                        HStack {
                            Image(systemName: entry.succeeded ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(entry.succeeded ? LitheTheme.success : LitheTheme.error)
                            DatabaseLocalization.text(entry.summary)
                            Spacer()
                            DatabaseLocalization.auditAction(entry.action).foregroundStyle(LitheTheme.secondaryText)
                        }
                    }
                }
            }
            .listStyle(.inset)
            if let result = feature.lastDiagnostics {
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                let columns = result.columns ?? result.rows.reduce(into: [String]()) { columns, row in
                    for key in row.keys where !columns.contains(key) { columns.append(key) }
                }
                DatabaseQueryResultGrid(columns: columns, rows: result.rows)
                    .frame(minHeight: 170)
            }
        }
        .alert("Restore recovery point?", isPresented: $showsRollbackConfirmation, presenting: pendingRollback) { point in
            Button("Cancel", role: .cancel) { pendingRollback = nil }
            Button("Restore", role: .destructive) {
                Task { _ = await feature.rollback(to: point) }
                pendingRollback = nil
            }
        } message: { point in
            Text("This will restore the saved SQL snapshot from \(point.reason). Current data may be overwritten.")
        }
        .sheet(isPresented: $showsBackupSchedule) {
            if let profile = feature.selectedProfile {
                DatabaseBackupScheduleEditor(profile: profile)
                    .environment(\.locale, model.settings.language.locale)
                    .id(model.settings.language)
            }
        }
    }

    private func loadDiagnostics() {
        Task {
            _ = await feature.loadDiagnostics(DatabaseDiagnosticsRequest(kind: diagnosticKind, schema: "", table: feature.selectedTable ?? ""))
        }
    }
}

private struct DatabaseBackupScheduleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var feature: DatabaseFeatureModel
    let profile: DatabaseProfile
    @State private var enabled = true
    @State private var intervalHours = 24
    @State private var retentionCount = 14

    var body: some View {
        VStack(spacing: 0) {
            Text("Backup Schedule").font(LitheTheme.uiFont(size: 15, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            Form {
                LabeledContent("Connection") { Text(profile.name) }
                Toggle("Enable scheduled backups", isOn: $enabled)
                Stepper(value: $intervalHours, in: 1...720) {
                    Text("Backup interval: \(intervalHours) hours")
                }
                Stepper("Keep \(retentionCount) recovery points", value: $retentionCount, in: 1...365)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    feature.configureBackupSchedule(profileID: profile.id, isEnabled: enabled, intervalHours: intervalHours, retentionCount: retentionCount)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 420, height: 280)
        .onAppear {
            if let schedule = feature.backupSchedules.first(where: { $0.profileID == profile.id }) {
                enabled = schedule.isEnabled
                intervalHours = schedule.intervalHours
                retentionCount = schedule.retentionCount
            }
        }
    }
}

private struct SQLSyntaxEditor: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    let completions: [String]
    let onRun: () -> Void
    let onSelectionChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, completions: completions, onRun: onRun, onSelectionChange: onSelectionChange) }

    func makeNSView(context: Context) -> NSScrollView {
        let isDark = colorScheme == .dark
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        let textView = SQLTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 240))
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = LitheTheme.editorFont(size: 13)
        applyAppearance(to: textView, in: scrollView, isDark: isDark)
        textView.textContainerInset = NSSize(width: 11, height: 9)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.completionItems = completions
        textView.onRun = onRun
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.textView = textView
        context.coordinator.isDarkAppearance = isDark
        context.coordinator.highlight()
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SQLTextView else { return }
        let isDark = colorScheme == .dark
        let appearanceChanged = context.coordinator.isDarkAppearance != isDark
        context.coordinator.isDarkAppearance = isDark
        context.coordinator.completions = completions
        context.coordinator.onSelectionChange = onSelectionChange
        textView.completionItems = completions
        textView.onRun = onRun
        if appearanceChanged {
            applyAppearance(to: textView, in: scrollView, isDark: isDark)
            context.coordinator.highlight()
        }
        if textView.string != text, !textView.hasMarkedText(), !context.coordinator.isApplyingChange {
            let selection = textView.selectedRange()
            textView.string = text
            let location = min(selection.location, text.utf16.count)
            let length = min(selection.length, text.utf16.count - location)
            textView.setSelectedRange(NSRange(location: location, length: length))
            context.coordinator.highlight()
        }
    }

    private func applyAppearance(to textView: NSTextView, in scrollView: NSScrollView, isDark: Bool) {
        let background = NSColor(LitheTheme.editor)
        let foreground = NSColor(LitheTheme.primaryText)
        scrollView.backgroundColor = background
        textView.backgroundColor = background
        textView.textColor = foreground
        textView.insertionPointColor = foreground
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(LitheTheme.selection),
            .foregroundColor: foreground
        ]
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>
        var completions: [String]
        let onRun: () -> Void
        var onSelectionChange: (String) -> Void
        weak var textView: SQLTextView?
        var isApplyingChange = false
        var isDarkAppearance = true

        init(text: Binding<String>, completions: [String], onRun: @escaping () -> Void, onSelectionChange: @escaping (String) -> Void) {
            self.text = text
            self.completions = completions
            self.onRun = onRun
            self.onSelectionChange = onSelectionChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            isApplyingChange = true
            text.wrappedValue = textView.string
            highlight()
            isApplyingChange = false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            let range = textView.selectedRange()
            guard range.length > 0, range.location + range.length <= textView.string.utf16.count else {
                onSelectionChange("")
                return
            }
            onSelectionChange((textView.string as NSString).substring(with: range))
        }

        func textView(
            _ textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            let prefix = (textView.string as NSString).substring(with: charRange).lowercased()
            let matches = completions.filter { $0.lowercased().hasPrefix(prefix) }
            if let index { index.pointee = 0 }
            return matches
        }

        func highlight() {
            guard let storage = textView?.textStorage else { return }
            SQLSyntaxHighlighter.apply(to: storage, isDark: isDarkAppearance)
        }
    }
}

private final class SQLTextView: NSTextView {
    var completionItems: [String] = []
    var onRun: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if (modifiers == .command && event.keyCode == 36) || (modifiers == .command && event.keyCode == 76) {
            onRun?()
            return
        }
        if modifiers == .control, event.keyCode == 49 {
            complete(nil)
            return
        }
        super.keyDown(with: event)
    }
}

private enum SQLSyntaxHighlighter {
    static func apply(to storage: NSTextStorage, isDark: Bool) {
        let range = NSRange(location: 0, length: storage.length)
        let textColor = NSColor(LitheTheme.primaryText)
        storage.beginEditing()
        storage.setAttributes([
            .font: LitheTheme.editorFont(size: 13),
            .foregroundColor: textColor
        ], range: range)
        apply(pattern: "(?i)\\b(SELECT|FROM|WHERE|INSERT|INTO|VALUES|UPDATE|DELETE|MERGE|REPLACE|CREATE|ALTER|DROP|TRUNCATE|TABLE|VIEW|INDEX|DATABASE|SCHEMA|TRIGGER|PROCEDURE|FUNCTION|JOIN|LEFT|RIGHT|INNER|OUTER|ON|AS|AND|OR|NOT|NULL|IS|IN|EXISTS|BETWEEN|LIKE|DISTINCT|GROUP|BY|ORDER|HAVING|LIMIT|OFFSET|UNION|ALL|WITH|RETURNING|SET|SHOW|DESCRIBE|DESC|EXPLAIN|PRAGMA|BEGIN|COMMIT|ROLLBACK|GRANT|REVOKE)\\b", color: NSColor(LitheTheme.accent), in: storage)
        apply(pattern: "\\b\\d+(?:\\.\\d+)?\\b", color: NSColor(LitheTheme.warning), in: storage)
        apply(pattern: "'(?:''|[^'])*'|\\\"(?:\\\"\\\"|[^\\\"])*\\\"|`(?:``|[^`])*`", color: NSColor(LitheTheme.success), in: storage)
        apply(pattern: "--[^\\n]*|/\\*[\\s\\S]*?\\*/", color: NSColor(LitheTheme.secondaryText), in: storage)
        storage.endEditing()
    }

    private static func apply(pattern: String, color: NSColor, in storage: NSTextStorage) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(location: 0, length: storage.length)
        for match in expression.matches(in: storage.string, range: range) {
            storage.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}

/// Overview uses the existing database state; closing its tab does not release connections or drafts.
struct DatabaseOverviewView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var feature: DatabaseFeatureModel
    @State private var showsConnectionEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 24) {
                    statistic("Connections", value: feature.profiles.count)
                    statistic("Connected", value: feature.connectedProfileCount)
                    statistic("Database types", value: Set(feature.profiles.map(\.kind)).count)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                LitheToolWindowHeaderDivider()
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        quickStart.frame(minWidth: 300, maxWidth: .infinity)
                        commonActions.frame(width: 240)
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        quickStart
                        commonActions
                    }
                }
                recentSQL
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .litheScrollViewChrome()
        .litheWorkbenchSurface(LitheTheme.editor)
        .background(LitheCenteredPopup(isPresented: $showsConnectionEditor,
                                       dialogTitle: String(localized: "Add Database Connection")) {
            DatabaseConnectionEditor(isPresented: $showsConnectionEditor)
                .environment(\.locale, model.settings.language.locale)
                .id(model.settings.language)
        })
    }

    private func statistic(_ title: LocalizedStringKey, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(LitheTheme.uiFont(size: 12))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(value.formatted()).font(LitheTheme.uiFont(size: 22, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quickStart: some View {
        VStack(alignment: .leading, spacing: 0) {
            LitheToolWindowHeader(title: "Quick Start")
            LitheToolWindowHeaderDivider()
            if feature.profiles.isEmpty {
                Text("No saved connections yet.")
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .padding(12)
            } else {
                ForEach(feature.profiles) { profile in
                    Button { open(profile, query: false) } label: {
                        HStack(spacing: 10) {
                            DatabaseBrandIcon(kind: profile.kind, size: LitheTheme.Metrics.toolbarIconSize)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name).foregroundStyle(LitheTheme.primaryText)
                                Text(profile.kind == .sqlite ? profile.path : "\(profile.host):\(profile.port)")
                                    .foregroundStyle(LitheTheme.secondaryText)
                            }
                            .lineLimit(1)
                            Spacer()
                            status(profile)
                        }
                        .font(LitheTheme.uiFont(size: 12))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.litheNoPress)
                    .litheRowHover()
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var commonActions: some View {
        VStack(alignment: .leading, spacing: 0) {
            LitheToolWindowHeader(title: "Common Actions")
            LitheToolWindowHeaderDivider()
            action("New Connection", icon: "expui/general/add.svg") { showsConnectionEditor = true }
            action("New Query", icon: "expui/fileTypes/shell.svg",
                   enabled: feature.profiles.contains { $0.kind.isSQLDatabase }) {
                if let profile = feature.selectedProfile.flatMap({ $0.kind.isSQLDatabase ? $0 : nil })
                    ?? feature.profiles.first(where: { $0.kind.isSQLDatabase }) {
                    open(profile, query: true)
                }
            }
            action("Browse Database", icon: "expui/toolwindows/toolWindowDataView@20x20.svg",
                   enabled: !feature.profiles.isEmpty) {
                if let profile = feature.selectedProfile ?? feature.profiles.first { open(profile, query: false) }
            }
            action("History", icon: "expui/general/history.svg") { openHistory() }
        }
    }

    private var recentSQL: some View {
        VStack(alignment: .leading, spacing: 0) {
            LitheToolWindowHeader(title: "Recent SQL") {
                Button { openHistory() } label: {
                    LitheIDEAIcon(resourcePath: "expui/general/history.svg", size: LitheTheme.Metrics.toolbarIconSize,
                                  preservesOriginalColors: true)
                }
                .litheToolbarIconButton().workbenchHoverHelp(Text("SQL History"))
                .accessibilityLabel("SQL History")
            }
            LitheToolWindowHeaderDivider()
            if feature.sqlHistory.isEmpty {
                Text("No SQL history yet.")
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .padding(12)
            } else {
                ForEach(Array(feature.sqlHistory.prefix(8))) { entry in
                    Button {
                        if let profile = feature.profiles.first(where: { $0.id == entry.profileID }) {
                            open(profile, query: true, history: entry)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text(entry.sql.replacingOccurrences(of: "\n", with: " "))
                                .font(LitheTheme.uiFont(size: 12, design: .monospaced))
                                .foregroundStyle(LitheTheme.primaryText)
                                .lineLimit(1)
                            Spacer()
                            Text(entry.executedAt, style: .relative)
                                .font(LitheTheme.uiFont(size: 11))
                                .foregroundStyle(LitheTheme.secondaryText)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.litheNoPress)
                    .litheRowHover(hoverBackground: feature.profiles.first(where: { $0.id == entry.profileID })?.kind.isSQLDatabase == true ? LitheTheme.hoverBackground : .clear)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(feature.profiles.first(where: { $0.id == entry.profileID })?.kind.isSQLDatabase != true)
                }
            }
        }
        .workbenchHoverTooltipScope()
    }

    private func action(_ title: LocalizedStringKey, icon: String, enabled: Bool = true,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 10) {
                LitheIDEAIcon(resourcePath: icon, size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
                Text(title).font(LitheTheme.uiFont(size: 12))
            }
            .foregroundStyle(enabled ? LitheTheme.primaryText : LitheTheme.tertiaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .litheRowHover(hoverBackground: enabled ? LitheTheme.hoverBackground : .clear)
        .disabled(!enabled)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func status(_ profile: DatabaseProfile) -> some View {
        switch feature.connectionStatus(for: profile) {
        case .idle: Text("Not connected").foregroundStyle(LitheTheme.secondaryText)
        case .connecting: Text("Connecting").foregroundStyle(LitheTheme.secondaryText)
        case .connected: Text("Connected").foregroundStyle(LitheTheme.success)
        case .failed: Text("Connection failed").foregroundStyle(LitheTheme.warning)
        }
    }

    private func openHistory() {
        feature.workspaceSection = .history
        model.openDatabaseWorkspace()
    }

    private func open(_ profile: DatabaseProfile, query: Bool, history: DatabaseSQLHistoryEntry? = nil) {
        Task {
            if feature.selectedProfileID != profile.id { await feature.select(profile) }
            guard feature.selectedProfileID == profile.id, model.databaseFeatureIfActive === feature else { return }
            if let history { feature.restoreSQLHistory(history) }
            else if query { feature.addSQLTab() }
            feature.workspaceSection = query ? .sql : .data
            model.openDatabaseWorkspace()
        }
    }
}
