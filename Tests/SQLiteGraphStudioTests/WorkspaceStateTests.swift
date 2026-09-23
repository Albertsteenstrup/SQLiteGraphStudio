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

    @Test
    func workspaceTabsOwnIndependentGraphPaneAndQueryState() {
        let firstDomain = "WorkspaceTabsTests.first.\(UUID().uuidString)"
        let secondDomain = "WorkspaceTabsTests.second.\(UUID().uuidString)"
        let firstDefaults = UserDefaults(suiteName: firstDomain)!
        let secondDefaults = UserDefaults(suiteName: secondDomain)!
        defer {
            firstDefaults.removePersistentDomain(forName: firstDomain)
            secondDefaults.removePersistentDomain(forName: secondDomain)
        }

        let firstSession = AppSession(databaseService: DatabaseService(), userDefaults: firstDefaults)
        let controller = WorkspaceTabController(initialSession: firstSession) {
            AppSession(databaseService: DatabaseService(), userDefaults: secondDefaults)
        }
        let firstTab = controller.activeTab!
        #expect(firstSession.leftPane.kind == .schema)
        #expect(firstSession.rightPane.kind == .tables)

        firstSession.graphZoom = 1.25
        firstSession.selectedGraphNodeIDs = ["authors"]
        let firstQuery = firstSession.queryWorkspace.createQuery(sqlText: "SELECT 'first';")

        let secondTab = controller.createTab(kind: .comparison, title: "Preview vs. live")
        let secondSession = secondTab.session
        #expect(secondTab.id != firstTab.id)
        #expect(secondSession !== firstSession)
        #expect(secondSession.leftPane.kind == .schema)
        #expect(secondSession.rightPane.kind == .tables)

        secondSession.graphZoom = 2.0
        secondSession.selectedGraphNodeIDs = ["posts"]
        secondSession.setPaneContent(.query, for: .right)
        let secondQuery = secondSession.queryWorkspace.createQuery(sqlText: "SELECT 'second';")

        #expect(firstSession.graphZoom == 1.25)
        #expect(firstSession.selectedGraphNodeIDs == ["authors"])
        #expect(firstSession.rightPane.kind == .tables)
        #expect(firstSession.queryWorkspace.activeQuery?.id == firstQuery.id)
        #expect(firstSession.queryWorkspace.activeQuery?.sqlText == "SELECT 'first';")
        #expect(secondSession.graphZoom == 2.0)
        #expect(secondSession.selectedGraphNodeIDs == ["posts"])
        #expect(secondSession.rightPane.kind == .query)
        #expect(secondSession.queryWorkspace.activeQuery?.id == secondQuery.id)
        #expect(secondSession.queryWorkspace.activeQuery?.sqlText == "SELECT 'second';")
    }

    @Test
    func openingSeveralDocumentsCreatesIndependentTabsAndKeepsFirstActive() async {
        let controller = WorkspaceTabController(initialSession: AppSession(databaseService: DatabaseService()))
        let initialTabID = controller.activeTabID
        let urls = [
            URL(fileURLWithPath: "/tmp/orders.sgpreview"),
            URL(fileURLWithPath: "/tmp/orders-v2.sgreview"),
        ]

        let opened = await controller.openDocuments(urls)

        #expect(opened.count == 2)
        #expect(controller.tabs.count == 3)
        #expect(controller.activeTabID == opened[0].id)
        #expect(opened[0].kind == .preview)
        #expect(opened[1].kind == .comparison)
        #expect(opened[0].session !== opened[1].session)
        #expect(opened[0].session.presentedError != nil)
        #expect(opened[1].session.presentedError != nil)

        await controller.closeAndWait(opened[0].id)
        #expect(controller.tabs.map(\.id) == [initialTabID!, opened[1].id])
        #expect(controller.activeTabID == opened[1].id)
    }

    @Test
    func closingOneWorkspaceDoesNotCloseAnotherWorkspaceOnTheSameDatabase() async throws {
        let url = try TestSupport.createFixture(named: "same-source-workspaces")
        let controller = WorkspaceTabController(
            initialSession: AppSession(databaseService: DatabaseService())
        )
        let first = controller.activeTab!
        await first.session.openDatabase(url: url)
        let second = controller.createTab()
        await second.session.openDatabase(url: url)

        await controller.closeAndWait(first.id)

        #expect(!first.session.hasOpenDatabase)
        #expect(second.session.hasOpenDatabase)
        let authors = try #require(second.session.openTable(named: "authors", autoLoad: false))
        await authors.reload()
        #expect(authors.chunk.totalRowCount == 8)
    }

    @Test
    func workspaceControllerPublishesActiveAndClosedTabTransitions() async {
        let controller = WorkspaceTabController(initialSession: AppSession(databaseService: DatabaseService()))
        let first = controller.activeTab!
        var activeChanges: [UUID?] = []
        var closedTabs: [UUID] = []
        controller.onActiveTabChanged = { activeChanges.append($0) }
        controller.onTabClosed = { closedTabs.append($0) }

        let second = controller.createTab(activate: false)
        #expect(activeChanges.isEmpty)
        controller.activate(second.id)
        #expect(activeChanges == [second.id])

        await controller.closeAndWait(second.id)

        #expect(activeChanges == [second.id, first.id])
        #expect(closedTabs == [second.id])
    }
}
