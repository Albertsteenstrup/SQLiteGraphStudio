import Observation
import SwiftUI

public struct TableWorkspaceView: View {
    @Bindable private var session: AppSession
    @State private var pendingColumnDrop: TableColumn?

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
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tablecells")
                .font(.system(size: 36))
                .foregroundStyle(StudioPalette.secondaryText)

            Text("Open a table from the toolbar, the schema graph, or the context menu.")
                .foregroundStyle(StudioPalette.secondaryText)

            if session.hasOpenDatabase {
                HStack(spacing: 10) {
                    Button("Open Table") {
                        session.showTablePicker()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StudioPalette.accent)

                    Button("Create Table") {
                        session.showCreateTable()
                    }
                    .buttonStyle(.bordered)
                    .tint(StudioPalette.accent)
                    .disabled(!session.databaseCapabilities.canCreateTable)
                }
            }
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(session.openTabs) { tab in
                    Button {
                        session.selectTab(id: tab.id)
                    } label: {
                        let tableDescription = session.tableDescription(for: tab.descriptor.name)
                        HStack(spacing: 8) {
                            if let tableDescription {
                                DescribedTableNameText(
                                    title: tab.title,
                                    description: tableDescription,
                                    font: .body
                                )
                            } else {
                                Text(tab.title)
                                    .lineLimit(1)
                                    .foregroundStyle(StudioPalette.primaryText)
                            }

                            Button {
                                session.closeTab(id: tab.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2.bold())
                                    .foregroundStyle(StudioPalette.secondaryText)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(session.activeTabID == tab.id ? StudioPalette.selectionSurfaceTop : StudioPalette.headerSurface.opacity(0.84))
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(session.activeTabID == tab.id ? StudioPalette.border : StudioPalette.borderSoft)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func tableContent(for activeTab: TableTabModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header(for: activeTab)
            schemaMetadataStrip(for: activeTab.descriptor)

            if let error = activeTab.inlineErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.red.opacity(0.9))
            }

            TableGridRepresentable(
                tab: activeTab,
                revision: activeTab.revision,
                columnDescription: { columnName in
                    session.columnDescription(for: activeTab.descriptor.name, column: columnName)
                },
                requestColumnDrop: { column in
                    pendingColumnDrop = column
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StudioPalette.gridSurface.opacity(0.96))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(StudioPalette.borderSoft)
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

    private func header(for activeTab: TableTabModel) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
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
                }
                HStack(spacing: 8) {
                    Text(activeTab.descriptor.isEditable ? "Editable table" : "Read-only table")
                    Text(activeTab.rowCountLabel)
                }
                .font(.caption)
                .foregroundStyle(StudioPalette.secondaryText)
            }

            Spacer()

            HStack(spacing: 8) {
                TextField(
                    "Search rows",
                    text: Binding(
                        get: { activeTab.queryState.searchText },
                        set: { activeTab.queryState.searchText = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    activeTab.updateSearch(activeTab.queryState.searchText)
                }

                if activeTab.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(StudioPalette.accent)
                }

                Button {
                    activeTab.updateSearch(activeTab.queryState.searchText)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(StudioPalette.accent)
                .help("Search rows")

                Button {
                    Task { await activeTab.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(StudioPalette.accent)
                .help("Refresh table")

                Menu {
                    Button {
                        session.showAlterTable()
                    } label: {
                        Label("Alter Table", systemImage: "slider.horizontal.3")
                    }
                    .disabled(!session.databaseCapabilities.canAlterSchema)

                    Divider()

                    Button {
                        session.importRowsIntoActiveTable(format: .csv)
                    } label: {
                        Label("Import CSV", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!session.databaseCapabilities.canImportRows || !activeTab.isEditable)

                    Button {
                        session.importRowsIntoActiveTable(format: .json)
                    } label: {
                        Label("Import JSON", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!session.databaseCapabilities.canImportRows || !activeTab.isEditable)

                    Divider()

                    Button {
                        session.exportActiveTableRows(format: .csv)
                    } label: {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        session.exportActiveTableRows(format: .json)
                    } label: {
                        Label("Export JSON", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(StudioPalette.accent)
                .help("More actions")
            }
        }
    }

    private func schemaMetadataStrip(for descriptor: EditableTableDescriptor) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                metadataMenu(
                    "\(descriptor.indexes.count) indexes",
                    systemImage: "list.bullet.rectangle",
                    items: descriptor.indexes.map { "\($0.name): \($0.columns.joined(separator: ", "))" }
                )
                metadataMenu(
                    "\(descriptor.triggers.count) triggers",
                    systemImage: "bolt",
                    items: descriptor.triggers.map(\.name)
                )
                metadataMenu(
                    "\(descriptor.constraints.count) constraints",
                    systemImage: "checkmark.seal",
                    items: descriptor.constraints.map(\.detail)
                )
                metadataMenu(
                    "\(descriptor.generatedColumns.count) generated",
                    systemImage: "function",
                    items: descriptor.generatedColumns.map { "\($0.name): \($0.storedKind)" }
                )
                metadataMenu(
                    "\(descriptor.identityColumns.count) identity",
                    systemImage: "person.badge.key",
                    items: descriptor.identityColumns.compactMap { column in
                        column.identityLabel.map { "\(column.name): \($0)" }
                    }
                )
            }
            .padding(.bottom, 2)
        }
    }

    private func metadataMenu(_ title: String, systemImage: String, items: [String]) -> some View {
        Menu {
            if items.isEmpty {
                Text("None")
            } else {
                ForEach(items, id: \.self) { item in
                    Text(item)
                }
            }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(StudioPalette.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(StudioPalette.headerSurface.opacity(0.72), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
