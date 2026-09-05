import Foundation
import Testing
@testable import StudioCore

@Suite
struct GraphGroupingTests {
    @Test
    func emptyGraphIgnoresStaleHints() {
        let result = GraphGrouping.resolve(
            graph: .empty,
            sidecar: SchemaSidecar(clusters: [.init(id: "old", tables: ["removed"])])
        )

        #expect(result == .empty)
        #expect(result.groupCount == 0)
        #expect(result.nodeCount == 0)
        #expect(result.group(id: "old") == nil)
        #expect(result.group(for: "removed") == nil)
    }

    @Test
    func authoredGroupsPreserveMetadataAndIgnoreStaleTables() throws {
        let result = GraphGrouping.resolve(
            graph: graph(["users", "sessions", "orders"]),
            sidecar: SchemaSidecar(clusters: [
                .init(id: "identity", label: "People and access", tables: ["sessions", "removed", "users", "users"], color: " #12aBcD "),
            ])
        )
        let authored = try #require(result.group(id: "identity"))

        #expect(authored.label == "People and access")
        #expect(authored.colorHex == "#12ABCD")
        #expect(authored.nodeIDs == ["sessions", "users"])
        #expect(!authored.isInferred)
        #expect(result.nodeToGroup["removed"] == nil)
        #expect(result.group(for: "users") == authored)
        #expect(result.authoredGroupCount == 1)
        #expect(result.authoredNodeCount == 2)
        #expect(result.inferredNodeCount == 1)
        #expect(result.groupCount == result.authoredGroupCount + result.inferredGroupCount)
        expectCoverage(result, nodeIDs: ["users", "sessions", "orders"])
    }

    @Test
    func duplicateClusterIDsMergeWithFirstMetadataAndFirstMembershipWins() throws {
        let result = GraphGrouping.resolve(
            graph: graph(["a", "b", "c", "d", "e"]),
            sidecar: SchemaSidecar(clusters: [
                .init(id: "first", label: "First label", tables: ["a", "b"], color: "AABBCC"),
                .init(id: "second", label: "Second label", tables: ["b", "c"], color: "112233"),
                .init(id: "first", label: "Later label", tables: ["c", "d"], color: "445566"),
                .init(id: "stale", tables: ["gone"]),
            ])
        )
        let first = try #require(result.group(id: "first"))
        let second = try #require(result.group(id: "second"))

        #expect(first.label == "First label")
        #expect(first.colorHex == "#AABBCC")
        #expect(first.nodeIDs == ["a", "b", "d"])
        #expect(second.nodeIDs == ["c"])
        #expect(result.groups.filter { !$0.isInferred }.map(\.id) == ["first", "second"])
        #expect(result.group(id: "stale") == nil)
        expectCoverage(result, nodeIDs: ["a", "b", "c", "d", "e"])
    }

    @Test
    func invalidAndMissingColorsHaveStableVisibleFallbacks() throws {
        let sidecar = SchemaSidecar(clusters: [
            .init(id: "bad", tables: ["a"], color: "#GGHHII"),
            .init(id: "missing", tables: ["b"]),
            .init(id: "short", tables: ["c"], color: "#abc"),
            .init(id: "punctuation", tables: ["d"], color: "1#23456"),
        ])
        let before = GraphGrouping.resolve(graph: graph(["a", "b", "c", "d", "e"]), sidecar: sidecar)
        let after = GraphGrouping.resolve(graph: graph(["e", "d", "c", "b", "a"]), sidecar: sidecar)

        #expect(before == after)
        for group in before.groups {
            #expect(isValidColor(group.colorHex))
        }
        let differentColor = GraphGrouping.resolve(
            graph: graph(["a"]),
            sidecar: SchemaSidecar(clusters: [.init(id: "bad", tables: ["a"], color: "also invalid")])
        )
        #expect(before.group(id: "bad")?.colorHex == differentColor.group(id: "bad")?.colorHex)
    }

    @Test
    func blankAuthoredLabelFallsBackToID() {
        let result = GraphGrouping.resolve(
            graph: graph(["a"]),
            sidecar: SchemaSidecar(clusters: [.init(id: "catalog", label: " \n ", tables: ["a"])])
        )

        #expect(result.group(id: "catalog")?.label == "catalog")
    }

