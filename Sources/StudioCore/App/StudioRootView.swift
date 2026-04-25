import AppKit
import Observation
import SwiftUI

public struct StudioRootView: View {
    @Bindable private var session: AppSession
    @State private var isMinimapHovered = false

    public init(session: AppSession) {
        self.session = session
    }

    private var schemaIsVisible: Bool {
        if session.showAllGraphTableCards { return true }
        if let side = session.maximizedPaneSide {
            return session.paneState(for: side).kind == .schema
        }
        // In split-pane mode, show if either pane is schema
        return session.side(containing: .schema) != nil
    }

    public var body: some View {
        ZStack {
            rootBackground

            if session.hasOpenDatabase {
                if session.showAllGraphTableCards {
                    SchemaGraphView(session: session)
                        .padding(16)
                } else if let maximizedPaneSide = session.maximizedPaneSide {
                    MaximizedPaneView(session: session, side: maximizedPaneSide)
                        .padding(16)
                } else {
                    ZStack(alignment: .bottom) {
                        HSplitView {
                            WorkspacePaneContainer(session: session, side: .left)
                                .frame(minWidth: 380)

                            WorkspacePaneContainer(session: session, side: .right)
                                .frame(minWidth: 420)
                        }
                        .padding(16)

                        WorkspaceDockView(session: session)
                            .padding(.bottom, 18)
                    }
                }
            } else {
                EmptyDatabaseView(session: session)
                    .padding(24)
            }

            // Minimap — shown whenever the schema graph is visible and has nodes.
            // Rendered at the root ZStack level so it's never clipped by pane containers
            // and always appears above the dock nav.
            if session.hasOpenDatabase && !session.graph.nodes.isEmpty && schemaIsVisible {
                GeometryReader { geo in
                    GraphMinimapView(
                        session: session,
                        viewportSize: geo.size,
                        zoom: session.graphZoom,
                        pan: session.graphPan,
                        onViewportTap: { _ in }
                    )
                    .frame(width: 180, height: 120)
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .onHover { isHovered in isMinimapHovered = isHovered }
                    .zIndex(isMinimapHovered ? 1000 : 1)
                }
            }
        }
        .containerBackground(.thinMaterial, for: .window)
        .toolbar {
            ToolbarItem {
                Button {
                    session.presentOpenDatabasePanel()
                } label: {
                    Label("Open Database", systemImage: "folder")
                }
                .help("Open Database")
            }

            ToolbarItem {
                Button {
                    session.showProfileManager()
                } label: {
                    Label("Profiles", systemImage: "person.crop.rectangle.stack")
                }
                .help("Connection Profiles")
            }

            ToolbarItem {
                Button {
                    session.refreshSchema()
                } label: {
                    Label("Refresh Schema", systemImage: "arrow.clockwise")
                }
                .disabled(!session.hasOpenDatabase)
                .help("Refresh Schema")
            }

            ToolbarItem {
                Button {
                    session.showTablePicker()
                } label: {
                    Label("Open Table", systemImage: "tablecells")
                }
                .disabled(session.tables.isEmpty)
                .help("Open Table")
            }

            ToolbarItem {
                Button {
                    session.showCreateTable()
                } label: {
                    Label("Create Table", systemImage: "plus.square.on.square")
                }
                .disabled(!session.hasOpenDatabase)
                .help("Create Table")
            }

            ToolbarItem {
                Button {
                    session.showAlterTable()
                } label: {
                    Label("Alter Table", systemImage: "slider.horizontal.3")
                }
                .disabled(session.activeTab == nil)
                .help("Alter Active Table")
            }
        }
        .sheet(isPresented: $session.isTablePickerPresented) {
            OpenTablePickerView(session: session)
        }
        .sheet(isPresented: $session.isProfileManagerPresented) {
            ConnectionProfileManagerView(session: session)
        }
        .sheet(isPresented: $session.isCreateTablePresented) {
            CreateTableSheetView(session: session)
        }
        .sheet(isPresented: $session.isAlterTablePresented) {
            AlterTableSheetView(session: session)
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
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Spacer()
                    .frame(height: 58) // Reserve space for header
                
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
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            
            paneHeader
                .zIndex(100)
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
            if paneState.kind != .schema {
                Label(paneState.kind.title, systemImage: paneState.kind.systemImage)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(StudioPalette.primaryText)
            }

            Spacer()

            PaneHeaderIconButton(systemImage: "arrow.up.left.and.arrow.down.right", title: "Maximize pane") {
                session.toggleMaximizePane(side)
            }

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

private struct PaneHeaderIconButton: View {
    let systemImage: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudioPalette.secondaryText)
                .frame(width: 30, height: 30)
                .background(StudioPalette.headerSurface.opacity(0.72), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
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

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(filteredTables) { table in
                        Button {
                            selection = table.name
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(table.name)
                                        .foregroundStyle(StudioPalette.primaryText)
                                    Text(table.isEditable ? "Editable" : "Read-only")
                                        .font(.caption)
                                        .foregroundStyle(StudioPalette.secondaryText)
                                }
                                Spacer()
                                if selection == table.name {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(StudioPalette.primaryText)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(selection == table.name ? StudioPalette.selectionSurfaceTop : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
            }
            .frame(minWidth: 420, minHeight: 320, maxHeight: 420)
            .background(StudioPalette.gridSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(StudioPalette.borderSoft)
            }

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
        VStack(alignment: .leading, spacing: 22) {
            VStack(spacing: 14) {
                StudioAppLogoView()

                VStack(spacing: 8) {
                    Text("Open a SQLite database")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(StudioPalette.primaryText)
                    Text("Choose a `.sqlite`, `.sqlite3`, or `.db` file to explore the schema, edit rows, and run SQL.")
                        .foregroundStyle(StudioPalette.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }

                Button {
                    session.presentOpenDatabasePanel()
                } label: {
                    Label("Choose Database", systemImage: "folder")
                        .frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioPalette.accent)
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity)

            if !session.recentDatabaseURLs.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recent")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(StudioPalette.primaryText)

                    VStack(spacing: 10) {
                        ForEach(session.recentDatabaseURLs, id: \.path) { url in
                            Button {
                                session.openRecentDatabase(url)
                            } label: {
                                RecentDatabaseRow(url: url)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
            }
        }
        .frame(maxWidth: 620)
        .padding(.horizontal, 36)
        .padding(.vertical, 42)
        .studioGlassCard(cornerRadius: 30, tint: Color.white, strokeOpacity: 0.14)
    }
}

private struct StudioAppLogoView: View {
    private let appIcon = NSApplication.shared.applicationIconImage
        ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

    var body: some View {
        Image(nsImage: appIcon)
            .resizable()
            .interpolation(.high)
            .frame(width: 76, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: StudioPalette.shadow.opacity(0.18), radius: 18, y: 10)
    }
}

private struct RecentDatabaseRow: View {
    let url: URL

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StudioPalette.secondaryText)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(url.lastPathComponent)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudioPalette.primaryText)
                    .lineLimit(1)

                Text(url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(StudioPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Image(systemName: "arrow.up.forward.app")
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudioPalette.tertiaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StudioPalette.chromeFillStrong.opacity(0.72))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(StudioPalette.borderSoft)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct MaximizedPaneView: View {
    @Bindable var session: AppSession
    let side: WorkspacePaneSide

    private var kind: PaneContentKind {
        session.paneState(for: side).kind
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Spacer()
                    .frame(height: 58) // Reserve space for header

                Group {
                    switch kind {
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
                    .stroke(StudioPalette.border, lineWidth: 1.4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            // Note: clipShape is applied to the content VStack only, so maximizedHeader
            // and its menus can overflow the clip boundary without being clipped.

            maximizedHeader
                .zIndex(100)
        }
    }

    private var maximizedHeader: some View {
        HStack(spacing: 12) {
            Label(kind.title, systemImage: kind.systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(StudioPalette.primaryText)

            Spacer()

            Button {
                session.exitMaximizedMode()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.caption.weight(.semibold))
                    Text("Exit Full Screen")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(StudioPalette.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(StudioPalette.chromeFillStrong)
                )
                .overlay {
                    Capsule()
                        .stroke(StudioPalette.border, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)

            Text(session.databaseDisplayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(StudioPalette.secondaryText)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(StudioPalette.chromeFillStrong)
        )
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }
}

private struct ConnectionProfileManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: AppSession
    @State private var newProfileName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connection Profiles")
                .font(.title2.weight(.semibold))

            if session.hasOpenDatabase {
                HStack(spacing: 10) {
                    TextField("Profile name", text: $newProfileName)
                        .textFieldStyle(.roundedBorder)
                    Button("Save Current") {
                        session.saveCurrentConnectionProfile(name: newProfileName)
                        newProfileName = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StudioPalette.accent)
                }
            }

            if session.connectionProfiles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.rectangle.stack")
                        .font(.system(size: 28))
                        .foregroundStyle(StudioPalette.secondaryText)
                    Text("Save the current database as a reusable SQLite profile.")
                        .foregroundStyle(StudioPalette.secondaryText)
                }
                .frame(width: 520, height: 220)
            } else {
                List {
                    ForEach(session.connectionProfiles) { profile in
                        ConnectionProfileRow(session: session, profile: profile)
                    }
                }
                .frame(width: 560, height: 300)
            }

            HStack {
                Spacer()
                Button("Done") {
                    session.dismissProfileManager()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

private struct ConnectionProfileRow: View {
    @Bindable var session: AppSession
    let profile: DatabaseConnectionProfile
    @State private var name: String

    init(session: AppSession, profile: DatabaseConnectionProfile) {
        self.session = session
        self.profile = profile
        _name = State(initialValue: profile.name)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive")
                .foregroundStyle(StudioPalette.secondaryText)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                    .onSubmit {
                        session.renameConnectionProfile(profile, to: name)
                    }
                Text(profile.filePath)
                    .font(.caption)
                    .foregroundStyle(StudioPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button("Open") {
                session.openConnectionProfile(profile)
            }
            .buttonStyle(.bordered)
            .tint(StudioPalette.accent)

            Button(role: .destructive) {
                session.deleteConnectionProfile(profile)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 6)
    }
}

private struct CreateTableSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: AppSession
    @State private var draft = TableCreateDraft()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Table")
                .font(.title2.weight(.semibold))

            TextField("Table name", text: $draft.tableName)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Columns")
                        .font(.headline)
                    Spacer()
                    Button {
                        draft.columns.append(TableColumnDraft())
                    } label: {
                        Label("Add Column", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .tint(StudioPalette.accent)
                }

                ForEach($draft.columns) { $column in
                    HStack(spacing: 8) {
                        TextField("Name", text: $column.name)
                            .textFieldStyle(.roundedBorder)
                        TextField("Type", text: $column.type)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                        Toggle("PK", isOn: $column.isPrimaryKey)
                        Toggle("NN", isOn: $column.isNotNull)
                        TextField("Default SQL", text: $column.defaultValueSQL)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                    }
                }
            }

            TextEditor(text: .constant(session.createTableSQLPreview(for: draft)))
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 110)
                .scrollContentBackground(.hidden)
                .background(StudioPalette.editorSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack {
                Spacer()
                Button("Cancel") {
                    session.dismissCreateTable()
                    dismiss()
                }
                Button("Create") {
                    session.createTable(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioPalette.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 680)
    }
}

private struct AlterTableSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: AppSession
    @State private var tableName = ""
    @State private var selectedColumn = ""
    @State private var renamedColumn = ""
    @State private var newColumn = TableColumnDraft()

    private var descriptor: EditableTableDescriptor? {
        session.activeTab?.descriptor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Alter Table")
                .font(.title2.weight(.semibold))

            if let descriptor {
                HStack(spacing: 10) {
                    TextField("Table name", text: $tableName)
                        .textFieldStyle(.roundedBorder)
                    Button("Rename Table") {
                        session.renameActiveTable(to: tableName)
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .tint(StudioPalette.accent)
                }
                Text("ALTER TABLE \(quoteIdentifier(descriptor.name)) RENAME TO \(quoteIdentifier(tableName.isEmpty ? descriptor.name : tableName))")
                    .font(.caption.monospaced())
                    .foregroundStyle(StudioPalette.secondaryText)

                Divider()

                HStack(spacing: 8) {
                    TextField("New column", text: $newColumn.name)
                        .textFieldStyle(.roundedBorder)
                    TextField("Type", text: $newColumn.type)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                    Toggle("NN", isOn: $newColumn.isNotNull)
                    TextField("Default SQL", text: $newColumn.defaultValueSQL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                    Button("Add") {
                        session.addColumnToActiveTable(newColumn)
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .tint(StudioPalette.accent)
                }
                Text("ALTER TABLE \(quoteIdentifier(descriptor.name)) ADD COLUMN \(quoteIdentifier(newColumn.name.isEmpty ? "column_name" : newColumn.name)) \(newColumn.type)")
                    .font(.caption.monospaced())
                    .foregroundStyle(StudioPalette.secondaryText)

                Divider()

                HStack(spacing: 8) {
                    Picker("Column", selection: $selectedColumn) {
                        ForEach(descriptor.columns) { column in
                            Text(column.name).tag(column.name)
                        }
                    }
                    .frame(width: 180)
                    TextField("New name", text: $renamedColumn)
                        .textFieldStyle(.roundedBorder)
                    Button("Rename Column") {
                        session.renameColumnInActiveTable(from: selectedColumn, to: renamedColumn)
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .tint(StudioPalette.accent)
                    .disabled(selectedColumn.isEmpty || renamedColumn.isEmpty)

                    Button("Drop Column", role: .destructive) {
                        session.dropColumnFromActiveTable(selectedColumn)
                        dismiss()
                    }
                    .disabled(selectedColumn.isEmpty)
                }
                Text("ALTER TABLE \(quoteIdentifier(descriptor.name)) RENAME COLUMN \(quoteIdentifier(selectedColumn.isEmpty ? "column" : selectedColumn)) TO \(quoteIdentifier(renamedColumn.isEmpty ? "new_column" : renamedColumn))")
                    .font(.caption.monospaced())
                    .foregroundStyle(StudioPalette.secondaryText)
            }

            HStack {
                Spacer()
                Button("Done") {
                    session.dismissAlterTable()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 700)
        .onAppear {
            if let descriptor {
                tableName = descriptor.name
                selectedColumn = descriptor.columns.first?.name ?? ""
                renamedColumn = selectedColumn
            }
        }
    }
}
