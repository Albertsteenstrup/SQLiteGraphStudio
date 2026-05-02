import Foundation
import Testing
@testable import StudioCore

@MainActor
struct GraphLayoutTests {
    @Test
    func graphLayoutResetsDeterministically() {
        let graph = SchemaGraph(
            nodes: [
                GraphNode(id: "authors", title: "authors", isEditable: true),
                GraphNode(id: "posts", title: "posts", isEditable: true),
                GraphNode(id: "comments", title: "comments", isEditable: true),
            ],
            edges: [
                GraphEdge(id: "posts-authors", sourceID: "posts", targetID: "authors", sourceColumn: "author_id", targetColumn: "id"),
                GraphEdge(id: "comments-posts", sourceID: "comments", targetID: "posts", sourceColumn: "post_id", targetColumn: "id"),
            ]
        )

        let first = GraphLayoutModel()
        first.reset(for: graph)

        let second = GraphLayoutModel()
        second.reset(for: graph)

        #expect(first.position(for: "authors") == second.position(for: "authors"))
        #expect(first.position(for: "posts") == second.position(for: "posts"))
        #expect(first.position(for: "comments") == second.position(for: "comments"))
    }

    @Test
    func pinningNodeDoesNotRestartAnimationByDefault() {
        let graph = SchemaGraph(
            nodes: [
                GraphNode(id: "authors", title: "authors", isEditable: true),
                GraphNode(id: "posts", title: "posts", isEditable: true),
            ],
            edges: []
        )

        let layout = GraphLayoutModel()
        layout.reset(for: graph)
        layout.pin(nodeID: "authors", at: CGPoint(x: 120, y: 80))

        #expect(layout.position(for: "authors") == CGPoint(x: 120, y: 80))
        #expect(!layout.isAnimating)
    }

    @Test
    func allCardsStabilizationSeparatesLargeExpandedCards() {
        let leftDescriptor = makeDescriptor(name: "audit_entries", columnCount: 12)
        let rightDescriptor = makeDescriptor(name: "workspace_preferences", columnCount: 10)
        let graph = SchemaGraph(
            nodes: [
                GraphNode(id: leftDescriptor.name, title: leftDescriptor.name, isEditable: true),
                GraphNode(id: rightDescriptor.name, title: rightDescriptor.name, isEditable: true),
            ],
            edges: [
                GraphEdge(
                    id: "prefs-audit",
                    sourceID: rightDescriptor.name,
                    targetID: leftDescriptor.name,
                    sourceColumn: "column_2",
                    targetColumn: "column_1"
                ),
            ]
        )

        let descriptors = [leftDescriptor.name: leftDescriptor, rightDescriptor.name: rightDescriptor]
        let layout = GraphLayoutModel()
        layout.reset(for: graph, presentation: .allCards, descriptorLookup: { descriptors[$0] })
        layout.pin(nodeID: leftDescriptor.name, at: .zero)
        layout.pin(nodeID: rightDescriptor.name, at: CGPoint(x: 12, y: 18))
        layout.clearPinnedState()

        layout.stabilize(
            graph: graph,
            presentation: .allCards,
            descriptorLookup: { descriptors[$0] },
            nodeSizeLookup: {
                guard let descriptor = descriptors[$0] else {
                    return CGSize(width: GraphCardLayout.expandedWidth, height: GraphCardLayout.collapsedHeight)
                }
                return GraphCardLayout.nodeSize(title: descriptor.name, descriptor: descriptor, style: .expanded)
            },
            maxIterations: 420
        )

        let leftSize = GraphCardLayout.nodeSize(title: leftDescriptor.name, descriptor: leftDescriptor, style: .expanded)
        let rightSize = GraphCardLayout.nodeSize(title: rightDescriptor.name, descriptor: rightDescriptor, style: .expanded)
        let leftCenter = layout.position(for: leftDescriptor.name)
        let rightCenter = layout.position(for: rightDescriptor.name)
        let leftFrame = CGRect(
            x: leftCenter.x - leftSize.width / 2,
            y: leftCenter.y - leftSize.height / 2,
            width: leftSize.width,
            height: leftSize.height
        )
        let rightFrame = CGRect(
            x: rightCenter.x - rightSize.width / 2,
            y: rightCenter.y - rightSize.height / 2,
            width: rightSize.width,
            height: rightSize.height
        )

        #expect(!leftFrame.insetBy(dx: -24, dy: -24).intersects(rightFrame))
    }

    @Test
    func restoredSnapshotReusesSavedPositionsAndPins() {
        let graph = SchemaGraph(
            nodes: [
                GraphNode(id: "authors", title: "authors", isEditable: true),
                GraphNode(id: "posts", title: "posts", isEditable: true),
            ],
            edges: []
        )

        let original = GraphLayoutModel()
        original.reset(for: graph)
        original.pin(nodeID: "authors", at: CGPoint(x: 144, y: 92))
        original.pin(nodeID: "posts", at: CGPoint(x: -88, y: 44))
        let snapshot = original.snapshot(for: graph)

        let restored = GraphLayoutModel()
        restored.restore(snapshot, for: graph, presentation: .compact, descriptorLookup: nil)

        #expect(restored.position(for: "authors") == CGPoint(x: 144, y: 92))
        #expect(restored.position(for: "posts") == CGPoint(x: -88, y: 44))
        #expect(restored.hasRestoredSnapshot)
        #expect(!restored.isAnimating)
    }

