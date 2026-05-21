import Foundation
import Testing
@testable import StudioCore

@MainActor
struct StoryGraphPlacementTests {
    @Test
    func anchoredStoriesGroupNearClusterTableCentroid() async throws {
        let url = try TestSupport.createFixture(named: "story-cluster-placement")
        let sidecarJSON = """
        {
          "version": 1,
          "clusters": [
            {
              "id": "publishing",
              "label": "Publishing",
              "tables": ["authors", "posts"],
              "color": "#A8E6A3"
            }
          ],
          "stories": [
            {
              "id": "story-a",
              "title": "Story A",
              "created_at": "2026-05-18T12:00:00Z",
              "clusters": ["publishing"],
              "playback": [
                { "text": "Authors first.", "tables": ["authors"], "focus": "authors" }
              ]
            },
            {
              "id": "story-b",
              "title": "Story B",
              "created_at": "2026-05-18T12:01:00Z",
              "clusters": ["publishing"],
              "playback": [
                { "text": "Posts next.", "tables": ["posts"], "focus": "posts" }
              ]
            }
          ]
        }
        """
        try sidecarJSON.write(to: SchemaSidecarStore.sidecarURL(for: url), atomically: true, encoding: .utf8)

        let session = AppSession(databaseService: DatabaseService())
        await session.openDatabase(url: url)
        session.showStoryCardsInGraph = true
        session.showOnlyStoryCardsInGraph = false
        session.graphLayout.pin(nodeID: "authors", at: CGPoint(x: -120, y: 40))
        session.graphLayout.pin(nodeID: "posts", at: CGPoint(x: 120, y: 40))

        let placed = StoryGraphPlacement.placedCards(for: session)
        #expect(placed.count == 2)
        #expect(Set(placed.map(\.clusterKey)) == ["publishing"])

        let clusterCentroid = CGPoint(x: 0, y: 40)
        let positions = placed.map(\.graphPosition)
        let maxDistanceFromCentroid = positions.map { hypot($0.x - clusterCentroid.x, $0.y - clusterCentroid.y) }.max() ?? 0
        let spread = hypot(
            (positions.map(\.x).max() ?? 0) - (positions.map(\.x).min() ?? 0),
            (positions.map(\.y).max() ?? 0) - (positions.map(\.y).min() ?? 0)
        )

        #expect(maxDistanceFromCentroid > 150)
        #expect(maxDistanceFromCentroid < 520)
        #expect(spread < 260)

        let tableFrames = ["authors", "posts"].map { tableID in
            let center = session.graphLayout.position(for: tableID)
            let descriptor = session.descriptor(named: tableID)
            let size = GraphCardLayout.nodeSize(
                title: descriptor?.name ?? tableID,
                descriptor: descriptor,
                style: .collapsed
            )
            return CGRect(
                x: center.x - size.width / 2,
                y: center.y - size.height / 2,
                width: size.width,
                height: size.height
            )
        }

        for card in placed {
            let storyFrame = StoryGraphPlacement.cardFrame(at: card.graphPosition)
            for tableFrame in tableFrames {
                #expect(!storyFrame.intersects(tableFrame))
            }
        }
    }

