import CoreGraphics
import Testing
@testable import StudioCore

struct GraphExplorationTests {
    @Test func savedCameraCannotRestoreAcrossRepackedCardModes() {
        let camera = GraphViewportTransform(zoom: 0.15, pan: CGSize(width: 900, height: -200))
        let saved = GraphViewportBookmark(transform: camera, presentation: .compact)
        #expect(saved.restored(for: .compact) == camera)
        #expect(saved.restored(for: .allCards) == nil)
    }

    @Test func marqueeUsesOnlyScopedDisplayedFrames() {
        let scope = ["visible": CGRect(x: 20, y: 20, width: 40, height: 40)]
        #expect(GraphExploration.selection(in: CGRect(x: 0, y: 0, width: 100, height: 100), frames: scope) == ["visible"])
        #expect(GraphExploration.selection(in: CGRect(x: 200, y: 200, width: 100, height: 100), frames: scope).isEmpty)
    }

    @Test func pagesKeepEveryTableReachableWithoutDuplicateNeighbours() {
        let ids = (0..<585).map { "public.table_\($0)" }
        let pages = (0..<13).flatMap { GraphExploration.page(ids + ids, index: $0).ids }
        #expect(pages.count == 585)
        #expect(Set(pages) == Set(ids))
        #expect(GraphExploration.page(ids, index: 99).index == 12)
        #expect(GraphExploration.page([], index: 1).ids.isEmpty)
    }

    @Test func lowZoomUsesMarksAndKeepsSelectedDetails() {
        let frames = Dictionary(uniqueKeysWithValues: (0..<2_000).map {
            (String($0), CGRect(x: $0 % 50 * 8, y: $0 / 50 * 8, width: 6, height: 6))
        })
        let plan = GraphExploration.renderPlan(frames: frames, viewport: CGRect(x: 0, y: 0, width: 500, height: 500), zoom: 0.08, isLarge: true, emphasized: ["42"])
        #expect(plan.detailIDs == ["42"])
        #expect(plan.markerIDs.count == 1_999)
        #expect(plan.interactiveIDs == Set(frames.keys))
    }

    @Test func boundedFocusScopeRetainsDetailedCardsAtOverviewZoom() {
        let frames = Dictionary(uniqueKeysWithValues: (0..<48).map {
            (String($0), CGRect(x: $0 % 8 * 50, y: $0 / 8 * 50, width: 40, height: 40))
        })
        let plan = GraphExploration.renderPlan(frames: frames, viewport: CGRect(x: 0, y: 0, width: 500, height: 500), zoom: 0.2, isLarge: true, emphasized: Set(frames.keys))
        #expect(plan.detailIDs == Set(frames.keys))
        #expect(plan.markerIDs.isEmpty)
        #expect(GraphExploration.markerFrame(for: CGRect(x: 10, y: 10, width: 1, height: 1)).size == CGSize(width: 3, height: 3))
    }

    @Test func detailedCardsAreCulledAndBudgetedWithoutLosingMarks() {
        var frames = Dictionary(uniqueKeysWithValues: (0..<1_000).map {
            (String($0), CGRect(x: $0 % 20 * 10, y: $0 / 20 * 10, width: 8, height: 8))
        })
        frames["outside"] = CGRect(x: 10_000, y: 10_000, width: 100, height: 100)
        let plan = GraphExploration.renderPlan(frames: frames, viewport: CGRect(x: 0, y: 0, width: 500, height: 600), zoom: 1, isLarge: true, emphasized: [])
        #expect(plan.detailIDs.count <= GraphExploration.maximumDetailedCards)
        #expect(plan.interactiveIDs.count == 1_000)
        #expect(!plan.interactiveIDs.contains("outside"))
        #expect(plan.detailIDs.isDisjoint(with: plan.markerIDs))
    }

    @Test(arguments: [0.08, 1.0]) func selectingEveryTableStillBoundsDetailedViews(zoom: Double) {
        let frames = Dictionary(uniqueKeysWithValues: (0..<2_000).map {
            (String($0), CGRect(x: $0 % 50 * 8, y: $0 / 50 * 8, width: 6, height: 6))
        })
        let plan = GraphExploration.renderPlan(frames: frames, viewport: CGRect(x: 0, y: 0, width: 500, height: 500), zoom: zoom, isLarge: true, emphasized: Set(frames.keys), primary: ["1999"])
        #expect(plan.detailIDs.count == GraphExploration.maximumDetailedCards)
        #expect(plan.detailIDs.contains("1999"))
        #expect(plan.markerIDs.count == 2_000 - GraphExploration.maximumDetailedCards)
    }

    @Test func groupEdgesAggregateDeterministically() {
        let edges = [
            GraphEdge(id: "1", sourceID: "a", targetID: "b", sourceColumn: "id", targetColumn: "id"),
            GraphEdge(id: "2", sourceID: "c", targetID: "a", sourceColumn: "id", targetColumn: "id"),
            GraphEdge(id: "3", sourceID: "b", targetID: "c", sourceColumn: "id", targetColumn: "id")
        ]
        let links = GraphExploration.groupLinks(edges: edges, membership: ["a": "A", "b": "B", "c": "B"])
        #expect(links.count == 1)
        #expect(links.first?.count == 2)
        #expect(links.first?.sourceID == "A")
        #expect(links.first?.targetID == "B")
    }
}
