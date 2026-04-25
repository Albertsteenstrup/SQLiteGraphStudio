import CoreGraphics
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
}
