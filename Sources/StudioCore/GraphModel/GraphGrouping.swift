import Foundation

/// Shared, local grouping for layout and navigation. Inferred groups are a view of the
/// current graph; resolving them never changes the authored sidecar or the database.
public struct GraphGrouping: Sendable, Hashable {
    public struct Group: Identifiable, Sendable, Hashable {
        public let id: String
        public let label: String
        public let colorHex: String
        public let nodeIDs: [String]
        public let isInferred: Bool
    }

    /// Authored groups retain sidecar order; inferred groups follow in stable order.
    /// Every member array is sorted, and each current graph node belongs to one group.
    public let groups: [Group]
    public let nodeToGroup: [String: String]
    public let authoredGroupCount: Int
    public let authoredNodeCount: Int

    private let groupIndexByID: [String: Int]

    /// Authored groups may exceed this size; the layout can subdivide them internally
    /// while preserving their shared name and colour.
    public static let maximumInferredGroupSize = 48
    public static let empty = GraphGrouping(groups: [])

    public var groupCount: Int { groups.count }
    public var nodeCount: Int { nodeToGroup.count }
    public var inferredGroupCount: Int { groupCount - authoredGroupCount }
    public var inferredNodeCount: Int { nodeCount - authoredNodeCount }

    public func group(id: String) -> Group? {
        guard let index = groupIndexByID[id] else { return nil }
        return groups[index]
    }

    public func group(for nodeID: String) -> Group? {
        guard let id = nodeToGroup[nodeID] else { return nil }
        return group(id: id)
    }

