import CoreGraphics
import Foundation
import Testing
@testable import StudioCore

@MainActor
struct WorkspaceStateTests {
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
