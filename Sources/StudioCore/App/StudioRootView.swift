import AppKit
import Observation
import SwiftUI

public struct StudioRootView: View {
    @State private var workspaceTabs: WorkspaceTabController

    public init(session: AppSession, workspaceTabs: WorkspaceTabController? = nil) {
        _workspaceTabs = State(initialValue: workspaceTabs ?? WorkspaceTabController(initialSession: session))
    }

    public var body: some View {
        VStack(spacing: 0) {
            WorkspaceTabBar(controller: workspaceTabs)
            if let activeTab = workspaceTabs.activeTab {
                WorkspaceSessionRootView(
                    session: activeTab.session,
                    openDocument: { workspaceTabs.presentOpenPanel() }
                )
                    .id(activeTab.id)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct WorkspaceTabBar: View {
    @Bindable var controller: WorkspaceTabController

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(controller.tabs) { tab in
                        HStack(spacing: 0) {
                            Button {
                                controller.activate(tab.id)
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: tab.kind.systemImage)
                                        .font(.caption.weight(.semibold))
                                    Text(tab.title)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                        .frame(maxWidth: 190)
                                }
                                .foregroundStyle(controller.activeTabID == tab.id ? StudioPalette.primaryText : StudioPalette.secondaryText)
                                .padding(.leading, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Show \(tab.title) workspace")

                            Button {
                                Task { await controller.closeAndWait(tab.id) }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(StudioPalette.tertiaryText)
                                    .frame(width: 28, height: 30)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Close \(tab.title) workspace")
                            .accessibilityLabel("Close \(tab.title) workspace")
                        }
                        .background(
                            Capsule().fill(controller.activeTabID == tab.id
                                           ? StudioPalette.chromeFillStrong
                                           : StudioPalette.headerSurface.opacity(0.72))
                        )
                        .overlay {
                            Capsule().stroke(controller.activeTabID == tab.id
                                             ? StudioPalette.border
                                             : StudioPalette.borderSoft, lineWidth: 1)
                        }
                    }
                }
                .padding(.vertical, 7)
            }
            .scrollIndicators(.hidden)

            Button {
                if controller.tabs.count < WorkspaceTabController.maximumTabs {
                    controller.createTab()
                }
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(StudioPalette.secondaryText)
                    .frame(width: 32, height: 32)
                    .background(StudioPalette.headerSurface.opacity(0.82), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(controller.tabs.count >= WorkspaceTabController.maximumTabs)
            .help("New workspace tab")
            .accessibilityLabel("New workspace tab")

            Button {
                controller.presentOpenPanel()
            } label: {
                Image(systemName: "folder")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioPalette.secondaryText)
                    .frame(width: 32, height: 32)
                    .background(StudioPalette.headerSurface.opacity(0.82), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Open database or workspace in a new tab")
            .accessibilityLabel("Open database or workspace")
        }
        .padding(.horizontal, 16)
        .background(StudioPalette.chromeFill.opacity(0.76))
        .overlay(alignment: .bottom) {
            Rectangle().fill(StudioPalette.borderSoft).frame(height: 1)
        }
    }
}

private struct WorkspaceSessionRootView: View {
    @Bindable private var session: AppSession
    private let openDocument: () -> Void
    @State private var isMinimapHovered = false
    @State private var skillsToastVisible = false
    @State private var skillsRepeatTask: Task<Void, Never>? = nil
    @State private var skillsToastDismissedForURL: URL? = nil
    @State private var refreshToastTask: Task<Void, Never>? = nil

    init(session: AppSession, openDocument: @escaping () -> Void) {
        self.session = session
        self.openDocument = openDocument
    }

    private var schemaIsVisible: Bool {
        if session.showAllGraphTableCards { return true }
        if let side = session.maximizedPaneSide {
            return session.paneState(for: side).kind == .schema
        }
        // In split-pane mode, show if either pane is schema
        return session.side(containing: .schema) != nil
    }

    /// The minimap stands down once a compact workspace no longer has room for it.
    private var showsMinimap: Bool {
        session.hasOpenDatabase
            && session.schemaReview == nil
            && !session.graphVisibleTableIDs.isEmpty
            && !session.isWorkspaceCompact
            && schemaIsVisible
            && session.graphVisuals.isEnabled(.minimap)
    }

    var body: some View {
        ZStack {
            rootBackground

            if let review = session.schemaReview {
                SchemaReviewWorkspaceView(session: session, review: review)
            } else if session.hasOpenDatabase {
                WorkspaceLayoutView(session: session)
                    .padding(WorkspaceCompactLayout.workspaceInset)
            } else {
                EmptyDatabaseView(session: session, openDocument: openDocument)
                    .padding(24)
            }

            if showsMinimap {
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
        .disabled(session.isRefreshing)
        .overlay {
            if let scan = session.projectScan {
                ProjectScanOverlayView(state: scan) { session.cancelProjectScan() }
            } else if let progress = session.documentOpenProgress {
                VStack(spacing: 14) {
                    ProgressView()
                    Text(progress)
                    Button("Cancel") { session.cancelDocumentOpen() }
                }
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if let export = session.exportProgress {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(export.scope).font(.caption.weight(.semibold))
                        if export.isRunning {
                            if let total = export.totalRows {
                                ProgressView(value: Double(export.rowsWritten), total: Double(max(1, total)))
                            } else { ProgressView().controlSize(.small) }
                        }
                        HStack {
                            Text(export.outcome ?? "\(export.rowsWritten) rows written to temporary file")
                                .font(.caption).monospacedDigit()
                            Spacer()
                            if export.isRunning {
                                Button("Cancel Export") { session.cancelExport() }
                            } else {
                                Button("Dismiss") { session.dismissExportProgress() }
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: 620)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                if !session.metadataDiagnostics.isEmpty {
                    DisclosureGroup("Metadata: \(session.metadataDiagnostics.count) issue(s)") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(session.metadataDiagnostics, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                            }
                        }.frame(maxHeight: 140)
                        Button("Reload Metadata") { session.reloadSchemaSidecarFromDisk() }
                    }
                    .padding(12)
                    .frame(maxWidth: 620)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                if let refreshToast = session.refreshToast {
                    RefreshToastView(message: refreshToast.message)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if skillsToastVisible {
                    SkillsToastView {
                        // "Get Skills" — stop repeat loop and open panel
                        skillsRepeatTask?.cancel()
                        skillsRepeatTask = nil
                        withAnimation(.snappy(duration: 0.3)) { skillsToastVisible = false }
                        session.showSkills()
                    } onDismiss: {
                        // "×" — user explicitly hides; suppress for this database
                        skillsToastDismissedForURL = session.databaseURL
                        skillsRepeatTask?.cancel()
                        skillsRepeatTask = nil
                        withAnimation(.snappy(duration: 0.3)) { skillsToastVisible = false }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 20)
        }
        .overlay(alignment: .top) {
            if session.databaseTarget?.isMigrationModel == true {
                documentBadge(session.migrationReplaySummary ?? "Migrations · schema only",
                              systemImage: "square.stack.3d.up")
            } else if session.isPostgreSQL {
                documentBadge("PostgreSQL · read-only", systemImage: "lock.fill")
            }
        }
        .animation(.snappy(duration: 0.3), value: skillsToastVisible)
        .animation(.snappy(duration: 0.3), value: session.refreshToast?.id)
        .onChange(of: session.refreshToast?.id) { _, newID in
            refreshToastTask?.cancel()
            guard newID != nil else { return }
            refreshToastTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                withAnimation(.snappy(duration: 0.3)) {
                    session.dismissRefreshToast()
                }
            }
        }
        .onChange(of: session.tables) { _, newTables in
            guard session.databaseCapabilities.supportsAIWorkspace,
                  newTables.count > 10,
                  !session.skillsInstalled,
                  skillsToastDismissedForURL != session.databaseURL,
                  skillsRepeatTask == nil
            else { return }
            skillsRepeatTask = Task { @MainActor in
                while !Task.isCancelled {
                    guard !session.skillsInstalled else { break }
                    withAnimation(.snappy(duration: 0.3)) { skillsToastVisible = true }
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled else { break }
                    withAnimation(.snappy(duration: 0.3)) { skillsToastVisible = false }
                    try? await Task.sleep(for: .seconds(5 * 60))
                }
                withAnimation(.snappy(duration: 0.3)) { skillsToastVisible = false }
            }
        }
        .onChange(of: session.databaseURL) { _, _ in
            skillsRepeatTask?.cancel()
            skillsRepeatTask = nil
            refreshToastTask?.cancel()
            refreshToastTask = nil
            withAnimation(.snappy(duration: 0.3)) { skillsToastVisible = false }
            withAnimation(.snappy(duration: 0.3)) { session.dismissRefreshToast() }
        }
        .containerBackground(.thinMaterial, for: .window)
        .sheet(isPresented: Binding(get: { session.records.isPresented }, set: { session.records.isPresented = $0 }), onDismiss: { session.records.cancel() }) {
            RecordExplorationView(session: session)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    if session.records.current == nil { session.records.forward() }
                    session.records.isPresented = true
                } label: { Label("Records", systemImage: "point.3.connected.trianglepath.dotted") }
                .disabled(session.records.history.isEmpty)
                .help("Return to the record inspector and record graph")
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
                if session.databaseCapabilities.canCreateTable {
                    Button { session.showCreateTable() } label: { Label("Create Table", systemImage: "plus.square.on.square") }
                        .help("Create Table")
                }
            }
            ToolbarItem {
                if session.databaseCapabilities.canAlterSchema {
                    Button { session.showAlterTable() } label: { Label("Alter Table", systemImage: "slider.horizontal.3") }
                        .disabled(session.activeTab == nil)
                        .help("Alter Active Table")
                }
            }
        }
        .sheet(isPresented: $session.isTablePickerPresented) {
            OpenTablePickerView(session: session)
        }
        .sheet(isPresented: $session.isSkillsPresented) {
            SkillsPickerView(session: session)
        }
        .sheet(item: $session.projectCandidates) { choice in
            ProjectCandidatePickerView(session: session, choice: choice)
        }
        .sheet(isPresented: $session.isCreateTablePresented) {
            CreateTableSheetView(session: session)
        }
        .sheet(isPresented: $session.isAlterTablePresented) {
            AlterTableSheetView(session: session)
        }
        .alert(
            "Database Error",
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
                if let recovery = session.presentedError?.recoverySuggestion {
                    Text(recovery)
                }
            }
        )
    }

    /// The capsule above the workspace naming what kind of document is open.
    private func documentBadge(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(StudioPalette.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().stroke(StudioPalette.border, lineWidth: 1))
            .padding(.top, 8)
            .allowsHitTesting(false)
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

/// Keeps SchemaGraphView, TableWorkspaceView, and QueryWorkspaceView alive at all times.
/// PaneShell instances are given explicit stable `.id()` values so SwiftUI never
/// recreates them when the surrounding layout changes between split and fullscreen.
private struct WorkspaceLayoutView: View {
    @Bindable var session: AppSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var databaseNameSide: WorkspacePaneSide = .left

    private var fullscreenSide: WorkspacePaneSide? {
        if let side = session.maximizedPaneSide {
            return side
        }
        if session.showAllGraphTableCards {
            return session.side(containing: .schema) ?? .left
        }
        return session.compactVisibleSide
    }

    private var isFullscreen: Bool {
        fullscreenSide != nil
    }

    /// Keeps the dock available when a narrow workspace shows one pane.
    private var isCompactSinglePane: Bool {
        session.isWorkspaceCompact
            && session.maximizedPaneSide == nil
            && !session.showAllGraphTableCards
    }

    private var visiblePaneKinds: Set<PaneContentKind> {
        guard let fullscreenSide else {
            return [session.leftPane.kind, session.rightPane.kind]
        }
        return [session.paneState(for: fullscreenSide).kind]
    }

    var body: some View {
        splitLayout
            .animation(reduceMotion ? nil : .snappy(duration: 0.32), value: fullscreenSide)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                session.updateWorkspaceWidth(width)
            }
    }

    private var splitLayout: some View {
        ZStack(alignment: .bottom) {
            HSplitView {
                PaneShell(
                    session: session,
                    side: .left,
                    isCompact: isCompactSinglePane,
                    showsDatabaseName: (fullscreenSide ?? databaseNameSide) == .left
                )
                .id("workspace-pane-left")
                .frame(
                    minWidth: paneWidthBounds(for: .left).minimum,
                    maxWidth: paneWidthBounds(for: .left).maximum
                )
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: WorkspacePaneWidthsKey.self, value: [.left: geometry.size.width])
                    }
                }
                .opacity(paneOpacity(for: .left))
                .allowsHitTesting(paneIsInteractive(.left))
                .accessibilityHidden(!paneIsInteractive(.left))

                PaneShell(
                    session: session,
                    side: .right,
                    isCompact: isCompactSinglePane,
                    showsDatabaseName: (fullscreenSide ?? databaseNameSide) == .right
                )
                .id("workspace-pane-right")
                .frame(
                    minWidth: paneWidthBounds(for: .right).minimum,
                    maxWidth: paneWidthBounds(for: .right).maximum
                )
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: WorkspacePaneWidthsKey.self, value: [.right: geometry.size.width])
                    }
                }
                .opacity(paneOpacity(for: .right))
                .allowsHitTesting(paneIsInteractive(.right))
                .accessibilityHidden(!paneIsInteractive(.right))
            }
            .background(SplitViewPositioner(mode: splitMode))
            .onPreferenceChange(WorkspacePaneWidthsKey.self) { widths in
                guard fullscreenSide == nil,
                      let left = widths[.left], let right = widths[.right],
                      left > 0, right > 0,
                      abs(left - right) > 1
                else { return }
                // Keep the current owner at an even split so the title cannot flicker.
                databaseNameSide = left > right ? .left : .right
                session.workspaceSplitFraction = min(max(left / (left + right), 0.25), 0.75)
            }

            if !isFullscreen || isCompactSinglePane {
                WorkspaceDockView(session: session, visibleKinds: visiblePaneKinds)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var splitMode: SplitViewPositionMode {
        if let fullscreenSide {
            return .fullscreen(fullscreenSide)
        }
        return .split(defaultFraction: session.workspaceSplitFraction)
    }

    private func paneOpacity(for side: WorkspacePaneSide) -> Double {
        guard let fullscreenSide else { return 1 }
        return fullscreenSide == side ? 1 : 0
    }

    private func paneIsInteractive(_ side: WorkspacePaneSide) -> Bool {
        fullscreenSide == nil || fullscreenSide == side
    }

    private func paneWidthBounds(for side: WorkspacePaneSide) -> (minimum: CGFloat, maximum: CGFloat) {
        WorkspaceCompactLayout.paneWidthBounds(for: side, fullscreenSide: fullscreenSide)
    }
}

private struct WorkspacePaneWidthsKey: PreferenceKey {
    static let defaultValue: [WorkspacePaneSide: CGFloat] = [:]

    static func reduce(value: inout [WorkspacePaneSide: CGFloat], nextValue: () -> [WorkspacePaneSide: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, width in width })
    }
}

private enum SplitViewPositionMode: Equatable {
    case split(defaultFraction: CGFloat)
    case fullscreen(WorkspacePaneSide)
}

private struct SplitViewPositioner: NSViewRepresentable {
    let mode: SplitViewPositionMode

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.applyPosition(from: nsView, mode: mode)
        }
    }

    @MainActor
    final class Coordinator {
        private var didApplyInitialPosition = false
        private var lastMode: SplitViewPositionMode?
        private var savedSplitFraction: CGFloat?

        @MainActor
        func applyPosition(from view: NSView, mode: SplitViewPositionMode, attempt: Int = 0) {
            guard let splitView = view.nearestSplitView(),
                  splitView.arrangedSubviews.count >= 2,
                  splitView.bounds.width > 0
            else {
                retry(from: view, mode: mode, attempt: attempt)
                return
            }

            switch mode {
            case .split(let defaultFraction):
                applySplitMode(to: splitView, defaultFraction: defaultFraction)
            case .fullscreen(let side):
                applyFullscreenMode(to: splitView, side: side)
            }

            lastMode = mode
        }

        @MainActor
        private func applySplitMode(to splitView: NSSplitView, defaultFraction: CGFloat) {
            if !didApplyInitialPosition {
                didApplyInitialPosition = true
                savedSplitFraction = defaultFraction
                setDividerPosition(
                    splitView.bounds.width * defaultFraction,
                    in: splitView,
                    animated: false
                )
                return
            }

            if case .fullscreen = lastMode {
                let fraction = savedSplitFraction ?? defaultFraction
                setDividerPosition(
                    splitView.bounds.width * fraction,
                    in: splitView,
                    animated: true
                )
                return
            }

            savedSplitFraction = currentDividerFraction(in: splitView) ?? savedSplitFraction
        }

        @MainActor
        private func applyFullscreenMode(to splitView: NSSplitView, side: WorkspacePaneSide) {
            if shouldCaptureSplitFraction {
                savedSplitFraction = currentDividerFraction(in: splitView) ?? savedSplitFraction
            }

            didApplyInitialPosition = true
            let targetPosition = side == .left ? splitView.bounds.width : 0
            setDividerPosition(targetPosition, in: splitView, animated: true)
        }

        private var shouldCaptureSplitFraction: Bool {
            guard let lastMode else { return true }
            if case .split = lastMode { return true }
            return false
        }

        @MainActor
        private func currentDividerFraction(in splitView: NSSplitView) -> CGFloat? {
            guard splitView.bounds.width > 0,
                  splitView.arrangedSubviews.count >= 2
            else {
                return nil
            }

            let width = splitView.arrangedSubviews[0].frame.width
            guard width.isFinite, width > 0, width < splitView.bounds.width else { return nil }
            return width / splitView.bounds.width
        }

        @MainActor
        private func setDividerPosition(_ position: CGFloat, in splitView: NSSplitView, animated: Bool) {
            // This slide is what a collapse actually looks like, and a resize can
            // now trigger it, so it answers to reduce-motion like the SwiftUI
            // transitions around it.
            guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                splitView.setPosition(position, ofDividerAt: 0)
                return
            }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                context.allowsImplicitAnimation = true
                splitView.animator().setPosition(position, ofDividerAt: 0)
            }
        }

