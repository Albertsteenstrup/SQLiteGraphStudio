import Observation
import SwiftUI

public struct TableWorkspaceView: View {
    @Bindable private var session: AppSession
    @State private var pendingColumnDrop: TableColumn?
    @State private var showsFilters = false
    @FocusState private var isSearchFocused: Bool

    public init(session: AppSession) {
        self.session = session
    }

    public var body: some View {
        Group {
            if session.openTabs.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    tabStrip

                    Divider()
                        .overlay(StudioPalette.divider)

                    if let activeTab = session.activeTab {
                        tableContent(for: activeTab)
                    }
                }
            }
        }
        .padding(18)
        .studioSurface(.light)
        .defaultFocus($isSearchFocused, false)
        .onChange(of: session.activeTabID) { _, _ in isSearchFocused = false }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tablecells")
                .font(.system(size: 36))
                .foregroundStyle(StudioPalette.secondaryText)

            Text("Choose a table below or double-click it in the schema graph.")
                .foregroundStyle(StudioPalette.secondaryText)

            if session.hasOpenDatabase {
                HStack(spacing: 8) {
                    Button("Open Table") {
                        session.showTablePicker()
                    }
                    .buttonStyle(.studioPrimary)

                    if session.databaseCapabilities.canCreateTable {
                        Button("Create Table") { session.showCreateTable() }
                            .buttonStyle(.studio)
                    }
                }
            }
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(session.openTabs) { tab in
                    Button {
                        session.selectTab(id: tab.id)
                    } label: {
                        let tableDescription = session.tableDescription(for: tab.descriptor.name)
                        HStack(spacing: 4) {
                            if let tableDescription {
                                DescribedTableNameText(
                                    title: tab.title,
                                    description: tableDescription,
                                    font: .system(size: 12.5, weight: session.activeTabID == tab.id ? .medium : .regular)
                                )
                            } else {
                                Text(tab.title)
                                    .lineLimit(1)
                            }

                            StudioTabCloseButton(title: "Close \(tab.title)") {
                                session.closeTab(id: tab.id)
                            }
                        }
                        .studioTabChrome(isActive: session.activeTabID == tab.id)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func tableContent(for activeTab: TableTabModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(for: activeTab)
            if session.databaseCapabilities.canBrowseRows {
                rowControls(for: activeTab)
            } else {
                // A model replayed from migration files has structure but no data.
                Label(
                    session.databaseTarget?.isMigrationModel == true
                        ? "Schema only — this model comes from migration files, so there are no rows to browse."
                        : "Schema only — this document has structure but no rows to browse.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(StudioPalette.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: StudioCornerRadius.surface, style: .continuous).fill(StudioPalette.headerSurface))
                .overlay { RoundedRectangle(cornerRadius: StudioCornerRadius.surface, style: .continuous).stroke(StudioPalette.borderSoft) }
            }
            schemaMetadataStrip(for: activeTab.descriptor)

            if session.databaseCapabilities.canBrowseRows, let error = activeTab.inlineErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.red.opacity(0.9))
            }

            if session.databaseCapabilities.canBrowseRows {
                TableGridRepresentable(
                    tab: activeTab,
                    revision: activeTab.revision,
                    columnDescription: { columnName in
                        session.columnDescription(for: activeTab.descriptor.name, column: columnName)
                    },
                    requestColumnDrop: { column in
                        pendingColumnDrop = column
                    },
                    inspectRow: { session.inspectRecord(in: activeTab, row: $0) },
                    inspectCellSlice: { row, columnName in
                        session.inspectCellSlice(in: activeTab, row: row, columnName: columnName)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(StudioPalette.gridSurface.opacity(0.96))
                .clipShape(RoundedRectangle(cornerRadius: StudioCornerRadius.surface, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: StudioCornerRadius.surface, style: .continuous)
                        .stroke(StudioPalette.borderSoft)
                }
            } else {
                schemaOnlyColumnList(for: activeTab.descriptor)
            }
        }
        .padding(20)
        .alert(
            "Database Busy",
            isPresented: Binding(
                get: { activeTab.busyError != nil },
                set: { newValue in
                    if !newValue {
                        activeTab.clearBusyError()
                    }
                }
            ),
            actions: {
                Button("Cancel", role: .cancel) {
                    activeTab.clearBusyError()
                }
                Button("Retry") {
                    activeTab.retryPendingEdit()
                }
            },
            message: {
                Text(activeTab.busyError?.message ?? "The database is busy.")
            }
        )
        .alert(
            "Drop Column",
            isPresented: Binding(
                get: { pendingColumnDrop != nil },
                set: { newValue in
                    if !newValue {
                        pendingColumnDrop = nil
                    }
                }
            ),
            presenting: pendingColumnDrop,
            actions: { column in
                Button("Cancel", role: .cancel) {
                    pendingColumnDrop = nil
                }
                Button("Drop \(column.name)", role: .destructive) {
                    Task {
                        do {
                            try await activeTab.dropColumn(column.name)
                            pendingColumnDrop = nil
                            session.refreshSchema()
                        } catch {
                            session.presentedError = SQLiteUserError.from(error)
                        }
                    }
                }
            },
            message: { column in
                Text("This changes the schema and removes `\(column.name)` from `\(activeTab.title)`.")
            }
        )
    }

    /// Search and filter on the left, paging on the right: one quiet row instead
    /// of a row of bezeled push buttons.
    private func rowControls(for activeTab: TableTabModel) -> some View {
        HStack(spacing: 8) {
            searchField(for: activeTab)
                .frame(minWidth: 120, maxWidth: 340)

            Button { showsFilters = true } label: {
                let filterCount = activeTab.queryState.sanitizedFilters.count
                Label(
                    filterCount == 0 ? "Filter" : "Filter · \(filterCount)",
                    systemImage: "line.3.horizontal.decrease"
                )
            }
            .buttonStyle(StudioButtonStyle(activeTab.hasColumnFilters ? .secondary : .quiet))
            .fixedSize()
            .help(activeTab.hasColumnFilters ? "Edit column filters" : "Filter rows by column")
            .popover(isPresented: $showsFilters, arrowEdge: .bottom) {
                TableFilterEditor(tab: activeTab).id(activeTab.id)
            }

            Spacer(minLength: 8)

            if activeTab.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(StudioPalette.accent)
            }

            pager(for: activeTab)
        }
    }

    private func searchField(for activeTab: TableTabModel) -> some View {
        HStack(spacing: 6) {
            Button {
                activeTab.updateSearch(activeTab.queryState.searchText)
                isSearchFocused = false
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(StudioPalette.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Search rows")
            .accessibilityLabel("Search rows")

            TextField(
                "Search rows",
                text: Binding(
                    get: { activeTab.queryState.searchText },
                    set: { activeTab.queryState.searchText = $0 }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .focused($isSearchFocused)
            .background(SearchFieldFocusDismissal(isFocused: isSearchFocused) { isSearchFocused = false })
            .onExitCommand { isSearchFocused = false }
            .onSubmit {
                activeTab.updateSearch(activeTab.queryState.searchText)
                isSearchFocused = false
            }

            if !activeTab.queryState.searchText.isEmpty {
                Button {
                    activeTab.updateSearch("")
                    isSearchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(StudioPalette.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("Clear row search")
                .accessibilityLabel("Clear row search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Capsule().fill(Color.black.opacity(isSearchFocused ? 0.03 : 0.045)))
        .overlay {
            Capsule().stroke(Color.black.opacity(isSearchFocused ? 0.16 : 0), lineWidth: 1)
        }
        // The borderless field sits on the always-light pane, so its text and
        // placeholder must stay dark in Dark Mode too.
        .environment(\.colorScheme, .light)
        .animation(.easeOut(duration: 0.12), value: isSearchFocused)
    }

    private func pager(for activeTab: TableTabModel) -> some View {
        HStack(spacing: 0) {
            Button { activeTab.previousPage() } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(activeTab.chunk.offset == 0 || activeTab.isLoading)
            .help("Previous page")
            .accessibilityLabel("Previous page")

            Text(activeTab.chunk.rows.isEmpty
                 ? "No rows"
                 : "\(activeTab.chunk.offset + 1)–\(activeTab.chunk.rowRange.upperBound)")
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(StudioPalette.secondaryText)
                .padding(.horizontal, 6)
                .help("Loaded rows")

            Button { activeTab.nextPage() } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!activeTab.chunk.hasMore || activeTab.isLoading)
            .help("Next page")
            .accessibilityLabel("Next page")
        }
        .buttonStyle(.studioIcon)
        .controlSize(.small)
        .padding(2)
        .background(Capsule().fill(Color.black.opacity(0.045)))
        .fixedSize()
    }

    private func header(for activeTab: TableTabModel) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                let tableDescription = session.tableDescription(for: activeTab.descriptor.name)
                if let tableDescription {
                    DescribedTableNameText(
                        title: activeTab.title,
                        description: tableDescription,
                        font: .title3.weight(.semibold)
                    )
                } else {
                    Text(activeTab.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(StudioPalette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(activeTab.descriptor.name)
                }
                HStack(spacing: 6) {
                    Text(activeTab.descriptor.isEditable ? "Editable" : "Read-only")
                    Text("·").foregroundStyle(StudioPalette.tertiaryText)
                    // A schema-only model has no row count to report, and zero
                    // would read as a claim that the table is empty.
                    if session.databaseCapabilities.canBrowseRows {
                        Text(activeTab.rowCountLabel)
                            .monospacedDigit()
                        Button("Count exactly") { activeTab.countExactly() }
                            .buttonStyle(.studioQuiet)
                            .controlSize(.mini)
                            .disabled(activeTab.isLoading)
                            .help("Count every matching row")
                    } else {
                        Text("schema only")
                    }
                }
                .font(.caption)
                .foregroundStyle(StudioPalette.secondaryText)
            }

            Spacer(minLength: 12)

            if session.databaseCapabilities.canBrowseRows {
                Button {
                    activeTab.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.studioIcon)
                .help("Refresh table")
                .accessibilityLabel("Refresh table")

                StudioMenu(.quiet, iconOnly: true) {
                    if session.databaseCapabilities.canAlterSchema {
                        StudioMenuItem("Alter Table", systemImage: "slider.horizontal.3") {
                            session.showAlterTable()
                        }
                    }
                    if session.databaseCapabilities.canImportRows && activeTab.isEditable {
                        StudioMenuItem("Import CSV", systemImage: "square.and.arrow.down") {
                            session.importRowsIntoActiveTable(format: .csv)
                        }
                        StudioMenuItem("Import JSON", systemImage: "square.and.arrow.down") {
                            session.importRowsIntoActiveTable(format: .json)
                        }
                        StudioMenuDivider()
                    }

                    StudioSubmenu("Export loaded rows (\(activeTab.chunk.rows.count))", systemImage: "square.and.arrow.up") {
                        StudioMenuItem("CSV…") { session.exportActiveTableRows(format: .csv, scope: .loadedRows) }
                        StudioMenuItem("JSON…") { session.exportActiveTableRows(format: .json, scope: .loadedRows) }
                    }
                    .disabled(session.exportProgress?.isRunning == true)
                    StudioSubmenu("Export all matching rows", systemImage: "square.and.arrow.up") {
                        StudioMenuItem("CSV…") { session.exportActiveTableRows(format: .csv, scope: .allMatchingRows) }
                        StudioMenuItem("JSON…") { session.exportActiveTableRows(format: .json, scope: .allMatchingRows) }
                    }
                    .disabled(session.exportProgress?.isRunning == true)
                } label: {
                    Label("More actions", systemImage: "ellipsis")
                }
                .help("More actions")
            }
        }
    }

    private func schemaMetadataStrip(for descriptor: EditableTableDescriptor) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                SchemaMetadataChip(
                    title: "Indexes", singular: "index", plural: "indexes", systemImage: "list.bullet.rectangle",
                    items: descriptor.indexes.map { index in
                        StudioListItem(
                            id: index.id,
                            title: index.name,
                            detail: index.columns.joined(separator: ", "),
                            tag: index.isUnique ? "unique" : index.isPartial ? "partial" : nil
                        )
                    }
                )
                SchemaMetadataChip(
                    title: "Triggers", singular: "trigger", plural: "triggers", systemImage: "bolt",
                    items: descriptor.triggers.map { StudioListItem(id: $0.id, title: $0.name) }
                )
                SchemaMetadataChip(
                    title: "Constraints", singular: "constraint", plural: "constraints", systemImage: "checkmark.seal",
                    items: descriptor.constraints.map { constraint in
                        StudioListItem(
                            id: constraint.id,
                            title: constraint.columns.isEmpty
                                ? constraint.name ?? constraint.kind.title
                                : constraint.columns.joined(separator: ", "),
                            detail: constraint.kind.detailAddsInformation ? constraint.detail : nil,
                            tag: constraint.kind.title.lowercased()
                        )
                    }
                )
                SchemaMetadataChip(
                    title: "Generated columns", singular: "generated", plural: "generated", systemImage: "function",
                    items: descriptor.generatedColumns.map { StudioListItem(id: $0.id, title: $0.name, detail: $0.storedKind) }
                )
                SchemaMetadataChip(
                    title: "Identity columns", singular: "identity", plural: "identity", systemImage: "person.badge.key",
                    items: descriptor.identityColumns.compactMap { column in
                        column.identityLabel.map { StudioListItem(id: column.id, title: column.name, detail: $0) }
                    }
                )
            }
            .controlSize(.small)
            .padding(.bottom, 2)
        }
        .padding(.leading, -8)
    }

    private func schemaOnlyColumnList(for descriptor: EditableTableDescriptor) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(descriptor.columns) { column in
                    VStack(alignment: .leading, spacing: 6) {
                        let details = [
                            column.primaryKeyOrdinal > 0 ? "Primary key" : nil,
                            column.notNull ? "Required" : "Nullable",
                            column.isGenerated ? "Generated" : nil,
                            column.identityLabel,
                            column.defaultValueSQL.map { "Default: \($0)" }
                        ].compactMap { $0 }

                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(column.name)
                                .font(.system(.body, design: .monospaced).weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(column.typeLabel)
                                .font(.caption.monospaced())
                                .foregroundStyle(StudioPalette.secondaryText)
                                .lineLimit(1)
                        }

                        Text(details.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(StudioPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                        if let description = session.columnDescription(for: descriptor.name, column: column.name) {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(StudioPalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    if column.id != descriptor.columns.last?.id {
                        Divider().overlay(StudioPalette.divider)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudioPalette.gridSurface.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: StudioCornerRadius.surface, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: StudioCornerRadius.surface, style: .continuous)
                .stroke(StudioPalette.borderSoft)
        }
    }

}

/// A count of one kind of schema object. Clicking it lists them; an empty kind
/// stays readable but inert.
private struct SchemaMetadataChip: View {
    let title: String
    let singular: String
    let plural: String
    let systemImage: String
    let items: [StudioListItem]
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text("\(items.count)").fontWeight(.semibold).monospacedDigit()
                    + Text(" \(items.count == 1 ? singular : plural)")
            }
        }
        .buttonStyle(.studioQuiet)
        .disabled(items.isEmpty)
        .fixedSize()
        .help(items.isEmpty ? "No \(plural)" : "Show \(plural)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            StudioPopoverList(title: title, items: items)
        }
    }
}

private extension SchemaConstraintKind {
    var title: String {
        switch self {
        case .primaryKey: "Primary key"
        case .foreignKey: "Foreign key"
        case .unique: "Unique"
        case .notNull: "Not null"
        case .defaultValue: "Default"
        case .check: "Check"
        }
    }

    /// Whether the SQL says more than the columns and kind already do.
    var detailAddsInformation: Bool {
        switch self {
        case .foreignKey, .defaultValue, .check: true
        case .primaryKey, .unique, .notNull: false
        }
    }
}

private struct DescribedTableNameText: View {
    let title: String
    let description: String
    let font: Font
    @State private var isHovering = false

    var body: some View {
        Text(title)
            .lineLimit(1)
            .font(font)
            .foregroundStyle(StudioPalette.primaryText)
            .underline(true, color: StudioPalette.primaryText.opacity(0.4))
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .popover(isPresented: $isHovering, arrowEdge: .top) {
                TableNameDescriptionTooltip(text: description)
            }
    }
}

private struct TableNameDescriptionTooltip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(StudioPalette.primaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: 230, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: StudioCornerRadius.surface, style: .continuous))
    }
}
