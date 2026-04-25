import Foundation

public enum EdgeCardinality: String, Sendable, Hashable, Codable {
    case oneToOne    // source unique, target unique
    case oneToMany   // source unique, target not unique
    case manyToOne   // source not unique, target unique
    case manyToMany  // neither unique
}

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
    public let cardinality: EdgeCardinality

    public init(
        id: String,
        sourceID: String,
        targetID: String,
        sourceColumn: String,
        targetColumn: String,
        cardinality: EdgeCardinality = .manyToOne
    ) {
        self.id = id
        self.sourceID = sourceID
        self.targetID = targetID
        self.sourceColumn = sourceColumn
        self.targetColumn = targetColumn
        self.cardinality = cardinality
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