    private init(groups: [Group]) {
        self.groups = groups
        groupIndexByID = Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($0.element.id, $0.offset) })
        nodeToGroup = Dictionary(uniqueKeysWithValues: groups.flatMap { group in
            group.nodeIDs.map { ($0, group.id) }
        })
        authoredGroupCount = groups.reduce(0) { $0 + ($1.isInferred ? 0 : 1) }
        authoredNodeCount = groups.reduce(0) { $0 + ($1.isInferred ? 0 : $1.nodeIDs.count) }
    }

    /// Explicit memberships win in sidecar order. Repeated cluster IDs merge using the
    /// first hint's metadata; repeated table memberships belong to the first hint that
    /// names them. Stale table IDs and empty resolved groups are ignored.
    ///
    /// Unhinted tables are separated by structured namespace, then repeated literal
    /// name prefixes, then bounded breadth-first neighborhoods. Qualified identifiers
    /// are never split or matched by their potentially ambiguous base name.
    public static func resolve(
        graph: SchemaGraph,
        descriptors: [String: EditableTableDescriptor] = [:],
        sidecar: SchemaSidecar = .empty
    ) -> GraphGrouping {
        let nodeIDs = Set(graph.nodes.map(\.id)).sorted()
        guard !nodeIDs.isEmpty else { return .empty }
        let validIDs = Set(nodeIDs)

        var firstHintByID: [String: SchemaSidecar.ClusterHint] = [:]
        var authoredOrder: [String] = []
        var authoredMembers: [String: [String]] = [:]
        var assignedIDs: Set<String> = []

        for hint in sidecar.clusters {
            if firstHintByID[hint.id] == nil {
                firstHintByID[hint.id] = hint
                authoredOrder.append(hint.id)
            }
            for nodeID in hint.tables where validIDs.contains(nodeID) {
                guard assignedIDs.insert(nodeID).inserted else { continue }
                authoredMembers[hint.id, default: []].append(nodeID)
            }
        }

        var groups: [Group] = authoredOrder.compactMap { id in
            guard let hint = firstHintByID[id],
                  let members = authoredMembers[id],
                  !members.isEmpty
            else { return nil }
            let label: String
            if let authoredLabel = hint.label,
               !authoredLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                label = authoredLabel
            } else {
                label = id.isEmpty ? "Group" : id
            }
            return Group(
                id: id,
                label: label,
                colorHex: normalizedColor(hint.color) ?? fallbackColor(for: id),
                nodeIDs: members.sorted(),
                isInferred: false
            )
        }

        let unhintedIDs = nodeIDs.filter { !assignedIDs.contains($0) }
        guard !unhintedIDs.isEmpty else { return GraphGrouping(groups: groups) }

        // Sort each adjacency list once. Duplicate edges, edge direction and input
        // order cannot affect traversal, and stale references never become members.
        let unhintedSet = Set(unhintedIDs)
        let adjacency = Dictionary(uniqueKeysWithValues: unhintedIDs.map { nodeID in
            (nodeID, graph.neighbors(of: nodeID).filter {
                $0 != nodeID && unhintedSet.contains($0)
            }.sorted())
        })
        var usedGroupIDs = Set(firstHintByID.keys)

        func appendInferred(_ members: [String], namespace: String, prefix: String? = nil, isNamespace: Bool = false) {
            guard !members.isEmpty else { return }
            let partitions = boundedNeighborhoods(members, adjacency: adjacency)
            let memberSet = Set(members)
            let hasRelations = members.contains { nodeID in
                adjacency[nodeID, default: []].contains { memberSet.contains($0) }
            }
            let kind: String
            let baseLabel: String
            if isNamespace {
                kind = "schema"
                baseLabel = namespace
            } else if let prefix {
                kind = "prefix"
                baseLabel = namespace.isEmpty ? "\(prefix)*" : "\(namespace) · \(prefix)*"
            } else {
                kind = "neighborhood"
                let label = hasRelations ? "Neighborhood" : "Tables"
                baseLabel = namespace.isEmpty ? label : "\(namespace) · \(label)"
            }

            for (index, partition) in partitions.enumerated() {
                let label = partitions.count == 1 ? baseLabel : "\(baseLabel) · \(index + 1)"
                // Length-prefixed components distinguish namespaces/identifiers that
                // themselves contain punctuation used in these generated IDs.
                let baseID = "inferred:\(kind):\(idComponent(namespace)):\(idComponent(prefix ?? "")):\(idComponent(partition[0]))"
                var id = baseID
                var suffix = 2
                while !usedGroupIDs.insert(id).inserted {
                    id = "\(baseID):\(suffix)"
                    suffix += 1
                }
                groups.append(Group(
                    id: id,
                    label: label,
                    colorHex: fallbackColor(for: id),
                    nodeIDs: partition,
                    isInferred: true
                ))
            }
        }

        // An empty namespace key represents absent structured metadata. Never infer a
        // namespace by splitting a node ID: both backends permit dots in object names.
        let nodesByNamespace = Dictionary(grouping: unhintedIDs) { descriptors[$0]?.schemaName ?? "" }
        for namespace in nodesByNamespace.keys.sorted() {
            let namespaceMembers = nodesByNamespace[namespace, default: []]
            if !namespace.isEmpty && namespaceMembers.count <= maximumInferredGroupSize {
                appendInferred(namespaceMembers, namespace: namespace, isNamespace: true)
                continue
            }

            var nodesByPrefix: [String: [String]] = [:]
            for nodeID in namespaceMembers {
                let name = descriptors[nodeID]?.objectName ?? nodeID
                guard let prefix = namePrefix(name) else { continue }
                nodesByPrefix[prefix, default: []].append(nodeID)
            }

            var prefixedIDs: Set<String> = []
            for prefix in nodesByPrefix.keys.sorted() {
                let prefixMembers = nodesByPrefix[prefix, default: []]
                // Two names can coincide accidentally; three repeated literal
                // prefixes are a useful signal without guessing business domains.
                guard prefixMembers.count >= 3 else { continue }
                appendInferred(prefixMembers, namespace: namespace, prefix: prefix)
                prefixedIDs.formUnion(prefixMembers)
            }

            appendInferred(
                namespaceMembers.filter { !prefixedIDs.contains($0) },
                namespace: namespace
            )
        }
        return GraphGrouping(groups: groups)
    }

    /// Refill a bounded BFS from the next sorted seed when a component is exhausted.
    /// This keeps related nodes together while avoiding one group per isolated table.
    /// Each node/adjacency list is visited at most once across the inferred partitions.
    private static func boundedNeighborhoods(_ nodeIDs: [String], adjacency: [String: [String]]) -> [[String]] {
        let sortedIDs = nodeIDs.sorted()
        var remaining = Set(sortedIDs)
        var seedIndex = 0
        var partitions: [[String]] = []

        while !remaining.isEmpty {
            var members: [String] = []
            var queue: [String] = []
            var queueIndex = 0

            while members.count < maximumInferredGroupSize {
                if queueIndex == queue.count {
                    while seedIndex < sortedIDs.count && !remaining.contains(sortedIDs[seedIndex]) {
                        seedIndex += 1
                    }
                    guard seedIndex < sortedIDs.count else { break }
                    let seed = sortedIDs[seedIndex]
                    remaining.remove(seed)
                    members.append(seed)
                    queue.append(seed)
                }

                let current = queue[queueIndex]
                queueIndex += 1
                for neighbor in adjacency[current, default: []] {
                    guard members.count < maximumInferredGroupSize else { break }
                    guard remaining.remove(neighbor) != nil else { continue }
                    members.append(neighbor)
                    queue.append(neighbor)
                }
            }
            partitions.append(members.sorted())
        }
        return partitions
    }

    /// A literal snake/kebab-case prefix, including its separator. No unverified
    /// domain labels or schema assumptions are derived from table names.
    private static func namePrefix(_ name: String) -> String? {
        guard let separator = name.firstIndex(where: { $0 == "_" || $0 == "-" }),
              name.index(after: separator) < name.endIndex
        else { return nil }
        let token = name[..<separator]
        guard token.count >= 2,
              token.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }),
              token.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) })
        else { return nil }
        return String(name[...separator])
    }

    private static func idComponent(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }

    private static func normalizedColor(_ color: String?) -> String? {
        guard var value = color?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.utf8.count == 6,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else { return nil }
        return "#\(value.uppercased())"
    }

    private static func fallbackColor(for id: String) -> String {
        let palette = [
            "#64B5F6", "#81C784", "#FFB74D", "#BA68C8", "#4DD0E1", "#F06292",
            "#AED581", "#7986CB", "#FFD54F", "#4DB6AC", "#A1887F", "#90A4AE",
        ]
        // Swift's Hasher is deliberately randomized between processes. FNV-1a keeps
        // a group's fallback colour stable across reloads and input order changes.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}