    @Test
    func anOversizedAuthoredGroupRemainsOneGroup() throws {
        let ids = numberedIDs(count: 1_000)
        let result = GraphGrouping.resolve(
            graph: graph(ids),
            sidecar: SchemaSidecar(clusters: [.init(id: "chosen-lens", tables: ids, color: "#336699")])
        )

        #expect(result.groupCount == 1)
        #expect(result.inferredGroupCount == 0)
        #expect(try #require(result.group(id: "chosen-lens")).nodeIDs.count == 1_000)
        expectCoverage(result, nodeIDs: ids)
    }

    @Test(arguments: [585, 1_000, 2_000])
    func largeIsolatedSchemasHaveBoundedCompleteGroups(count: Int) {
        let ids = numberedIDs(count: count)
        let result = GraphGrouping.resolve(graph: graph(ids))

        expectCoverage(result, nodeIDs: ids)
        #expect(result.authoredGroupCount == 0)
        #expect(result.inferredNodeCount == count)
        #expect(result.groupCount == (count + GraphGrouping.maximumInferredGroupSize - 1) / GraphGrouping.maximumInferredGroupSize)
        #expect(result.groups.allSatisfy { $0.isInferred && $0.nodeIDs.count <= GraphGrouping.maximumInferredGroupSize })
        #expect(result.groups.allSatisfy { !$0.label.isEmpty && isValidColor($0.colorHex) })
    }

    @Test(arguments: [585, 1_000, 2_000])
    func hugeConnectedSchemasAreBoundedAndInputOrderIndependent(count: Int) {
        let ids = numberedIDs(count: count)
        let edges = ids.dropFirst().enumerated().map { index, id in
            edge(ids[index], id)
        } + ids.dropFirst().map { edge(ids[0], $0) }
        let original = GraphGrouping.resolve(graph: graph(ids, edges: edges))
        let reversed = GraphGrouping.resolve(graph: graph(Array(ids.reversed()), edges: Array(edges.reversed())))

        #expect(original == reversed)
        expectCoverage(original, nodeIDs: ids)
        #expect(original.groups.allSatisfy { $0.nodeIDs.count <= GraphGrouping.maximumInferredGroupSize })
        #expect(original.groupCount == (count + GraphGrouping.maximumInferredGroupSize - 1) / GraphGrouping.maximumInferredGroupSize)
    }

    @Test
    func topologyKeepsSmallConnectedNeighborhoodsTogether() {
        let ids = (0..<4).flatMap { lane in (0..<16).map { "n\($0 * 4 + lane)" } }
        let edges = (0..<4).flatMap { lane in
            (1..<16).map { index in edge("n\((index - 1) * 4 + lane)", "n\(index * 4 + lane)") }
        }
        let result = GraphGrouping.resolve(graph: graph(ids, edges: edges))

        #expect(result.groupCount == 2)
        for lane in 0..<4 {
            let groupIDs = Set((0..<16).compactMap { result.nodeToGroup["n\($0 * 4 + lane)"] })
            #expect(groupIDs.count == 1)
        }
    }

    @Test
    func credibleNamePrefixesFormFactualGroups() throws {
        let ids = ["auth_users", "auth_sessions", "auth_tokens", "billing_accounts", "billing_invoices", "billing_items"]
        let result = GraphGrouping.resolve(graph: graph(ids))
        let auth = try #require(result.group(for: "auth_users"))
        let billing = try #require(result.group(for: "billing_accounts"))

        #expect(auth.id != billing.id)
        #expect(auth.nodeIDs == ["auth_sessions", "auth_tokens", "auth_users"])
        #expect(billing.nodeIDs == ["billing_accounts", "billing_invoices", "billing_items"])
        #expect(auth.label.contains("auth"))
        #expect(billing.label.contains("billing"))
        #expect(auth.isInferred && billing.isInferred)
    }

