import CoreGraphics
import Testing
@testable import StudioCore

@Suite
struct GraphFocusHierarchyTests {
    @Test
    func ringLayoutSeparatesMultipleItems() {
        let positions = GraphFocusRingLayout.graphPositions(
            hubCenter: .zero,
            hubSize: CGSize(width: 190, height: 78),
            items: [
                .init(id: "a", size: CGSize(width: 140, height: 46)),
                .init(id: "b", size: CGSize(width: 140, height: 46)),
                .init(id: "c", size: CGSize(width: 140, height: 46)),
            ],
            gap: 84,
            interItemGap: 32
        )

        #expect(positions.count == 3)

        let ids = ["a", "b", "c"]
        for i in 0..<ids.count {
            for j in (i + 1)..<ids.count {
                let lhs = positions[ids[i]]!
                let rhs = positions[ids[j]]!
                let dx = abs(lhs.x - rhs.x)
                let dy = abs(lhs.y - rhs.y)
                #expect(dx > 80 || dy > 40)
            }
        }
    }

    @Test
    func denseFocusUsesReadableColumnsWithoutCoveringTheExpandedTable() {
        let hubSize = CGSize(width: 440, height: 236)
        let items = (0..<8).map { index in
            GraphFocusRingLayout.Item(id: "neighbor_\(index)",
                                      size: CGSize(width: 440, height: index.isMultiple(of: 3) ? 80 : 46))
        }
        let positions = GraphFocusRingLayout.graphPositions(
            hubCenter: .zero, hubSize: hubSize, items: items
        )
        let hub = CGRect(x: -hubSize.width / 2, y: -hubSize.height / 2,
                         width: hubSize.width, height: hubSize.height)
        let frames = items.map { item in
            let point = positions[item.id]!
            return CGRect(x: point.x - item.size.width / 2, y: point.y - item.size.height / 2,
                          width: item.size.width, height: item.size.height)
        }
        #expect(frames.allSatisfy { !$0.intersects(hub) })
        for first in frames.indices {
            for second in frames.indices where second > first {
                #expect(!frames[first].intersects(frames[second]))
            }
        }
        let bounds = frames.reduce(hub) { $0.union($1) }
        let camera = GraphViewportTransform.fit(
            contentBounds: bounds, in: CGSize(width: 1167, height: 520),
            padding: 128, minZoom: 0.5, maxZoom: 1.3
        )
        #expect(camera.zoom >= 0.5)
        #expect(hubSize.width * GraphReadableCardScale.focusedScale(for: camera.zoom) >= 396)
        let left = frames[0]
        let expandedHubLeft = -hubSize.width * GraphReadableCardScale.focusedScale(for: camera.zoom) / 2
        let visibleLeftEdge = left.maxX * camera.zoom
        #expect(expandedHubLeft - visibleLeftEdge >= 50)
    }

    @Test
    func focusedHubHighlightsOneHoveredNeighbourInsteadOfEveryRelation() {
        #expect(GraphFocusEdgeEmphasis.highlightedTableID(
            focusedHubID: "registry_workflow", hoveredTableID: nil,
            selectedTableID: "registry_workflow", fallbackID: "registry_workflow"
        ) == nil)
        #expect(GraphFocusEdgeEmphasis.highlightedTableID(
            focusedHubID: "registry_workflow", hoveredTableID: "registry_workflow",
            selectedTableID: "registry_workflow", fallbackID: "registry_workflow"
        ) == nil)
        #expect(GraphFocusEdgeEmphasis.highlightedTableID(
            focusedHubID: "registry_workflow", hoveredTableID: "job_progress_event",
            selectedTableID: "registry_workflow", fallbackID: "registry_workflow"
        ) == "job_progress_event")
        #expect(GraphFocusEdgeEmphasis.highlightedTableID(
            focusedHubID: "registry_workflow", hoveredTableID: nil,
            selectedTableID: "app_user", fallbackID: "registry_workflow"
        ) == "app_user")
        #expect(GraphFocusEdgeEmphasis.highlightedTableID(
            focusedHubID: nil, hoveredTableID: nil, selectedTableID: nil, fallbackID: "registry_workflow"
        ) == "registry_workflow")
        #expect(GraphFocusEdgeEmphasis.showsEdge(
            sourceID: "job_progress_event", targetID: "registry_workflow", focusedHubID: "registry_workflow"
        ))
        #expect(!GraphFocusEdgeEmphasis.showsEdge(
            sourceID: "registry_workflow_agent_trigger", targetID: "registry_workflow_agent_turn",
            focusedHubID: "registry_workflow"
        ))
        #expect(GraphFocusEdgeEmphasis.showsEdge(
            sourceID: "registry_workflow_agent_trigger", targetID: "registry_workflow_agent_turn",
            focusedHubID: nil
        ))
    }

    @Test
    func focusPlanHidesUnrelatedTables() {
        let plan = GraphFocusPlan(
            activeTableIDs: ["users"],
            relatedTableIDs: ["sessions"]
        )

        #expect(plan.tierForTable("users") == .active)
        #expect(plan.tierForTable("sessions") == .related)
        #expect(plan.tierForTable("orders") == .hidden)
    }
}
