import Foundation
import GRDB
import Testing
@testable import StudioCore

@MainActor
struct GraphSessionInteractionTests {
    @Test func compactArrangementReservesCompositeKeyNeighbourPreviews() async throws {
        let url = TestSupport.temporaryDatabaseURL(named: "compact-preview")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let columns = (0..<16).map { "key_\($0)" }
        let names = columns.joined(separator: ", ")
        let definitions = columns.map { "\($0) INTEGER" }.joined(separator: ", ")
        let database = try DatabaseQueue(path: url.path)
        try await database.write { db in
            try db.execute(sql: "CREATE TABLE parent(\(definitions), PRIMARY KEY(\(names)))")
            try db.execute(sql: "CREATE TABLE child(\(definitions), FOREIGN KEY(\(names)) REFERENCES parent(\(names)))")
        }
        try database.close()
        let suite = "GraphSessionInteractionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = AppSession(userDefaults: defaults)
        await session.openDatabase(url: url)
        session.expandedGraphNodeIDs = ["parent"]
        session.compactGraphTables(["parent", "child"], columns: 1)

        let parentCenter = session.graphLayout.position(for: "parent")
        let childCenter = session.graphLayout.position(for: "child")
        // The expanded parent lists seven rows; its child previews all sixteen key
        // components. Reserving only a collapsed child would cover the parent.
        let parentBottom = parentCenter.y + (46 + 10 + 12 + 7 * 24) / 2
        let childTop = childCenter.y - (46 + 10 + 12 + 16 * 24) / 2
        #expect(childTop - parentBottom >= 80)
        await session.closeAndWait()
    }

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