    @Test
    func oversizedNamePrefixStillUsesBoundedNeighborhoods() {
        let ids = (0..<585).map { "record_item_\($0)" }
        let result = GraphGrouping.resolve(graph: graph(ids))

        expectCoverage(result, nodeIDs: ids)
        #expect(result.groups.allSatisfy { $0.nodeIDs.count <= GraphGrouping.maximumInferredGroupSize })
        #expect(result.groups.allSatisfy { $0.label.contains("record") })
    }

    @Test
    func namespacesSeparateRepeatedPostgresObjectNamesAndUseDescriptorNames() throws {
        let names = ["users", "sessions", "tokens"]
        let schemas = ["auth", "archive"]
        let descriptors = Dictionary(uniqueKeysWithValues: schemas.flatMap { schema in
            names.map { name in
                let id = "\(schema).\(name)"
                return (id, descriptor(id: id, schema: schema, object: name))
            }
        })
        let ids = descriptors.keys.sorted()
        let result = GraphGrouping.resolve(
            graph: graph(ids, edges: [edge("auth.users", "archive.users")]),
            descriptors: descriptors
        )
        let auth = try #require(result.group(for: "auth.users"))
        let archive = try #require(result.group(for: "archive.users"))

        #expect(auth.id != archive.id)
        #expect(auth.nodeIDs == ["auth.sessions", "auth.tokens", "auth.users"])
        #expect(archive.nodeIDs == ["archive.sessions", "archive.tokens", "archive.users"])
        #expect(auth.label.contains("auth"))
        #expect(archive.label.contains("archive"))
        expectCoverage(result, nodeIDs: ids)
    }

    @Test
    func namespaceNamesWithDotsAndQuotesRemainDistinct() {
        let descriptors = [
            "first-id": descriptor(id: "first-id", schema: "one.two", object: "shared_name"),
            "second-id": descriptor(id: "second-id", schema: "one", object: "two.shared_name"),
            "third-id": descriptor(id: "third-id", schema: "a\"b", object: "shared_name"),
        ]
        let result = GraphGrouping.resolve(graph: graph(descriptors.keys.sorted()), descriptors: descriptors)

        #expect(Set(result.nodeToGroup.values).count == 3)
        #expect(result.group(for: "first-id")?.label.contains("one.two") == true)
        #expect(result.group(for: "third-id")?.label.contains("a\"b") == true)
    }

    @Test
    func unqualifiedHintsCannotClaimAmbiguousPostgresTables() {
        let descriptors = [
            "auth.users": descriptor(id: "auth.users", schema: "auth", object: "users"),
            "archive.users": descriptor(id: "archive.users", schema: "archive", object: "users"),
        ]
        let result = GraphGrouping.resolve(
            graph: graph(descriptors.keys.sorted()),
            descriptors: descriptors,
            sidecar: SchemaSidecar(clusters: [.init(id: "ambiguous", tables: ["users"])])
        )

        #expect(result.authoredGroupCount == 0)
        #expect(result.group(id: "ambiguous") == nil)
        expectCoverage(result, nodeIDs: descriptors.keys.sorted())
    }

    @Test
    func denseRelationsRemainBoundedAndDeterministic() {
        let ids = numberedIDs(count: 585)
        let edges = ids.indices.flatMap { index in
            (1...24).map { offset in edge(ids[index], ids[(index + offset) % ids.count]) }
        }
        let result = GraphGrouping.resolve(graph: graph(ids, edges: edges))
        let reverse = GraphGrouping.resolve(graph: graph(Array(ids.reversed()), edges: Array(edges.reversed())))

        #expect(result == reverse)
        expectCoverage(result, nodeIDs: ids)
        #expect(result.groups.allSatisfy { $0.nodeIDs.count <= GraphGrouping.maximumInferredGroupSize })
    }

