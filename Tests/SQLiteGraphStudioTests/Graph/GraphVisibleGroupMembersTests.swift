import Testing
@testable import StudioCore

struct GraphVisibleGroupMembersTests {
    @Test
    func filteredMembersAreRemovedBeforeDrawingAndCounting() {
        let renderedGraph = SchemaGraph(
            nodes: [
                GraphNode(id: "orders", title: "orders", isEditable: true),
                GraphNode(id: "line_items", title: "line_items", isEditable: true),
            ],
            edges: []
        )
        let groupNodeIDs = ["orders", "hidden_audit", "line_items"]

        let visibleMembers = GraphVisibleGroupMembers.intersection(
            groupNodeIDs, renderedGraph: renderedGraph
        )

        #expect(visibleMembers == ["orders", "line_items"])
        #expect(visibleMembers.count == 2)
    }

    @Test
    func allVisibleMembersKeepTheirExistingOrderAndCount() {
        let renderedGraph = SchemaGraph(
            nodes: [
                GraphNode(id: "line_items", title: "line_items", isEditable: true),
                GraphNode(id: "orders", title: "orders", isEditable: true),
            ],
            edges: []
        )
        let groupNodeIDs = ["orders", "line_items"]

        #expect(GraphVisibleGroupMembers.intersection(groupNodeIDs, renderedGraph: renderedGraph) == groupNodeIDs)
    }
}
