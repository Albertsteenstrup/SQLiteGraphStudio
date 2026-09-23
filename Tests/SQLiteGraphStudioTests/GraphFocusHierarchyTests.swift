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