    @Test
    func partialAuthoredCoverageLeavesNamespacesAndEveryOtherTableAvailable() {
        let ids = numberedIDs(count: 585)
        let authoredIDs = Array(ids.prefix(17))
        let descriptors = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, descriptor(id: id, schema: index.isMultiple(of: 2) ? "public" : "archive", object: id))
        })
        let result = GraphGrouping.resolve(
            graph: graph(ids),
            descriptors: descriptors,
            sidecar: SchemaSidecar(clusters: [.init(id: "authored", tables: authoredIDs)])
        )

        #expect(result.authoredNodeCount == 17)
        #expect(result.inferredNodeCount == 568)
        #expect(result.group(id: "authored")?.nodeIDs == authoredIDs)
        expectCoverage(result, nodeIDs: ids)
        for group in result.groups where group.isInferred {
            #expect(group.nodeIDs.count <= GraphGrouping.maximumInferredGroupSize)
            #expect(Set(group.nodeIDs.compactMap { descriptors[$0]?.schemaName }).count == 1)
        }
    }

    @Test
    func duplicateNodesEdgesAndDanglingReferencesDoNotAlterGrouping() {
        let ids = numberedIDs(count: 100)
        let edges = ids.dropFirst().enumerated().map { index, id in edge(ids[index], id) }
        let original = GraphGrouping.resolve(graph: graph(ids, edges: edges))
        let duplicated = GraphGrouping.resolve(
            graph: graph(ids + Array(ids.reversed()), edges: edges + edges + [edge("missing", ids[0]), edge(ids[0], ids[0])])
        )

        #expect(original == duplicated)
        expectCoverage(duplicated, nodeIDs: ids)
    }

    @Test
    func inferredIDsCannotCollideWithAuthoredIDs() throws {
        let ids = numberedIDs(count: 100)
        let initiallyInferred = GraphGrouping.resolve(graph: graph(ids))
        let collidingID = try #require(initiallyInferred.groups.first?.id)
        let result = GraphGrouping.resolve(
            graph: graph(ids + ["chosen"]),
            sidecar: SchemaSidecar(clusters: [.init(id: collidingID, label: "Chosen", tables: ["chosen"])])
        )

        #expect(result.group(id: collidingID)?.nodeIDs == ["chosen"])
        #expect(result.group(id: collidingID)?.isInferred == false)
        #expect(Set(result.groups.map(\.id)).count == result.groups.count)
        expectCoverage(result, nodeIDs: ids + ["chosen"])
    }

    private func expectCoverage(_ grouping: GraphGrouping, nodeIDs: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        let flattened = grouping.groups.flatMap(\.nodeIDs)
        #expect(Set(flattened) == Set(nodeIDs), sourceLocation: sourceLocation)
        #expect(flattened.count == Set(nodeIDs).count, sourceLocation: sourceLocation)
        #expect(grouping.nodeCount == Set(nodeIDs).count, sourceLocation: sourceLocation)
        #expect(Set(grouping.nodeToGroup.keys) == Set(nodeIDs), sourceLocation: sourceLocation)
        #expect(grouping.groups.allSatisfy { !$0.nodeIDs.isEmpty && $0.nodeIDs == $0.nodeIDs.sorted() }, sourceLocation: sourceLocation)
        for group in grouping.groups {
            #expect(group.nodeIDs.allSatisfy { grouping.nodeToGroup[$0] == group.id }, sourceLocation: sourceLocation)
        }
    }

    private func graph(_ ids: [String], edges: [GraphEdge] = []) -> SchemaGraph {
        SchemaGraph(nodes: ids.map { GraphNode(id: $0, title: $0, isEditable: false) }, edges: edges)
    }

    private func edge(_ source: String, _ target: String) -> GraphEdge {
        GraphEdge(id: "\(source)->\(target)", sourceID: source, targetID: target, sourceColumn: "parent_id", targetColumn: "id")
    }

    private func numberedIDs(count: Int) -> [String] {
        (0..<count).map { String(format: "n%04d", $0) }
    }

    private func descriptor(id: String, schema: String?, object: String) -> EditableTableDescriptor {
        EditableTableDescriptor(
            name: id,
            objectType: .table,
            columns: [],
            primaryKeyColumns: [],
            rowIdentityStrategy: .readOnly,
            isWithoutRowID: false,
            isEditable: false,
            schemaName: schema,
            objectName: object
        )
    }

    private func isValidColor(_ color: String) -> Bool {
        color.count == 7 && color.first == "#" && UInt32(color.dropFirst(), radix: 16) != nil
    }
}
