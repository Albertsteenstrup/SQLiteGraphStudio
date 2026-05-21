import AppKit
import Observation
import SwiftUI

public struct StudioRootView: View {
    @Bindable private var session: AppSession
    @State private var isMinimapHovered = false
    @State private var skillsToastVisible = false
    @State private var skillsRepeatTask: Task<Void, Never>? = nil
    @State private var skillsToastDismissedForURL: URL? = nil
    @State private var refreshToastTask: Task<Void, Never>? = nil

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
                WorkspaceLayoutView(session: session)
                    .padding(session.storyPlaybackOverlay == nil ? 16 : 0)
            } else {
                EmptyDatabaseView(session: session)
                    .padding(24)
            }

            // Minimap — shown whenever the schema graph is visible and has nodes.
            // Rendered at the root ZStack level so it's never clipped by pane containers
            // and always appears above the dock nav.
            if session.hasOpenDatabase
                && session.storyPlaybackOverlay == nil
                && !session.graph.nodes.isEmpty
                && schemaIsVisible {
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
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
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
            .padding(.bottom, session.storyPlaybackOverlay == nil ? 20 : 132)
        }
        .animation(.snappy(duration: 0.3), value: skillsToastVisible)
        .animation(.snappy(duration: 0.3), value: session.refreshToast?.id)
        .animation(.snappy(duration: 0.32), value: session.storyPlaybackOverlay != nil)
        .background {
            StoryPlaybackKeyboardMonitor(
                isActive: session.storyPlaybackOverlay != nil,
                sendCommand: { commandKind in
                    session.storyPlaybackCommand = StoryPlaybackCommand(kind: commandKind)
                }
            )
            .frame(width: 0, height: 0)
        }
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
            guard newTables.count > 10,
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
        .sheet(isPresented: $session.isSkillsPresented) {
            SkillsPickerView(session: session)
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

/// Keeps SchemaGraphView, TableWorkspaceView, and QueryWorkspaceView alive at all times.
/// PaneShell instances are given explicit stable `.id()` values so SwiftUI never
/// recreates them when the surrounding layout changes between split and fullscreen.
private struct WorkspaceLayoutView: View {
    @Bindable var session: AppSession

    private var storyPlaybackState: StoryPlaybackOverlayState? {
        session.storyPlaybackOverlay
    }

    private var isStoryPlaybackActive: Bool {
        storyPlaybackState != nil
    }

    private var fullscreenSide: WorkspacePaneSide? {
        if let side = session.maximizedPaneSide {
            return side
        }
        if isStoryPlaybackActive || session.showAllGraphTableCards {
            return session.side(containing: .schema) ?? .left
        }
        return nil
    }

    private var isFullscreen: Bool {
        fullscreenSide != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            splitLayout

            if let storyPlaybackState {
                StoryPlaybackBottomBar(
                    state: storyPlaybackState,
                    displayedText: session.storyPlaybackDisplayedText,
                    sendCommand: { commandKind in
                        session.storyPlaybackCommand = StoryPlaybackCommand(kind: commandKind)
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.32), value: isStoryPlaybackActive)
        .animation(.snappy(duration: 0.32), value: fullscreenSide)
    }

    private var splitLayout: some View {
        ZStack(alignment: .bottom) {
            HSplitView {
                PaneShell(
                    session: session,
                    side: .left,
                    isCanvasMode: isStoryCanvasMode(for: .left)
                )
                .id("workspace-pane-left")
                .frame(minWidth: minimumPaneWidth(for: .left))
                .opacity(paneOpacity(for: .left))
                .allowsHitTesting(paneIsInteractive(.left))

                PaneShell(
                    session: session,
                    side: .right,
                    isCanvasMode: isStoryCanvasMode(for: .right)
                )
                .id("workspace-pane-right")
                .frame(minWidth: minimumPaneWidth(for: .right))
                .opacity(paneOpacity(for: .right))
                .allowsHitTesting(paneIsInteractive(.right))
            }
            .background(SplitViewPositioner(mode: splitMode))

            if !isFullscreen {
                WorkspaceDockView(session: session)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var splitMode: SplitViewPositionMode {
        if let fullscreenSide {
            return .fullscreen(fullscreenSide)
        }
        return .split(defaultFraction: 0.6)
    }

    private func isStoryCanvasMode(for side: WorkspacePaneSide) -> Bool {
        isStoryPlaybackActive && session.paneState(for: side).kind == .schema
    }

    private func paneOpacity(for side: WorkspacePaneSide) -> Double {
        guard let fullscreenSide else { return 1 }
        return fullscreenSide == side ? 1 : 0
    }

    private func paneIsInteractive(_ side: WorkspacePaneSide) -> Bool {
        fullscreenSide == nil || fullscreenSide == side
    }

    private func minimumPaneWidth(for side: WorkspacePaneSide) -> CGFloat {
        guard let fullscreenSide else { return 320 }
        return fullscreenSide == side ? 320 : 0
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
            guard animated else {
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
    let side: WorkspacePaneSide
    let isCanvasMode: Bool
    @State private var isDropTargeted = false

    private var paneState: WorkspacePaneState { session.paneState(for: side) }
    private var isMaximized: Bool { session.maximizedPaneSide == side }
    private var cornerRadius: CGFloat { isCanvasMode ? 0 : 32 }
    private var headerHeight: CGFloat { isCanvasMode ? 0 : 58 }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Spacer().frame(height: headerHeight)
                PaneContentView(session: session, kind: paneState.kind, side: side)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(isCanvasMode ? Color.clear : StudioPalette.chromeFill.opacity(0.88)))
            .overlay {
                if !isCanvasMode {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(borderColor, lineWidth: isDropTargeted || session.activePaneSide == side ? 1.4 : 1.0)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

            if !isCanvasMode {
                paneHeader
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy(duration: 0.28), value: isCanvasMode)
        .dropDestination(for: WorkspaceDockItem.self) { items, _ in
            guard let item = items.first else { return false }
            session.applyDockItem(item, to: side)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private var paneHeader: some View {
        HStack(spacing: 12) {
            if isMaximized {
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
            } else {
                PaneHeaderIconButton(systemImage: "arrow.up.left.and.arrow.down.right", title: "Maximize pane") {
                    session.toggleMaximizePane(side)
                }
            }
            Text(session.databaseDisplayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(StudioPalette.secondaryText)
        }
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

private struct StoryPlaybackBottomBar: View {
    let state: StoryPlaybackOverlayState
    let displayedText: String
    let sendCommand: (StoryPlaybackCommand.Kind) -> Void

    private var clusterColor: Color? {
        state.clusterColorHex.flatMap { Color(studioHex: $0) }
    }

    private var beatText: String {
        let text = displayedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? state.displayedText : text
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            storySummary
                .frame(width: 300, alignment: .leading)

            Divider()
                .frame(height: 72)
                .opacity(0.55)

            playbackText
                .frame(maxWidth: .infinity, alignment: .leading)

            controls
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 104, maxHeight: 118, alignment: .center)
        .background(StudioPalette.chromeFillStrong)
        .overlay(alignment: .top) {
            Rectangle()
                .fill((clusterColor ?? StudioPalette.border).opacity(clusterColor == nil ? 0.85 : 0.72))
                .frame(height: 1)
        }
        .shadow(color: StudioPalette.shadow.opacity(0.36), radius: 18, y: -6)
    }

    private var storySummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Circle()
                    .fill(clusterColor ?? StudioPalette.accentSoft)
                    .frame(width: 8, height: 8)

                Text(state.clusterLabel ?? "Story")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(StudioPalette.secondaryText)
                    .lineLimit(1)

                Text("\(min(state.index + 1, state.playbackCount))/\(state.playbackCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(StudioPalette.tertiaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(StudioPalette.headerSurface, in: Capsule())

                if state.isPaused {
                    Text("Paused")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(StudioPalette.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(StudioPalette.headerSurface.opacity(0.8), in: Capsule())
                }
            }

            Text(state.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StudioPalette.primaryText)
                .lineLimit(1)

            if let userStoryText = state.userStoryText {
                Text(userStoryText)
                    .font(.caption)
                    .foregroundStyle(StudioPalette.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var playbackText: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(beatText)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(StudioPalette.primaryText)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(nil, value: displayedText)

            if let acceptanceText = state.acceptanceText {
                Text(acceptanceText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(StudioPalette.tertiaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 7) {
            if state.isReadAloudEnabled, let readAloudStatus = state.readAloudStatus.displayText {
                readAloudStatusPill(readAloudStatus)
            }

            storyControlButton(
                systemImage: "backward.end.fill",
                help: "Previous beat",
                isDisabled: !state.canGoBackward || state.isReadAloudBusy
            ) {
                sendCommand(.previous)
            }

            storyControlButton(
                systemImage: state.isPaused ? "play.fill" : "pause.fill",
                help: state.isPaused ? "Resume story" : "Pause story",
                isDisabled: state.isReadAloudBusy
            ) {
                sendCommand(.togglePause)
            }

            storyControlButton(
                systemImage: state.isReadAloudEnabled ? "speaker.wave.2.fill" : "speaker.wave.2",
                help: state.isReadAloudEnabled ? "Disable read aloud" : "Read beats aloud with Kokoro Bella",
                isActive: state.isReadAloudEnabled
            ) {
                sendCommand(.toggleReadAloud)
            }

            storyControlButton(
                systemImage: "forward.end.fill",
                help: "Next beat",
                isDisabled: !state.canGoForward || state.isReadAloudBusy
            ) {
                sendCommand(.next)
            }

            storyControlButton(systemImage: "xmark", help: "Stop story") {
                sendCommand(.stop)
            }
        }
    }

    private func readAloudStatusPill(_ text: String) -> some View {
        Group {
            if state.readAloudStatus.requiresInstall {
                Button {
                    sendCommand(.installReadAloud)
                } label: {
                    Label(text, systemImage: "arrow.down.circle.fill")
                        .font(.caption2.weight(.bold))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(StudioPalette.accent, in: Capsule())
                .help("Install Kokoro for read aloud")
            } else {
                HStack(spacing: 5) {
                    if state.isReadAloudBusy {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.58)
                            .frame(width: 10, height: 10)
                    }

                    Text(text)
                        .font(.caption2.weight(.bold))
                        .lineLimit(1)
                }
                .foregroundStyle(StudioPalette.secondaryText)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(StudioPalette.headerSurface.opacity(0.8), in: Capsule())
            }
        }
    }

    private func storyControlButton(
        systemImage: String,
        help: String,
        isDisabled: Bool = false,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isDisabled ? StudioPalette.tertiaryText : isActive ? Color.white : StudioPalette.secondaryText)
                .frame(width: 30, height: 30)
                .background(isActive ? StudioPalette.accent : StudioPalette.headerSurface.opacity(isDisabled ? 0.46 : 0.82), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
    }
}

private struct StoryPlaybackKeyboardMonitor: NSViewRepresentable {
    let isActive: Bool
    let sendCommand: (StoryPlaybackCommand.Kind) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.update(isActive: isActive, sendCommand: sendCommand)
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(isActive: isActive, sendCommand: sendCommand)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator {
        private var eventMonitor: Any?
        private var isActive = false
        private var sendCommand: ((StoryPlaybackCommand.Kind) -> Void)?

        func update(isActive: Bool, sendCommand: @escaping (StoryPlaybackCommand.Kind) -> Void) {
            self.sendCommand = sendCommand
            guard self.isActive != isActive else { return }
            self.isActive = isActive
            if isActive {
                startMonitoring()
            } else {
                stopMonitoring()
            }
        }

        func stopMonitoring() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
        }

        private func startMonitoring() {
            stopMonitoring()
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isActive else { return event }
                guard !Self.isTextInputFocused else { return event }
                let blockedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
                guard event.modifierFlags.intersection(blockedModifiers).isEmpty else { return event }
                guard let command = Self.command(for: event) else { return event }
                self.sendCommand?(command)
                return nil
            }
        }

        private static var isTextInputFocused: Bool {
            NSApp.keyWindow?.firstResponder is NSTextView
                || NSApp.keyWindow?.firstResponder is NSTextField
        }

        private static func command(for event: NSEvent) -> StoryPlaybackCommand.Kind? {
            switch event.keyCode {
            case 123:
                return .previous
            case 124:
                return .next
            case 49:
                return .togglePause
            default:
                return nil
            }
        }
    }
}

/// Affine translation used by story-card drag tests and any AppKit hit-test math.
enum StoryPlaybackCardDragTransform: Sendable {
    static func affineTransform(for offset: CGSize) -> CGAffineTransform {
        CGAffineTransform(translationX: offset.width, y: offset.height)
    }
}

/// Bottom-aligned story card with local drag offset so dragging stays 1:1 with the
/// pointer and does not re-render the whole workspace on every frame.
private struct StoryPlaybackOverlayHost: View {
    let state: StoryPlaybackOverlayState
    let displayedText: String
    let sendCommand: (StoryPlaybackCommand.Kind) -> Void

    @State private var dragOffset: CGSize = .zero

    var body: some View {
        StoryPlaybackOverlayCard(
            state: state,
            displayedText: displayedText,
            offset: $dragOffset,
            sendCommand: sendCommand
        )
        .offset(dragOffset)
        .onChange(of: state.index) { _, _ in
            dragOffset = .zero
        }
        .onChange(of: state.title) { _, _ in
            dragOffset = .zero
        }
    }
}

private struct StoryPlaybackOverlayCard: View {
    let state: StoryPlaybackOverlayState
    let displayedText: String
    @Binding var offset: CGSize
    let sendCommand: (StoryPlaybackCommand.Kind) -> Void

    @State private var dragStartOffset: CGSize?
    @State private var isExpanded = false

    private var clusterColor: Color? {
        state.clusterColorHex.flatMap { Color(studioHex: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            playbackHeaderRow

            VStack(alignment: .leading, spacing: 6) {
                Text(state.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StudioPalette.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .contentShape(Rectangle())
                    .gesture(dragGesture)

                if isExpanded {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 12) {
                            StoryUserCardFormatView(
                                actor: state.actor,
                                goal: state.goal,
                                benefit: state.benefit,
                                fallbackText: state.userStoryText,
                                conversation: state.conversation,
                                acceptanceCriteria: state.acceptanceCriteria
                            )

                            Divider().opacity(0.55)

                            Text(displayedText)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(StudioPalette.primaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .multilineTextAlignment(.leading)
                                .animation(nil, value: displayedText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 6)
                    }
                    .frame(height: 280, alignment: .top)
                } else {
                    compactStoryBody
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 13)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(clusterColor ?? StudioPalette.accentSoft)
                    .frame(width: 3)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(StudioPalette.chromeFillStrong)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(borderColor, lineWidth: 1.35)
        }
        .shadow(color: StudioPalette.shadow.opacity(0.85), radius: 22, y: 12)
        .frame(width: isExpanded ? 640 : 580, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .transaction { transaction in
            if dragStartOffset != nil {
                transaction.animation = nil
            }
        }
        .animation(nil, value: displayedText)
        .animation(.snappy(duration: 0.18), value: isExpanded)
    }

    private var borderColor: Color {
        if let clusterColor {
            return clusterColor.opacity(0.72)
        }
        return StudioPalette.border
    }

    private var playbackHeaderRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(StudioPalette.tertiaryText)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .gesture(dragGesture)
                .help("Drag story card")

            Image(systemName: "book.pages")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StudioPalette.secondaryText)

            Text(state.clusterLabel ?? "Story")
                .font(.caption2.weight(.bold))
                .foregroundStyle(StudioPalette.secondaryText)
                .lineLimit(1)

            Text("\(min(state.index + 1, state.playbackCount))/\(state.playbackCount)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(StudioPalette.tertiaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(StudioPalette.headerSurface, in: Capsule())

            if state.isPaused {
                Text("Paused")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(StudioPalette.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(StudioPalette.headerSurface.opacity(0.8), in: Capsule())
            }

            if state.isReadAloudEnabled, let readAloudStatus = state.readAloudStatus.displayText {
                readAloudStatusPill(readAloudStatus)
            }

            Spacer(minLength: 8)

            controls

            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(StudioPalette.secondaryText)
                    .frame(width: 24, height: 24)
                    .background(StudioPalette.headerSurface.opacity(0.82), in: Circle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Minimize story card" : "Expand story card")
        }
    }

    private func readAloudStatusPill(_ text: String) -> some View {
        Group {
            if state.readAloudStatus.requiresInstall {
                Button {
                    sendCommand(.installReadAloud)
                } label: {
                    Label(text, systemImage: "arrow.down.circle.fill")
                        .font(.caption2.weight(.bold))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(StudioPalette.accent, in: Capsule())
                .help("Install Kokoro for read aloud")
            } else {
                HStack(spacing: 5) {
                    if state.isReadAloudBusy {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.58)
                            .frame(width: 10, height: 10)
                    }

                    Text(text)
                        .font(.caption2.weight(.bold))
                        .lineLimit(1)
                }
                .foregroundStyle(StudioPalette.secondaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(StudioPalette.headerSurface.opacity(0.8), in: Capsule())
            }
        }
    }

    private var compactStoryBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let userStoryText = state.userStoryText {
                Text(userStoryText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(StudioPalette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }

            Text(displayedText)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(StudioPalette.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .lineLimit(4)
                .animation(nil, value: displayedText)

            if let acceptanceText = state.acceptanceText {
                Text(acceptanceText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(StudioPalette.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        HStack(spacing: 6) {
            storyControlButton(
                systemImage: "backward.end.fill",
                help: "Previous beat",
                isDisabled: !state.canGoBackward || state.isReadAloudBusy
            ) {
                sendCommand(.previous)
            }

            storyControlButton(
                systemImage: state.isPaused ? "play.fill" : "pause.fill",
                help: state.isPaused ? "Resume story" : "Pause story",
                isDisabled: state.isReadAloudBusy
            ) {
                sendCommand(.togglePause)
            }

            storyControlButton(
                systemImage: state.isReadAloudEnabled ? "speaker.wave.2.fill" : "speaker.wave.2",
                help: state.isReadAloudEnabled ? "Disable read aloud" : "Read beats aloud with Kokoro Bella",
                isActive: state.isReadAloudEnabled
            ) {
                sendCommand(.toggleReadAloud)
            }

            storyControlButton(
                systemImage: "forward.end.fill",
                help: "Next beat",
                isDisabled: !state.canGoForward || state.isReadAloudBusy
            ) {
                sendCommand(.next)
            }

            storyControlButton(systemImage: "xmark", help: "Stop story") {
                sendCommand(.stop)
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragStartOffset == nil {
                    dragStartOffset = offset
                }
                let start = dragStartOffset ?? .zero
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    offset = CGSize(
                        width: start.width + value.translation.width,
                        height: start.height + value.translation.height
                    )
                }
            }
            .onEnded { _ in
                dragStartOffset = nil
            }
    }

    private func storyControlButton(
        systemImage: String,
        help: String,
        isDisabled: Bool = false,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isDisabled ? StudioPalette.tertiaryText : isActive ? Color.white : StudioPalette.secondaryText)
                .frame(width: 28, height: 28)
                .background(isActive ? StudioPalette.accent : StudioPalette.headerSurface.opacity(isDisabled ? 0.46 : 0.82), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
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
        _expandedGroups = State(initialValue: Set(session.schemaSidecar.clusters.map(\.id)))
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
        let filtered = session.tables.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        let clusters = session.schemaSidecar.clusters
        let groupedNames = Set(clusters.flatMap(\.tables))

        var result: [PickerGroup] = clusters.compactMap { cluster -> PickerGroup? in
            let tables = filtered.filter { cluster.tables.contains($0.name) }
            guard !tables.isEmpty else { return nil }
            return PickerGroup(
                id: cluster.id,
                label: cluster.label ?? cluster.id,
                color: cluster.color.flatMap { Color(studioHex: $0) },
                tables: tables
            )
        }
        let ungrouped = filtered.filter { !groupedNames.contains($0.name) }
        if !ungrouped.isEmpty {
            result.append(PickerGroup(id: "__ungrouped__", label: "Other", color: nil, tables: ungrouped))
        }
        // If no clusters defined just show everything as one flat group
        if clusters.isEmpty {
            return [PickerGroup(id: "__all__", label: "Tables", color: nil, tables: filtered)]
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
                        if expandedGroups.contains(group.id) {
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
                    Text(table.name)
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
                Text("Install skills into your database directory for AI coding agents.")
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
