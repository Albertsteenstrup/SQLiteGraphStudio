import CoreGraphics
import Foundation
import Testing
@testable import StudioCore

@MainActor
struct WorkspaceStateTests {
    @Test
    func sourceReservationsCountWhileAsynchronousOpensAreStillPending() {
        let controller = WorkspaceTabController(initialSession: AppSession())
        let tabs = (0..<5).map { _ in controller.createTab(activate: false) }
        for tab in tabs.prefix(4) { #expect(controller.reserveDocumentOpening(for: tab.id)) }
        #expect(controller.liveDocumentCount == 4)
        #expect(!controller.reserveDocumentOpening(for: tabs[4].id))
        controller.finishDocumentOpening(for: tabs[0].id)
        #expect(controller.reserveDocumentOpening(for: tabs[4].id))
    }

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
    func agentReviewsReplaceTheirSessionsTabAndOtherSessionsGetTheirOwn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-tabs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = SchemaReviewSnapshot(engine: "sqlite", tables: [], relations: [])
        func review(_ name: String, title: String, session: String?) throws -> URL {
            let url = root.appendingPathComponent(name)
            let author = SchemaReviewDocument.Author(tool: "claude", session: session)
            try SchemaReviewDocument(title: title, baseRef: "a", headRef: "b", before: empty, after: empty, author: author)
                .write(to: url)
            return url
        }
        let controller = WorkspaceTabController(initialSession: AppSession(databaseService: DatabaseService()))
        let workspaceTabID = controller.activeTabID

        let first = try #require(await controller.openDocument(try review("a1.sgreview", title: "A v1", session: "Session A")))
        let other = try #require(await controller.openDocument(try review("b1.sgreview", title: "B v1", session: "Session B")))
        #expect(controller.tabs.map(\.id) == [workspaceTabID, first.id, other.id])

        // An updated review from the same session, even at a new path, takes over its tab's place.
        controller.activate(first.id)
        let updated = try #require(await controller.openDocument(try review("a2.sgreview", title: "A v2", session: "Session A")))
        #expect(updated.id != first.id)
        #expect(controller.tabs.map(\.id) == [workspaceTabID, updated.id, other.id])
        #expect(controller.activeTabID == updated.id)
        #expect(updated.session.schemaReview?.title == "A v2")
        #expect(other.session.schemaReview?.title == "B v1")

        // Rewriting the same file reloads it instead of just re-activating stale content.
        let rewritten = try review("b1.sgreview", title: "B v2", session: "Session B")
        let reloaded = try #require(await controller.openDocument(rewritten))
        #expect(controller.tabs.map(\.id) == [workspaceTabID, updated.id, reloaded.id])
        #expect(reloaded.session.schemaReview?.title == "B v2")

        // Without a session name there is no identity to match, so only the same file is replaced.
        let unnamed = try #require(await controller.openDocument(try review("c1.sgreview", title: "C v1", session: nil)))
        let secondUnnamed = try #require(await controller.openDocument(try review("c2.sgreview", title: "C v2", session: nil)))
        #expect(controller.tabs.map(\.id) == [workspaceTabID, updated.id, reloaded.id, unnamed.id, secondUnnamed.id])
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
