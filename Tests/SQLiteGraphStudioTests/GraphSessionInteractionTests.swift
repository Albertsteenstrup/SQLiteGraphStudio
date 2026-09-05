import Foundation
import Testing
@testable import StudioCore

@MainActor
struct GraphSessionInteractionTests {
    @Test func marqueePreservesPrimaryUntilItLeavesTheSelection() throws {
        let suite = "GraphSessionInteractionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = AppSession(databaseService: DatabaseService(), userDefaults: defaults)
        session.graph = SchemaGraph(nodes: ["a", "b", "c"].map {
            GraphNode(id: $0, title: $0, isEditable: true)
        }, edges: [])

        session.selectGraphNode("b")
        session.setGraphSelection(["a", "b", "missing"])
        #expect(session.selectedGraphNodeIDs == ["a", "b"])
        #expect(session.selectedGraphNodeID == "b")
        for _ in 0..<100 { session.setGraphSelection(["a", "b", "missing"]) }
        #expect(session.selectedGraphNodeID == "b")
        session.setGraphSelection(["a", "c"])
        #expect(session.selectedGraphNodeID == "a")
        session.setGraphSelection([])
        #expect(session.selectedGraphNodeID == nil)
    }

    @Test func indexedHighlightMatchesAllEdgesIncludingSelfReferences() {
        let graph = SchemaGraph(nodes: ["a", "b"].map {
            GraphNode(id: $0, title: $0, isEditable: true)
        }, edges: [
            GraphEdge(id: "self", sourceID: "a", targetID: "a", sourceColumn: "parent_id", targetColumn: "id"),
            GraphEdge(id: "out", sourceID: "a", targetID: "b", sourceColumn: "parent_id", targetColumn: "id"),
            GraphEdge(id: "in", sourceID: "b", targetID: "a", sourceColumn: "a_id", targetColumn: "id")
        ])
        let index = GraphTopologyIndex(graph: graph)
        let targets: [GraphRelationHoverTarget?] = [nil,
            .init(tableID: "a", columnName: "id", endpointKind: .primary),
            .init(tableID: "a", columnName: "parent_id", endpointKind: .foreign),
            .init(tableID: "a", columnName: "id", endpointKind: .column)
        ]
        for target in targets {
            let expected = GraphRelationHighlight(graph: graph, focusNodeID: "a", hoverTarget: target)
            let indexed = GraphRelationHighlight(graph: graph, focusNodeID: "a", hoverTarget: target, edgeLookup: index)
            #expect(indexed.highlightedEdgeIDs == expected.highlightedEdgeIDs)
            for node in graph.nodes {
                #expect(indexed.highlightState(for: node.id) == expected.highlightState(for: node.id))
            }
        }
    }
}
