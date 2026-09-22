import CoreGraphics
import Foundation
import Testing
@testable import StudioCore

@MainActor
struct WorkspaceStateTests {
    /// A defaults domain of this test's own, so a session that persists recents
    /// cannot reach the developer's real ones. Callers clear it with `defer`.
    private func makeIsolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "SQLiteGraphStudioTests.workspace-state.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suiteName)), suiteName)
    }

    @Test
    func draggingDockItemsSwapsPaneContentWithoutDuplicates() {
        let session = AppSession(databaseService: DatabaseService())

        #expect(session.leftPane.kind == .schema)
        #expect(session.rightPane.kind == .tables)

        session.setPaneContent(.query, for: .right)
        #expect(session.leftPane.kind == .schema)
        #expect(session.rightPane.kind == .query)

        session.applyDockItem(WorkspaceDockItem(kind: .schema), to: .right)
        #expect(session.leftPane.kind == .query)
        #expect(session.rightPane.kind == .schema)

        session.ensurePaneVisible(.tables)
        #expect(session.leftPane.kind == .query)
        #expect(session.rightPane.kind == .tables)
        #expect(Set([session.leftPane.kind, session.rightPane.kind]).count == 2)
    }

    @Test
    func floatingDetailsStateTracksSelectionAndPosition() {
        let session = AppSession(databaseService: DatabaseService())
        session.graph = SchemaGraph(
            nodes: [
                GraphNode(id: "authors", title: "authors", isEditable: true),
                GraphNode(id: "posts", title: "posts", isEditable: true),
            ],
            edges: []
        )

        let position = CGPoint(x: 240, y: 180)
        session.showFloatingDetails(for: "posts", preferredPosition: position)

        #expect(session.selectedGraphNodeID == "posts")
        #expect(session.floatingDetailsCardTableID == "posts")
        #expect(session.floatingDetailsCardPosition == position)

        let nextPosition = CGPoint(x: 320, y: 220)
        session.updateFloatingDetailsPosition(nextPosition)
        #expect(session.floatingDetailsCardPosition == nextPosition)

        session.closeFloatingDetails()
        #expect(session.floatingDetailsCardTableID == nil)
        #expect(session.floatingDetailsCardPosition == nil)
    }

    @Test
    func inlineExpansionStateAndPaneFocusAreExplicit() {
        let session = AppSession(databaseService: DatabaseService())
        session.graph = SchemaGraph(
            nodes: [
                GraphNode(id: "authors", title: "authors", isEditable: true),
                GraphNode(id: "posts", title: "posts", isEditable: true),
            ],
            edges: []
        )

        #expect(session.activePaneSide == .right)
        session.setActivePaneSide(.left)
        #expect(session.activePaneSide == .left)

        session.toggleGraphNodeExpansion("authors")
        #expect(session.isGraphNodeExpanded("authors"))
        #expect(!session.isGraphNodeExpanded("posts"))

        session.setShowAllGraphTableCards(true)
        #expect(session.isGraphNodeExpanded("authors"))
        #expect(session.isGraphNodeExpanded("posts"))

        session.setShowAllGraphTableCards(false)
        #expect(session.isGraphNodeExpanded("authors"))
        #expect(!session.isGraphNodeExpanded("posts"))

        session.collapseExpandedGraphNodes()
        #expect(!session.isGraphNodeExpanded("authors"))
    }

    @Test
    func narrowWorkspaceCollapsesToASinglePaneAndKeepsTheGraph() {
        let session = AppSession(databaseService: DatabaseService())

        #expect(session.leftPane.kind == .schema)
        #expect(session.activePaneSide == .right)
        #expect(!session.isWorkspaceCompact)
        #expect(session.compactVisibleSide == nil)

        // A window wide enough for two panes leaves the layout alone.
        session.updateWorkspaceWidth(1180)
        #expect(!session.isWorkspaceCompact)
        #expect(session.activePaneSide == .right)

        // Tiled beside another application, only one pane fits — the graph.
        session.updateWorkspaceWidth(700)
        #expect(session.isWorkspaceCompact)
        #expect(session.compactVisibleSide == .left)
        #expect(session.paneState(for: .left).kind == .schema)

        // Widening again restores both panes.
        session.updateWorkspaceWidth(1180)
        #expect(!session.isWorkspaceCompact)
        #expect(session.compactVisibleSide == nil)
    }

    @Test
    func compactWorkspaceKeepsTheChosenPaneOnScreen() {
        let session = AppSession(databaseService: DatabaseService())

        session.updateWorkspaceWidth(700)
        #expect(session.compactVisibleSide == .left)
        #expect(session.paneState(for: .left).kind == .schema)

        // Swapping content into the visible side keeps that side on screen
        // rather than jumping back to wherever the graph landed.
        session.setPaneContent(.tables, for: .left)
        #expect(session.compactVisibleSide == .left)
        #expect(session.paneState(for: .left).kind == .tables)
        #expect(session.paneState(for: .right).kind == .schema)

        // Further resizing inside the compact range does not undo that choice.
        session.updateWorkspaceWidth(640)
        #expect(session.compactVisibleSide == .left)
        #expect(session.paneState(for: .left).kind == .tables)

        // Crossing back out and in prefers the graph again.
        session.updateWorkspaceWidth(1180)
        session.updateWorkspaceWidth(640)
        #expect(session.compactVisibleSide == .right)
        #expect(session.paneState(for: .right).kind == .schema)
    }

    @Test
    func openingADatabaseWhileCompactKeepsTheGraphOnScreen() throws {
        // Opening a document returns pane focus to its default side, which is
        // the tables pane. While compact that side is the only one on screen,
        // so the default has to bend to the graph or opening would push it out
        // of view.
        // `apply` remembers the document, so the session gets its own defaults
        // rather than writing a bogus path into the developer's Open Recent.
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = AppSession(databaseService: DatabaseService(), userDefaults: defaults)
        session.updateWorkspaceWidth(700)
        #expect(session.compactVisibleSide == .left)

        session.setPaneContent(.tables, for: .left)
        #expect(session.paneState(for: .left).kind == .tables)

        session.apply(
            snapshot: CatalogSnapshot(descriptors: [], graph: SchemaGraph(nodes: [], edges: [])),
            target: .sqlite(URL(fileURLWithPath: "/tmp/compact-open-fixture.sqlite"))
        )

        #expect(session.compactVisibleSide == .right)
        #expect(session.paneState(for: .right).kind == .schema)
    }

    @Test
    func refreshingTheOpenDatabaseWhileCompactLeavesThePaneChoiceAlone() throws {
        // A refresh is not a new document. Whichever pane the user put on screen
        // stays there, graph or not.
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = AppSession(databaseService: DatabaseService(), userDefaults: defaults)
        let target = DatabaseTarget.sqlite(URL(fileURLWithPath: "/tmp/compact-refresh-fixture.sqlite"))
        let snapshot = CatalogSnapshot(descriptors: [], graph: SchemaGraph(nodes: [], edges: []))

        session.updateWorkspaceWidth(700)
        session.apply(snapshot: snapshot, target: target)
        session.setPaneContent(.tables, for: session.activePaneSide)
        let chosenSide = session.activePaneSide
        #expect(session.paneState(for: chosenSide).kind == .tables)

        session.apply(snapshot: snapshot, target: target)

        #expect(session.compactVisibleSide == chosenSide)
        #expect(session.paneState(for: chosenSide).kind == .tables)
    }

    @Test
    func compactWorkspaceFallsBackToTheActivePaneWithoutAGraph() {
        let session = AppSession(databaseService: DatabaseService())

        session.setPaneContent(.query, for: .left)
        #expect(session.side(containing: .schema) == nil)
        #expect(session.activePaneSide == .left)

        session.updateWorkspaceWidth(700)
        #expect(session.isWorkspaceCompact)
        #expect(session.compactVisibleSide == .left)
    }

    @Test
    func compactThresholdHasHysteresisAndIgnoresUnusableWidths() {
        var layout = WorkspaceCompactLayout()

        // `update` mutates, so each call happens before its expectation rather than
        // inside it: #expect captures its operands immutably, and a mutating call
        // nested in the macro fails to compile.
        var changed = layout.update(width: 0)
        #expect(!changed)
        changed = layout.update(width: .nan)
        #expect(!changed)
        #expect(!layout.isCompact)

        changed = layout.update(width: WorkspaceCompactLayout.collapseWidth)
        #expect(!changed)
        #expect(!layout.isCompact)

        changed = layout.update(width: WorkspaceCompactLayout.collapseWidth - 1)
        #expect(changed)
        #expect(layout.isCompact)

        // Between the two thresholds the layout stays put, so a resize drag that
        // hovers on the boundary cannot flap the panes.
        changed = layout.update(width: WorkspaceCompactLayout.collapseWidth + 10)
        #expect(!changed)
        #expect(layout.isCompact)

        changed = layout.update(width: WorkspaceCompactLayout.restoreWidth)
        #expect(changed)
        #expect(!layout.isCompact)
    }

    @Test
    func theSinglePaneLayoutHoldsTheOffScreenPaneShut() {
        // The divider stays draggable when one pane owns the workspace, and the
        // off-screen pane is transparent and takes no clicks — so if it can be
        // given any width at all, dragging peels it open as a blank strip. Its
        // maximum has to be zero, not just its minimum.
        let hidden = WorkspaceCompactLayout.paneWidthBounds(for: .right, fullscreenSide: .left)
        #expect(hidden.minimum == 0)
        #expect(hidden.maximum == 0)

        let shown = WorkspaceCompactLayout.paneWidthBounds(for: .left, fullscreenSide: .left)
        #expect(shown.minimum == WorkspaceCompactLayout.singlePaneMinimumWidth)
        #expect(shown.maximum == .infinity)

        // Both panes on screen keep the hand-drag floor and stay resizable.
        for side in WorkspacePaneSide.allCases {
            let split = WorkspaceCompactLayout.paneWidthBounds(for: side, fullscreenSide: nil)
            #expect(split.minimum == WorkspaceCompactLayout.splitPaneMinimumWidth)
            #expect(split.maximum == .infinity)
        }
    }

    @Test
    func theNarrowestWindowCanStillReachTheCompactLayout() {
        // The whole feature rests on this: two panes at their minimum have to fit
        // inside the smallest window, and that smallest window has to be narrow
        // enough to cross the collapse threshold. If a later change raises the
        // window floor past `collapseWidth`, the split view would be forced wider
        // than the space available and the compact layout would be unreachable.
        let narrowest = WorkspaceCompactLayout.narrowestWorkspaceWidth
        #expect(WorkspaceCompactLayout.splitPaneMinimumWidth * 2 < narrowest)
        #expect(WorkspaceCompactLayout.singlePaneMinimumWidth < narrowest)
        #expect(narrowest < WorkspaceCompactLayout.collapseWidth)
        #expect(WorkspaceCompactLayout.collapseWidth < WorkspaceCompactLayout.restoreWidth)

        var layout = WorkspaceCompactLayout()
        let changed = layout.update(width: narrowest)
        #expect(changed)
        #expect(layout.isCompact)
    }

    @Test
    func maximizedPaneTracksThePaneSide() {
        let session = AppSession(databaseService: DatabaseService())

        session.toggleMaximizePane(.left)
        #expect(session.maximizedPaneSide == .left)
        #expect(session.isMaximized(.left))
        #expect(!session.isMaximized(.right))

        session.toggleMaximizePane(.right)
        #expect(session.maximizedPaneSide == .right)

        session.toggleMaximizePane(.right)
        #expect(session.maximizedPaneSide == nil)
    }
}
