import Foundation

public struct GraphNode: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let isEditable: Bool

    public init(id: String, title: String, isEditable: Bool) {
        self.id = id
        self.title = title
        self.isEditable = isEditable
    }
}

public struct GraphEdge: Identifiable, Sendable, Hashable {
    public let id: String
    public let sourceID: String
    public let targetID: String
    public let sourceColumn: String
    public let targetColumn: String

    public init(id: String, sourceID: String, targetID: String, sourceColumn: String, targetColumn: String) {
        self.id = id
        self.sourceID = sourceID
        self.targetID = targetID
        self.sourceColumn = sourceColumn
        self.targetColumn = targetColumn
    }
}

public struct SchemaGraph: Sendable, Hashable {
    public let nodes: [GraphNode]
    public let edges: [GraphEdge]
    private let adjacency: [String: Set<String>]

    public init(nodes: [GraphNode], edges: [GraphEdge]) {
        self.nodes = nodes
        self.edges = edges

        var adjacency: [String: Set<String>] = [:]
        for edge in edges {
            adjacency[edge.sourceID, default: []].insert(edge.targetID)
            adjacency[edge.targetID, default: []].insert(edge.sourceID)
        }
        self.adjacency = adjacency
    }

    public static let empty = SchemaGraph(nodes: [], edges: [])

    public func neighbors(of nodeID: String) -> Set<String> {
        adjacency[nodeID, default: []]
    }

    public func contains(nodeID: String) -> Bool {
        nodes.contains { $0.id == nodeID }
    }
}
