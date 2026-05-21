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
    func focusPlanHidesUnrelatedCards() {
        let plan = GraphFocusPlan(
            activeStoryIDs: ["hub"],
            relatedStoryIDs: ["related"],
            activeTableIDs: ["users"],
            relatedTableIDs: ["sessions"]
        )

        #expect(plan.tierForStory("hub") == .active)
        #expect(plan.tierForStory("related") == .related)
        #expect(plan.tierForStory("other") == .hidden)
        #expect(plan.tierForTable("users") == .active)
        #expect(plan.tierForTable("sessions") == .related)
        #expect(plan.tierForTable("orders") == .hidden)
    }

    @Test
    func storyStarFormationSeparatesStoriesAndTables() {
        let tableSize = CGSize(width: 140, height: 46)
        let (tablePositions, storyPositions) = StoryStarFormationLayout.graphPositions(
            hubCenter: CGPoint(x: 400, y: 300),
            relatedStoryIDs: ["follow-on"],
            tableIDs: ["users", "sessions"],
            tableSize: { _ in tableSize }
        )

        #expect(tablePositions.count == 2)
        #expect(storyPositions.count == 1)
        #expect(tablePositions.keys.contains("users"))
        #expect(tablePositions.keys.contains("sessions"))
        #expect(storyPositions.keys.contains("follow-on"))

        let hubFrame = CGRect(
            x: 400 - StoryGraphCardLayout.width / 2,
            y: 300 - StoryGraphCardLayout.height / 2,
            width: StoryGraphCardLayout.width,
            height: StoryGraphCardLayout.height
        )
        let ringItems: [(CGPoint, CGSize)] =
            tablePositions.values.map { ($0, tableSize) }
            + storyPositions.values.map {
                ($0, CGSize(width: StoryGraphCardLayout.width, height: StoryGraphCardLayout.height))
            }
        for (point, size) in ringItems {
            let frame = CGRect(
                x: point.x - size.width / 2,
                y: point.y - size.height / 2,
                width: size.width,
                height: size.height
            )
            #expect(!frame.intersects(hubFrame))
        }
    }
}