    @Test
    func allCardsRelayoutStartsFromCompactPositionsWithoutKeepingPins() {
        let authors = makeDescriptor(name: "authors", columnCount: 8)
        let posts = makeDescriptor(name: "posts", columnCount: 9)
        let graph = SchemaGraph(
            nodes: [
                GraphNode(id: "authors", title: "authors", isEditable: true),
                GraphNode(id: "posts", title: "posts", isEditable: true),
            ],
            edges: [
                GraphEdge(id: "posts-authors", sourceID: "posts", targetID: "authors", sourceColumn: "column_2", targetColumn: "column_1"),
            ]
        )
        let descriptors = ["authors": authors, "posts": posts]

        let layout = GraphLayoutModel()
        layout.reset(for: graph, presentation: .compact, descriptorLookup: { descriptors[$0] })
        layout.pin(nodeID: "authors", at: CGPoint(x: -72, y: 20))
        layout.pin(nodeID: "posts", at: CGPoint(x: 88, y: 20))

        layout.relayoutPreservingCurrentPositions(
            for: graph,
            presentation: .allCards,
            descriptorLookup: { descriptors[$0] }
        )

        #expect(layout.position(for: "authors") == CGPoint(x: -72, y: 20))
        #expect(layout.position(for: "posts") == CGPoint(x: 88, y: 20))

        layout.stabilize(
            graph: graph,
            presentation: .allCards,
            descriptorLookup: { descriptors[$0] },
            nodeSizeLookup: {
                guard let descriptor = descriptors[$0] else { return .zero }
                return GraphCardLayout.nodeSize(title: descriptor.name, descriptor: descriptor, style: .expanded)
            },
            maxIterations: 420
        )

        let authorsSize = GraphCardLayout.nodeSize(title: "authors", descriptor: authors, style: .expanded)
        let postsSize = GraphCardLayout.nodeSize(title: "posts", descriptor: posts, style: .expanded)
        let authorsCenter = layout.position(for: "authors")
        let postsCenter = layout.position(for: "posts")
        let authorsFrame = CGRect(x: authorsCenter.x - authorsSize.width / 2, y: authorsCenter.y - authorsSize.height / 2, width: authorsSize.width, height: authorsSize.height)
        let postsFrame = CGRect(x: postsCenter.x - postsSize.width / 2, y: postsCenter.y - postsSize.height / 2, width: postsSize.width, height: postsSize.height)

        #expect(!authorsFrame.insetBy(dx: -24, dy: -24).intersects(postsFrame))
    }

    @Test
    func largeCompactLayoutsStayDenseAndBalanced() {
        let hubIDs = (0..<4).map { "hub_\($0)" }
        let leafIDs = (0..<60).map { "leaf_\($0)" }
        let isolatedIDs = (0..<48).map { "isolated_\($0)" }

        let nodes = (hubIDs + leafIDs + isolatedIDs).map {
            GraphNode(id: $0, title: $0, isEditable: true)
        }

        var edges: [GraphEdge] = []
        for (index, leafID) in leafIDs.enumerated() {
            let hubID = hubIDs[index % hubIDs.count]
            edges.append(GraphEdge(
                id: "\(leafID)-\(hubID)",
                sourceID: leafID,
                targetID: hubID,
                sourceColumn: "hub_id",
                targetColumn: "id"
            ))
        }
        for index in 0..<(hubIDs.count - 1) {
            edges.append(GraphEdge(
                id: "\(hubIDs[index])-\(hubIDs[index + 1])",
                sourceID: hubIDs[index],
                targetID: hubIDs[index + 1],
                sourceColumn: "parent_id",
                targetColumn: "id"
            ))
        }

        let graph = SchemaGraph(nodes: nodes, edges: edges)
        let layout = GraphLayoutModel()
        layout.reset(for: graph, presentation: .compact, descriptorLookup: nil)
        layout.stabilize(
            graph: graph,
            presentation: .compact,
            descriptorLookup: nil,
            nodeSizeLookup: nil,
            maxIterations: 260
        )

        let positions = layout.allPositions(for: graph)
        let xs = positions.values.map(\.x)
        let ys = positions.values.map(\.y)
        let width = Double((xs.max() ?? 0) - (xs.min() ?? 0))
        let height = Double((ys.max() ?? 0) - (ys.min() ?? 0))
        let longerAxis = max(width, height)
        let shorterAxis = max(min(width, height), 1)

        #expect(longerAxis / shorterAxis <= 1.55)
        #expect(width <= 1_900)
        #expect(height <= 1_700)
    }
}

private func makeDescriptor(name: String, columnCount: Int) -> EditableTableDescriptor {
    let columns = (0..<columnCount).map { index in
        TableColumn(
            name: "column_\(index + 1)",
            declaredType: index == 0 ? "INTEGER" : "TEXT",
            notNull: false,
            defaultValueSQL: nil,
            primaryKeyOrdinal: index == 0 ? 1 : 0,
            hiddenValue: 0
        )
    }

    return EditableTableDescriptor(
        name: name,
        objectType: .table,
        columns: columns,
        primaryKeyColumns: columns.filter { $0.primaryKeyOrdinal > 0 }.map(\.name),
        rowIdentityStrategy: .primaryKey,
        isWithoutRowID: false,
        isEditable: true
    )
}
