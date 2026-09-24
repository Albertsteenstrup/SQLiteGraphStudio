import Foundation

/// How a schema review weighs each table and relation on the canvas.
///
/// With nothing chosen, every change is the subject at once. Choosing changed tables —
/// in the graph or in the review's table list — narrows the subject to their own changes:
/// those tables, the relations they gained or lost, and the tables at the far ends of those
/// relations. Changes elsewhere fade rather than disappear, so the reader keeps their
/// bearings while reading one change at a time.
///
/// What did not change is context, never subject. Hover, relation highlights and labels
/// spend their emphasis only on changes, because a hub table can carry dozens of unchanged
/// relations that would otherwise bury the one that moved.
struct SchemaReviewLens: Equatable {
    enum Emphasis: Int, Comparable, Sendable {
        /// Unchanged: drawn quietly, or not at all while zoomed out.
        case context
        /// A change outside the reader's current focus.
        case faded
        /// A change the reader is looking at.
        case subject

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Changed tables the reader chose. Empty means every change is in focus.
    let focusIDs: Set<String>
    private let tableKinds: [String: SchemaChangeKind]
    private let edgeKinds: [String: SchemaChangeKind]
    private let changedNeighborsByTable: [String: Set<String>]
    private let subjectTableIDs: Set<String>
    /// Changed tables, whole-table additions and removals first, then by identifier, so
    /// the most consequential names claim label space and the order is stable while panning.
    private let rankedChangedTableIDs: [String]

    init(
        tableKinds: [String: SchemaChangeKind],
        edgeKinds: [String: SchemaChangeKind],
        edges: [GraphEdge],
        selection: Set<String>
    ) {
        self.tableKinds = tableKinds
        self.edgeKinds = edgeKinds

        var neighbors: [String: Set<String>] = [:]
        for edge in edges where (edgeKinds[edge.id] ?? .unchanged) != .unchanged {
            neighbors[edge.sourceID, default: []].insert(edge.targetID)
            neighbors[edge.targetID, default: []].insert(edge.sourceID)
        }
        changedNeighborsByTable = neighbors

        // Choosing an unchanged table has no changes to isolate, so every change stays in view.
        let focus = selection.filter { (tableKinds[$0] ?? .unchanged) != .unchanged }
        focusIDs = focus
        subjectTableIDs = focus.reduce(into: focus) { $0.formUnion(neighbors[$1] ?? []) }

        rankedChangedTableIDs = tableKinds.compactMap { $0.value == .unchanged ? nil : $0.key }.sorted { lhs, rhs in
            let lhsRank = Self.labelRank(tableKinds[lhs]), rhsRank = Self.labelRank(tableKinds[rhs])
            return lhsRank == rhsRank ? lhs < rhs : lhsRank < rhsRank
        }
    }

    var isFocused: Bool { !focusIDs.isEmpty }

    func kind(forTable id: String) -> SchemaChangeKind { tableKinds[id] ?? .unchanged }

    func kind(forEdge id: String) -> SchemaChangeKind { edgeKinds[id] ?? .unchanged }

    func emphasis(forTable id: String) -> Emphasis {
        guard kind(forTable: id) != .unchanged else { return .context }
        guard isFocused else { return .subject }
        return subjectTableIDs.contains(id) ? .subject : .faded
    }

    func emphasis(for edge: GraphEdge) -> Emphasis {
        guard kind(forEdge: edge.id) != .unchanged else { return .context }
        guard isFocused else { return .subject }
        return focusIDs.contains(edge.sourceID) || focusIDs.contains(edge.targetID) ? .subject : .faded
    }

    /// Tables joined to `id` by a relation that changed — what hover should point at,
    /// instead of every neighbour the table has.
    func changedNeighbors(of id: String) -> Set<String> {
        changedNeighborsByTable[id] ?? []
    }

    /// The tables whose names belong on the canvas, most important first.
    var labelOrder: [String] {
        isFocused ? rankedChangedTableIDs.filter(subjectTableIDs.contains) : rankedChangedTableIDs
    }

    private static func labelRank(_ kind: SchemaChangeKind?) -> Int {
        switch kind {
        case .added, .removed: return 0
        case .modified: return 1
        case .unchanged, nil: return 2
        }
    }
}
