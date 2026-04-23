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