    @Test
    func anchoredStoriesAvoidClusterTitleBand() async throws {
        let url = try TestSupport.createFixture(named: "story-title-clearance")
        let sidecarJSON = """
        {
          "version": 1,
          "clusters": [
            {
              "id": "publishing",
              "label": "Publishing",
              "tables": ["authors", "posts"],
              "color": "#A8E6A3"
            }
          ],
          "stories": [
            {
              "id": "story-a",
              "title": "Story A",
              "created_at": "2026-05-18T12:00:00Z",
              "clusters": ["publishing"],
              "playback": [
                { "text": "Authors first.", "tables": ["authors"], "focus": "authors" }
              ]
            }
          ]
        }
        """
        try sidecarJSON.write(to: SchemaSidecarStore.sidecarURL(for: url), atomically: true, encoding: .utf8)

        let session = AppSession(databaseService: DatabaseService())
        await session.openDatabase(url: url)
        session.showStoryCardsInGraph = true
        session.showOnlyStoryCardsInGraph = false
        session.graphLayout.pin(nodeID: "authors", at: CGPoint(x: -80, y: 20))
        session.graphLayout.pin(nodeID: "posts", at: CGPoint(x: 80, y: 20))

        let placed = try #require(StoryGraphPlacement.placedCards(for: session).first)
        let titleStyle = StoryGraphPlacement.clusterTitleStyle(for: session)
        let storyFrame = StoryGraphPlacement.cardFrame(at: placed.graphPosition)

        var clusterBounds = CGRect.null
        for tableID in ["authors", "posts"] {
            let center = session.graphLayout.position(for: tableID)
            let descriptor = session.descriptor(named: tableID)
            let size = GraphCardLayout.nodeSize(
                title: descriptor?.name ?? tableID,
                descriptor: descriptor,
                style: .collapsed
            )
            let frame = CGRect(
                x: center.x - size.width / 2 - titleStyle.padding,
                y: center.y - size.height / 2 - titleStyle.padding,
                width: size.width + titleStyle.padding * 2,
                height: size.height + titleStyle.padding * 2
            )
            clusterBounds = clusterBounds.isNull ? frame : clusterBounds.union(frame)
        }

        let titleBand = CGRect(
            x: clusterBounds.midX - clusterBounds.width / 2 - 28,
            y: clusterBounds.minY - (titleStyle.fontSize + 36),
            width: clusterBounds.width + 56,
            height: titleStyle.fontSize + 36
        )
        #expect(!storyFrame.intersects(titleBand))
    }

    @Test
    func placedStoriesRemainAfterRelayoutStyleReset() async throws {
        let url = try TestSupport.createFixture(named: "story-relayout-survival")
        let sidecarJSON = """
        {
          "version": 1,
          "clusters": [
            {
              "id": "publishing",
              "label": "Publishing",
              "tables": ["authors", "posts"],
              "color": "#A8E6A3"
            }
          ],
          "stories": [
            {
              "id": "story-a",
              "title": "Story A",
              "created_at": "2026-05-18T12:00:00Z",
              "clusters": ["publishing"],
              "playback": [
                { "text": "Authors first.", "tables": ["authors"], "focus": "authors" }
              ]
            },
            {
              "id": "story-b",
              "title": "Story B",
              "created_at": "2026-05-18T12:01:00Z",
              "clusters": ["publishing"],
              "playback": [
                { "text": "Posts next.", "tables": ["posts"], "focus": "posts" }
              ]
            }
          ]
        }
        """
        try sidecarJSON.write(to: SchemaSidecarStore.sidecarURL(for: url), atomically: true, encoding: .utf8)

        let session = AppSession(databaseService: DatabaseService())
        await session.openDatabase(url: url)
        session.showStoryCardsInGraph = true
        session.showOnlyStoryCardsInGraph = false

        let beforeRelayout = StoryGraphPlacement.placedCards(for: session)
        #expect(beforeRelayout.count == 2)

        session.clearPersistedStoryGraphLayout()
        session.graphLayout.clearPinnedState()
        session.graphLayout.relayout(
            for: session.graph,
            presentation: .compact,
            descriptorLookup: { session.descriptor(named: $0) }
        )
        session.graphLayout.stabilize(
            graph: session.graph,
            presentation: .compact,
            descriptorLookup: { session.descriptor(named: $0) },
            nodeSizeLookup: nil,
            maxIterations: 40
        )

        let afterRelayout = StoryGraphPlacement.placedCards(for: session)
        #expect(afterRelayout.count == 2)
        #expect(Set(afterRelayout.map(\.id)) == Set(beforeRelayout.map(\.id)))
    }
}
