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
                Button("Open Table") {
                    session.showTablePicker()
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioPalette.accent)
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
                        HStack(spacing: 8) {
                            Text(tab.title)
                                .lineLimit(1)
                                .foregroundStyle(StudioPalette.primaryText)

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

            if let error = activeTab.inlineErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.red.opacity(0.9))
            }

            TableGridRepresentable(
                tab: activeTab,
                revision: activeTab.revision,
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
                Text("This alters the SQLite schema and removes `\(column.name)` from `\(activeTab.title)`.")
            }
        )
    }

    private func header(for activeTab: TableTabModel) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(activeTab.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(StudioPalette.primaryText)
                HStack(spacing: 8) {
                    Text(activeTab.descriptor.isEditable ? "Editable table" : "Read-only table")
                    Text(activeTab.rowCountLabel)
                }
                .font(.caption)
                .foregroundStyle(StudioPalette.secondaryText)
            }

            Spacer()

            HStack(spacing: 10) {
                TextField(
                    "Search rows",
                    text: Binding(
                        get: { activeTab.queryState.searchText },
                        set: { activeTab.queryState.searchText = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit {
                    activeTab.updateSearch(activeTab.queryState.searchText)
                }

                Button {
                    activeTab.updateSearch(activeTab.queryState.searchText)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(StudioPalette.accent)

                if activeTab.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(StudioPalette.accent)
                }

                Button {
                    Task { await activeTab.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(StudioPalette.accent)
            }
        }
    }
}