        @MainActor
        private func retry(from view: NSView, mode: SplitViewPositionMode, attempt: Int) {
            guard attempt < 12 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak view, weak self] in
                guard let view, let self else { return }
                self.applyPosition(from: view, mode: mode, attempt: attempt + 1)
            }
        }
    }
}

private extension NSView {
    @MainActor
    func nearestSplitView() -> NSSplitView? {
        firstSuperview(of: NSSplitView.self)
            ?? window?.contentView?.firstDescendant(of: NSSplitView.self)
    }

    @MainActor
    private func firstSuperview<T: NSView>(of type: T.Type) -> T? {
        var current = superview
        while let view = current {
            if let match = view as? T {
                return match
            }
            current = view.superview
        }
        return nil
    }

    @MainActor
    private func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T {
                return match
            }
            if let match = subview.firstDescendant(of: type) {
                return match
            }
        }
        return nil
    }
}

/// A pane with its chrome (header, border, background). Keeps content views alive.
private struct PaneShell: View {
    @Bindable var session: AppSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let side: WorkspacePaneSide
    let isCompact: Bool
    let showsDatabaseName: Bool
    @State private var isDropTargeted = false

    private var paneState: WorkspacePaneState { session.paneState(for: side) }
    private var isMaximized: Bool { session.maximizedPaneSide == side }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Spacer().frame(height: 58)
                PaneContentView(session: session, kind: paneState.kind, side: side)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(StudioPalette.chromeFill.opacity(0.88)))
            .overlay {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(borderColor, lineWidth: isDropTargeted || session.activePaneSide == side ? 1.4 : 1.0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))

            paneHeader
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
        .dropDestination(for: WorkspaceDockItem.self) { items, _ in
            guard let item = items.first else { return false }
            session.applyDockItem(item, to: side)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private var paneHeader: some View {
        HStack(spacing: 12) {
            if isMaximized || isCompact {
                Label(paneState.kind.title, systemImage: paneState.kind.systemImage)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(StudioPalette.primaryText)
            } else if paneState.kind != .schema {
                Label(paneState.kind.title, systemImage: paneState.kind.systemImage)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(StudioPalette.primaryText)
            }
            Spacer()
            if isMaximized {
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
                    .background(Capsule().fill(StudioPalette.chromeFillStrong))
                    .overlay { Capsule().stroke(StudioPalette.border, lineWidth: 1) }
                }
                .buttonStyle(.plain)
            } else if !isCompact {
                PaneHeaderIconButton(systemImage: "arrow.up.left.and.arrow.down.right", title: "Maximize pane") {
                    session.toggleMaximizePane(side)
                }
            }
            if showsDatabaseName, session.migrationSet != nil {
                MigrationVersionControl(session: session)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            if showsDatabaseName {
                Text(session.databaseDisplayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(StudioPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(session.databaseDisplayName)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: showsDatabaseName)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(isMaximized || (isDropTargeted || session.activePaneSide == side)
                  ? StudioPalette.chromeFillStrong : StudioPalette.chromeFill))
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 4)
        // Use contentShape so only the visible pill intercepts events,
        // not the transparent padding area where graph controls live.
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture { session.setActivePaneSide(side) }
    }

    private var borderColor: Color {
        if isDropTargeted { return StudioPalette.borderStrong }
        if session.activePaneSide == side { return StudioPalette.border }
        return StudioPalette.borderSoft
    }
}

/// Renders the actual content for a pane kind. Each kind is always instantiated
/// and kept alive — visibility is controlled by the parent layout, not by
/// conditional branches here.
private struct PaneContentView: View {
    @Bindable var session: AppSession
    let kind: PaneContentKind
    let side: WorkspacePaneSide

    var body: some View {
        switch kind {
        case .schema:
            SchemaGraphView(session: session)
        case .tables:
            TableWorkspaceView(session: session)
        case .query:
            QueryWorkspaceView(session: session)
        }
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
    /// What is actually on screen. In the narrow single-pane layout both panes
    /// still hold content, but only one of them is showing.
    let visibleKinds: Set<PaneContentKind>

    var body: some View {
        HStack(spacing: 10) {
            ForEach(PaneContentKind.allCases.filter { $0 != .query || session.canShowQueryPane }) { kind in
                WorkspaceDockPill(
                    kind: kind,
                    isVisible: visibleKinds.contains(kind)
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
    @State private var expandedGroups: Set<String>
    @State private var expandedTables: Set<String> = []

    init(session: AppSession) {
        self.session = session
        // All groups start expanded
        _expandedGroups = State(initialValue: Set(session.graphGrouping.groups.map(\.id)).union(["__ungrouped__"]))
    }

    // FK source columns per table derived from graph edges
    private var fkColumnsByTable: [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for edge in session.graph.edges {
            result[edge.sourceID, default: []].insert(edge.sourceColumn)
        }
        return result
    }

    private struct PickerGroup: Identifiable {
        let id: String
        let label: String
        let color: Color?
        let tables: [TableSummary]
    }

    private var groups: [PickerGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = session.tables.filter { table in
            query.isEmpty || table.name.localizedCaseInsensitiveContains(query)
                || session.graphGrouping.group(for: table.name)?.label.localizedCaseInsensitiveContains(query) == true
        }
        let tablesByGroup = Dictionary(grouping: filtered) { table in
            session.graphGrouping.nodeToGroup[table.name] ?? "__ungrouped__"
        }
        var result: [PickerGroup] = session.graphGrouping.groups.compactMap { group in
            guard let tables = tablesByGroup[group.id], !tables.isEmpty else { return nil }
            return PickerGroup(
                id: group.id,
                label: group.label,
                color: Color(studioHex: group.colorHex),
                tables: tables
            )
        }
        if let ungrouped = tablesByGroup["__ungrouped__"], !ungrouped.isEmpty {
            result.append(PickerGroup(
                id: "__ungrouped__", label: result.isEmpty ? "Tables" : "Other", color: nil, tables: ungrouped
            ))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open Table")
                .font(.title2.weight(.semibold))

            TextField("Search tables", text: $searchText)
                .textFieldStyle(.roundedBorder)

            List {
                ForEach(groups) { group in
                    Section {
                        if expandedGroups.contains(group.id) || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ForEach(group.tables) { table in
                                tableRow(table, fk: fkColumnsByTable)
                            }
                        }
                    } header: {
                        groupHeader(group)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(StudioPalette.gridSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(StudioPalette.borderSoft)
            }
            .frame(minWidth: 460, minHeight: 340, maxHeight: 480)

            HStack {
                Spacer()
                Button("Cancel") {
                    session.dismissTablePicker()
                    dismiss()
                }
                Button("Open") {
                    if let selection { session.openTable(named: selection) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(20)
        .onChange(of: session.isTablePickerPresented) { _, isPresented in
            if !isPresented { dismiss() }
        }
    }

    @ViewBuilder
    private func groupHeader(_ group: PickerGroup) -> some View {
        Button {
            if expandedGroups.contains(group.id) { expandedGroups.remove(group.id) }
            else { expandedGroups.insert(group.id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expandedGroups.contains(group.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(StudioPalette.secondaryText)
                    .frame(width: 10)
                if let color = group.color {
                    Circle().fill(color.opacity(0.75)).frame(width: 7, height: 7)
                }
                Text(group.label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StudioPalette.secondaryText)
                Spacer()
                Text("\(group.tables.count)")
                    .font(.caption2)
                    .foregroundStyle(StudioPalette.secondaryText.opacity(0.5))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func tableRow(_ table: TableSummary, fk: [String: Set<String>]) -> some View {
        let isSelected = selection == table.name
        let isExpanded = expandedTables.contains(table.name)
        let descriptor = session.descriptor(named: table.name)
        let hasColumns = !(descriptor?.columns.isEmpty ?? true)

        VStack(alignment: .leading, spacing: 0) {
            Button {
                selection = table.name
                if hasColumns {
                    if isExpanded { expandedTables.remove(table.name) }
                    else { expandedTables.insert(table.name) }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: hasColumns
                          ? (isExpanded ? "chevron.down" : "chevron.right")
                          : "minus")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(StudioPalette.secondaryText.opacity(0.5))
                        .frame(width: 10)
                    Image(systemName: table.objectType == .view ? "eye" : "tablecells")
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? StudioPalette.accent : StudioPalette.secondaryText)
                    Text(table.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(StudioPalette.primaryText)
                    Spacer(minLength: 8)
                    if let count = table.rowCount {
                        Text("\(count)")
                            .font(.caption2)
                            .foregroundStyle(StudioPalette.secondaryText.opacity(0.5))
                    }
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(StudioPalette.accent)
                    }
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? StudioPalette.selectionSurfaceTop : .clear)
                )
            }
            .buttonStyle(.plain)

            if isExpanded, let descriptor {
                ForEach(descriptor.columns) { column in
                    pickerColumnRow(column, tableName: table.name, fk: fk)
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func pickerColumnRow(_ column: TableColumn, tableName: String, fk: [String: Set<String>]) -> some View {
        let isPK = column.primaryKeyOrdinal > 0
        let isFK = fk[tableName]?.contains(column.name) ?? false
        HStack(spacing: 5) {
            Spacer().frame(width: 26)
            Text(column.name)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(StudioPalette.primaryText.opacity(0.8))
            Spacer(minLength: 6)
            Text(column.typeLabel)
                .font(.system(size: 10))
                .foregroundStyle(StudioPalette.secondaryText)
            if isPK { pickerBadge("PK", tint: StudioPalette.primaryKeyTint) }
            if isFK { pickerBadge("FK", tint: StudioPalette.foreignKeyTint) }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func pickerBadge(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
    }
}

private struct EmptyDatabaseView: View {
    @Bindable var session: AppSession
    let openDocument: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(spacing: 14) {
                StudioAppLogoView()

                VStack(spacing: 8) {
                    Text("Open a database")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(StudioPalette.primaryText)
                    Text("Browse and edit SQLite databases, explore PostgreSQL in read-only mode, or read a data model straight from a project's migration files.")
                        .foregroundStyle(StudioPalette.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }

                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            openDocument()
                        } label: {
                            Label("Choose Database File", systemImage: "folder")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(StudioPalette.accent)
                        .controlSize(.large)

                        Button {
                            session.presentOpenProjectFolderPanel()
                        } label: {
                            Label("Search Project Folder", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }

                    Text(DatabaseDocument.supportedFormatsDescription
                         + "\nMigrations: a folder of versioned .sql files")
                        .font(.caption)
                        .foregroundStyle(StudioPalette.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 520)
                }
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

                // Columns are unbounded, so they scroll rather than pushing the
                // SQL preview and the action buttons past the bottom of a short
                // window.
                ScrollView {
                    VStack(spacing: 8) {
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
                    .padding(.trailing, 2)
                }
                .frame(minHeight: 96, maxHeight: 200)
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

// MARK: - RefreshToastView

private struct RefreshToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StudioPalette.accent)

            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(StudioPalette.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 440)
        .studioGlassCard(cornerRadius: 22, tint: Color.white, strokeOpacity: 0.12)
        .accessibilityLabel(message)
    }
}

// MARK: - SkillsToastView

private struct SkillsToastView: View {
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StudioPalette.accent)

            Text("AI skills available for this database")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(StudioPalette.primaryText)

            Spacer(minLength: 8)

            Button("Get Skills") {
                onOpen()
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(StudioPalette.accent)
            .controlSize(.small)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(StudioPalette.secondaryText)
                    .frame(width: 20, height: 20)
                    .background(StudioPalette.chromeFillStrong, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .studioGlassCard(cornerRadius: 24, tint: Color.white, strokeOpacity: 0.12)
    }
}

// MARK: - SkillsPickerView

private struct SkillsPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: AppSession
    @State private var expandedSkillIDs: Set<String> = []
    @State private var installRevision = 0
    @State private var autoCloseTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI Skills")
                    .font(.title2.weight(.semibold))
                Text("Install project skills for AI coding agents.")
                    .font(.subheadline)
                    .foregroundStyle(StudioPalette.secondaryText)
            }

            List {
                ForEach(StudioSkills.all) { skill in
                    skillRow(skill)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(StudioPalette.gridSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(StudioPalette.borderSoft)
            }
            .frame(minWidth: 500, minHeight: 240, maxHeight: 420)

            if let dir = session.skillsDirectory {
                Text("Installing to: \(dir.path)")
                    .font(.caption)
                    .foregroundStyle(StudioPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                if missingInstallCount == 0 {
                    Label("All available targets installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.green)
                        .font(.subheadline.weight(.medium))
                } else {
                    Text("\(missingInstallCount) missing")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(StudioPalette.secondaryText)
                }
                Spacer()
                Button("Cancel") {
                    session.dismissSkills()
                    dismiss()
                }
                Menu("Add Target") {
                    ForEach(missingTargetDirectories) { targetDirectory in
                        Button(targetDirectory.label) {
                            session.installSkills(to: targetDirectory)
                            installRevision &+= 1
                            scheduleAutoClose()
                        }
                    }
                }
                .disabled(missingTargetDirectories.isEmpty)
                Button(missingInstallCount == 0 ? "Installed" : "Install Missing") {
                    session.installSkills()
                    installRevision &+= 1
                    scheduleAutoClose()
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioPalette.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(missingInstallCount == 0)
            }
        }
        .padding(20)
        .id(installRevision)
        .onChange(of: session.isSkillsPresented) { _, isPresented in
            if !isPresented { dismiss() }
        }
        .onDisappear {
            autoCloseTask?.cancel()
        }
    }

    private func scheduleAutoClose() {
        autoCloseTask?.cancel()
        autoCloseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            session.dismissSkills()
            dismiss()
        }
    }

    private var missingInstallCount: Int {
        guard let dir = session.skillsDirectory else { return 0 }
        return StudioSkills.all.reduce(0) { count, skill in
            count + StudioSkills.missingTargets(for: skill, in: dir).count
        }
    }

    private var missingTargetDirectories: [StudioSkillDirectoryTarget] {
        guard let dir = session.skillsDirectory else { return [] }
        return StudioSkills.missingTargetDirectories(in: dir)
    }

    @ViewBuilder
    private func skillRow(_ skill: StudioSkill) -> some View {
        let isExpanded = expandedSkillIDs.contains(skill.id)
        let installStatus = installationStatus(for: skill)

        VStack(alignment: .leading, spacing: 0) {
            Button {
                if isExpanded { expandedSkillIDs.remove(skill.id) }
                else { expandedSkillIDs.insert(skill.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(StudioPalette.secondaryText)
                        .frame(width: 10)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(skill.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StudioPalette.primaryText)
                        Text(skill.shortDescription)
                            .font(.caption)
                            .foregroundStyle(StudioPalette.secondaryText)
                            .multilineTextAlignment(.leading)
                        Text(installStatus.detail)
                            .font(.caption2)
                            .foregroundStyle(StudioPalette.tertiaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if installStatus.missingCount == 0, installStatus.availableCount > 0 {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.green)
                        Button("Reinstall") {
                            session.installSkill(skill)
                            installRevision &+= 1
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Replace installed copies of this skill with the app's current version")
                    } else {
                        Button(installStatus.availableCount == 0 ? "No Target" : "Install") {
                            session.installSkill(skill)
                            installRevision &+= 1
                        }
                        .buttonStyle(.bordered)
                        .tint(StudioPalette.accent)
                        .controlSize(.small)
                        .disabled(installStatus.availableCount == 0 || installStatus.missingCount == 0)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollView {
                    Text(skill.fullContent)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(StudioPalette.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 200)
                .background(StudioPalette.editorSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func installationStatus(for skill: StudioSkill) -> SkillInstallStatus {
        guard let dir = session.skillsDirectory else {
            return SkillInstallStatus(availableCount: 0, installedCount: 0, missingCount: 0)
        }
        let available = StudioSkills.availableInstallationTargets(for: skill, in: dir)
        let installed = StudioSkills.installedTargets(for: skill, in: dir)
        let missing = StudioSkills.missingTargets(for: skill, in: dir)
        return SkillInstallStatus(
            availableCount: available.count,
            installedCount: installed.count,
            missingCount: missing.count
        )
    }

    private struct SkillInstallStatus {
        let availableCount: Int
        let installedCount: Int
        let missingCount: Int

        var detail: String {
            guard availableCount > 0 else {
                return "No supported skill directory found"
            }
            if missingCount == 0 {
                return "Installed in \(installedCount) target\(installedCount == 1 ? "" : "s")"
            }
            if installedCount == 0 {
                return "Not installed in \(availableCount) target\(availableCount == 1 ? "" : "s")"
            }
            return "\(installedCount) installed, \(missingCount) missing"
        }
    }
}
