import Observation
import SwiftUI

public struct StudioRootView: View {
    @Bindable private var session: AppSession

    public init(session: AppSession) {
        self.session = session
    }

    public var body: some View {
        ZStack {
            rootBackground

            if session.hasOpenDatabase {
                if session.showAllGraphTableCards {
                    SchemaGraphView(session: session)
                        .padding(16)
                } else {
                    ZStack(alignment: .top) {
                        HSplitView {
                            WorkspacePaneContainer(session: session, side: .left)
                                .frame(minWidth: 380)

                            WorkspacePaneContainer(session: session, side: .right)
                                .frame(minWidth: 420)
                        }
                        .padding(16)

                        WorkspaceDockView(session: session)
                            .padding(.top, 18)
                    }
                }
            } else {
                EmptyDatabaseView(session: session)
                    .padding(24)
            }
        }
        .containerBackground(.thinMaterial, for: .window)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    session.presentOpenDatabasePanel()
                } label: {
                    Label("Open Database", systemImage: "folder")
                }

                Button {
                    session.refreshSchema()
                } label: {
                    Label("Refresh Schema", systemImage: "arrow.clockwise")
                }
                .disabled(!session.hasOpenDatabase)

                Button {
                    session.showTablePicker()
                } label: {
                    Label("Open Table", systemImage: "tablecells")
                }
                .disabled(session.tables.isEmpty)
            }
        }
        .sheet(isPresented: $session.isTablePickerPresented) {
            OpenTablePickerView(session: session)
        }
        .alert(
            "SQLite Error",
            isPresented: Binding(
                get: { session.presentedError != nil },
                set: { newValue in
                    if !newValue {
                        session.dismissError()
                    }
                }
            ),
            actions: {
                Button("OK") {
                    session.dismissError()
                }
            },
            message: {
                Text(session.presentedError?.message ?? "Unknown error")
            }
        )
    }

    private var rootBackground: some View {
        LinearGradient(
            colors: [
                StudioPalette.windowBackdropTop,
                StudioPalette.windowBackdropBottom,
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(Color.white.opacity(0.72))
                .frame(width: 360, height: 360)
                .blur(radius: 52)
                .offset(x: 96, y: -92)
        }
        .overlay(alignment: .bottomLeading) {
            Circle()
                .fill(Color.black.opacity(0.04))
                .frame(width: 320, height: 320)
                .blur(radius: 74)
                .offset(x: -92, y: 118)
        }
        .ignoresSafeArea()
    }
}

private struct WorkspacePaneContainer: View {
    @Bindable var session: AppSession
    let side: WorkspacePaneSide
    @State private var isDropTargeted = false

    private var paneState: WorkspacePaneState {
        session.paneState(for: side)
    }

    var body: some View {
        VStack(spacing: 0) {
            paneHeader

            Group {
                switch paneState.kind {
                case .schema:
                    SchemaGraphView(session: session)
                case .tables:
                    TableWorkspaceView(session: session)
                case .query:
                    QueryWorkspaceView(session: session)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(StudioPalette.chromeFill.opacity(0.88))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(borderColor, lineWidth: isDropTargeted || session.activePaneSide == side ? 1.4 : 1.0)
        }
        .contentShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .onTapGesture {
            session.setActivePaneSide(side)
        }
        .dropDestination(for: WorkspaceDockItem.self) { items, _ in
            guard let item = items.first else { return false }
            session.applyDockItem(item, to: side)
            return true
        } isTargeted: { isTargeted in
            self.isDropTargeted = isTargeted
        }
    }

    private var paneHeader: some View {
        HStack(spacing: 12) {
            Label(paneState.kind.title, systemImage: paneState.kind.systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(StudioPalette.primaryText)

            Spacer()

            Text(session.databaseDisplayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(StudioPalette.secondaryText)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill((isDropTargeted || session.activePaneSide == side) ? StudioPalette.chromeFillStrong : StudioPalette.chromeFill)
        )
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    private var borderColor: Color {
        if isDropTargeted {
            return StudioPalette.borderStrong
        }
        if session.activePaneSide == side {
            return StudioPalette.border
        }
        return StudioPalette.borderSoft
    }
}

private struct WorkspaceDockView: View {
    @Bindable var session: AppSession

    var body: some View {
        HStack(spacing: 10) {
            ForEach(PaneContentKind.allCases) { kind in
                WorkspaceDockPill(
                    kind: kind,
                    isVisible: session.side(containing: kind) != nil
                )
                .onTapGesture {
                    session.setPaneContent(kind, for: session.activePaneSide)
                }
                .draggable(WorkspaceDockItem(kind: kind))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .studioGlassCard(cornerRadius: 24, tint: Color.white, strokeOpacity: 0.12)
    }
}

private struct WorkspaceDockPill: View {
    let kind: PaneContentKind
    let isVisible: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: kind.systemImage)
                .font(.caption.weight(.semibold))
            Text(kind.title)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(isVisible ? StudioPalette.primaryText : StudioPalette.secondaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(isVisible ? StudioPalette.chromeFillStrong : StudioPalette.headerSurface.opacity(0.8))
        )
        .overlay {
            Capsule()
                .stroke(isVisible ? StudioPalette.border : StudioPalette.borderSoft, lineWidth: 1)
        }
    }
}

private struct OpenTablePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: AppSession
    @State private var searchText = ""
    @State private var selection: String?

    var filteredTables: [TableSummary] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return session.tables
        }

        return session.tables.filter { table in
            table.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open Table")
                .font(.title2.weight(.semibold))

            TextField("Search tables", text: $searchText)
                .textFieldStyle(.roundedBorder)

            List(filteredTables, id: \.id, selection: $selection) { table in
                VStack(alignment: .leading, spacing: 2) {
                    Text(table.name)
                    Text(table.isEditable ? "Editable" : "Read-only")
                        .font(.caption)
                        .foregroundStyle(StudioPalette.secondaryText)
                }
                .tag(Optional(table.name))
            }
            .frame(minWidth: 420, minHeight: 280)

            HStack {
                Spacer()

                Button("Cancel") {
                    session.dismissTablePicker()
                    dismiss()
                }

                Button("Open") {
                    if let selection {
                        session.openTable(named: selection)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(20)
        .onChange(of: session.isTablePickerPresented) { _, isPresented in
            if !isPresented {
                dismiss()
            }
        }
    }
}

private struct EmptyDatabaseView: View {
    @Bindable var session: AppSession

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(StudioPalette.primaryText)

            VStack(spacing: 8) {
                Text("Open a SQLite database")
                    .font(.system(size: 30, weight: .semibold))
                Text("Browse to a `.sqlite`, `.sqlite3`, or `.db` file to explore the schema, edit rows, and run SQL.")
                    .foregroundStyle(StudioPalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            HStack(spacing: 12) {
                Button {
                    session.presentOpenDatabasePanel()
                } label: {
                    Label("Choose Database", systemImage: "folder")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioPalette.accent)
                .controlSize(.large)

                Button {
                    session.presentOpenDatabasePanel()
                } label: {
                    Label("Browse Files", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .tint(StudioPalette.accent)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 42)
        .studioGlassCard(cornerRadius: 30, tint: Color.white, strokeOpacity: 0.14)
    }
}
