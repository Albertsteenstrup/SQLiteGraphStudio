import Foundation
import Observation

public struct RecordExpansionKey: Hashable, Sendable {
    public let recordID: String
    public let relationshipID: String
    public let direction: RecordDirection
    public init(recordID: String, relationshipID: String, direction: RecordDirection) {
        self.recordID = recordID; self.relationshipID = relationshipID; self.direction = direction
    }
}

public struct RecordGraphLimits: Sendable {
    public let nodes: Int
    public let edges: Int
    public let depth: Int
    public let queries: Int
    public init(nodes: Int = 100, edges: Int = 250, depth: Int = 4, queries: Int = 120) {
        self.nodes = max(1, nodes); self.edges = max(1, edges)
        self.depth = max(0, depth); self.queries = max(1, queries)
    }
}

public struct RecordGraphBranch {
    public var records: [String: RecordSnapshot] = [:]
    public var edges: [String: GraphEdge] = [:]
    public var undirectedEdgeIDs: Set<String> = []
    public var hasMore = false
    public var nextOffset: Int?
    public var message: String?
}

/// A bounded exploration, with contributions tracked per expanded relationship.
/// Traversal direction is separate from FK direction so collapsing incoming branches works too.
@MainActor @Observable
public final class RecordGraphModel {
    public private(set) var root: RecordSnapshot?
    public private(set) var records: [String: RecordSnapshot] = [:]
    public private(set) var branches: [RecordExpansionKey: RecordGraphBranch] = [:]
    public private(set) var queriesUsed = 0
    public private(set) var limitMessage: String?
    public let limits: RecordGraphLimits
    public let layout = GraphLayoutModel()

    public init(limits: RecordGraphLimits = .init()) { self.limits = limits }

    public var graph: SchemaGraph {
        let edges = branches.values.reduce(into: [String: GraphEdge]()) { result, branch in
            result.merge(branch.edges) { _, new in new }
        }
        return SchemaGraph(
            nodes: records.values.sorted { $0.id < $1.id }.map { GraphNode(id: $0.id, title: $0.label, isEditable: false) },
            edges: edges.values.sorted { $0.id < $1.id }
        )
    }

    public var undirectedEdgeIDs: Set<String> {
        branches.values.reduce(into: Set<String>()) { $0.formUnion($1.undirectedEdgeIDs) }
    }

    public func setRoot(_ record: RecordSnapshot?) {
        root = record?.identity == nil ? nil : record
        records = root.map { [$0.id: $0] } ?? [:]
        branches = [:]; queriesUsed = 0; limitMessage = nil
        layout.reset(for: graph)
    }

    public func beginExpansion(from record: RecordSnapshot, cost: Int = 1) -> Bool {
        guard records[record.id] != nil, record.identity != nil else { return false }
        guard queriesUsed + cost <= limits.queries else {
            limitMessage = "Query budget reached (\(limits.queries)). Choose a new root to continue."; return false
        }
        guard (depths()[record.id] ?? Int.max) < limits.depth else {
            limitMessage = "Depth limit reached (\(limits.depth)). Choose this record as a new root to continue."; return false
        }
        guard records.count < limits.nodes, graph.edges.count < limits.edges else {
            limitMessage = "Graph limit reached. Collapse a branch or choose a new root to continue."; return false
        }
        queriesUsed += cost
        return true
    }

    public func add(_ page: RecordPage, from source: RecordSnapshot, relationship: RecordRelationship, direction: RecordDirection, offset: Int = 0) {
        guard records[source.id] != nil else { return }
        let key = RecordExpansionKey(recordID: source.id, relationshipID: relationship.id, direction: direction)
        var branch = branches[key] ?? RecordGraphBranch()
        var knownEdges = Set(graph.edges.map(\.id))
        var consumed = 0
        var clipped = false
        var identityless = 0
        for target in page.records {
            guard target.identity != nil else { consumed += 1; identityless += 1; continue }
            let from = direction == .outgoing ? source.id : target.id
            let to = direction == .outgoing ? target.id : source.id
            let edgeID = [relationship.id, from, to].map { "\($0.utf8.count):\($0)" }.joined()
            if (records[target.id] == nil && records.count >= limits.nodes) || (!knownEdges.contains(edgeID) && knownEdges.count >= limits.edges) {
                clipped = true; break
            }
            records[target.id] = target; branch.records[target.id] = target
            branch.edges[edgeID] = GraphEdge(id: edgeID, sourceID: from, targetID: to, sourceColumn: relationship.sourceColumns.joined(separator: ", "), targetColumn: relationship.targetColumns.joined(separator: ", "))
            knownEdges.insert(edgeID); consumed += 1
        }
        branch.hasMore = clipped || page.hasMore
        branch.nextOffset = clipped ? offset + consumed : page.nextOffset
        if identityless > 0 { branch.message = "\(identityless) related rows have no stable identity; inspect them in the related-record list." }
        if clipped { limitMessage = "Partial graph: node or edge limit reached. Collapse a branch to load more." }
        branches[key] = branch
    }

    public func addMapped(_ page: RecordMappedPage, from source: RecordSnapshot, mappingID: String, direction: RecordDirection, offset: Int = 0) {
        guard records[source.id] != nil else { return }
        let key = RecordExpansionKey(recordID: source.id, relationshipID: "mapping:" + mappingID, direction: direction)
        var branch = branches[key] ?? RecordGraphBranch()
        var knownEdges = Set(graph.edges.map(\.id))
        var clippedOffset: Int?
        for connection in page.connections {
            let candidates = [connection.source, connection.target]
            let newIDs = Set(candidates.map(\.id)).subtracting(records.keys)
            let edgeID = "mapped:\(mappingID.utf8.count):\(mappingID):\(connection.id)"
            if records.count + newIDs.count > limits.nodes || (!knownEdges.contains(edgeID) && knownEdges.count >= limits.edges) {
                clippedOffset = connection.edgeOffset; break
            }
            for record in candidates { records[record.id] = record; branch.records[record.id] = record }
            branch.edges[edgeID] = GraphEdge(id: edgeID, sourceID: connection.source.id, targetID: connection.target.id, sourceColumn: connection.label ?? "Mapped edge", targetColumn: "")
            if !connection.isDirected { branch.undirectedEdgeIDs.insert(edgeID) }
            knownEdges.insert(edgeID)
        }
        branch.hasMore = clippedOffset != nil || page.hasMore
        branch.nextOffset = clippedOffset ?? page.nextOffset
        branch.message = page.messages.isEmpty ? nil : page.messages.joined(separator: " ")
        if clippedOffset != nil { limitMessage = "Partial graph: node or edge limit reached. Collapse a branch to load more." }
        branches[key] = branch
    }

    public func collapse(_ key: RecordExpansionKey) {
        branches[key] = nil
        let reachable = Set(depths().keys)
        branches = branches.filter { reachable.contains($0.key.recordID) }
        records = root.map { [$0.id: $0] } ?? [:]
        for branch in branches.values { records.merge(branch.records) { _, new in new } }
        limitMessage = nil
    }

    private func depths() -> [String: Int] {
        guard let root else { return [:] }
        var result = [root.id: 0]
        var queue = [root.id], cursor = 0
        while cursor < queue.count {
            let source = queue[cursor]; cursor += 1
            for (key, branch) in branches where key.recordID == source {
                for target in branch.records.keys where result[target] == nil {
                    result[target] = result[source, default: 0] + 1; queue.append(target)
                }
            }
        }
        return result
    }
}
