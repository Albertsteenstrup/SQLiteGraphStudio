import CoreGraphics
import Foundation

/// A camera can be reused only while table geometry uses the same presentation.
struct GraphViewportBookmark: Equatable {
    let transform: GraphViewportTransform
    let presentation: GraphPresentationMode

    func restored(for mode: GraphPresentationMode) -> GraphViewportTransform? {
        mode == presentation ? transform : nil
    }
}

/// Backend-neutral limits shared by the navigator, renderer, and interaction targets.
enum GraphExploration {
    static let pageSize = 48
    static let maximumDetailedCards = 160
    static let detailZoom: CGFloat = 0.42

    struct Page: Equatable {
        let ids: [String]
        let index: Int
        let count: Int
        let total: Int
        var start: Int { total == 0 ? 0 : index * pageSize + 1 }
        var end: Int { min(total, (index + 1) * pageSize) }
    }

    static func page(_ ids: [String], index: Int) -> Page {
        let ordered = Set(ids).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let count = max(1, (ordered.count + pageSize - 1) / pageSize)
        let index = min(max(index, 0), count - 1)
        let start = index * pageSize
        return Page(ids: Array(ordered.dropFirst(start).prefix(pageSize)), index: index, count: count, total: ordered.count)
    }

    struct RenderPlan {
        let detailIDs: Set<String>
        let markerIDs: Set<String>
        var interactiveIDs: Set<String> { detailIDs.union(markerIDs) }
    }

    static func selection(in rectangle: CGRect, frames: [String: CGRect]) -> Set<String> {
        Set(frames.compactMap { id, frame in
            rectangle.contains(CGPoint(x: frame.midX, y: frame.midY)) ? id : nil
        })
    }

    static func markerFrame(for frame: CGRect) -> CGRect {
        CGRect(x: frame.midX - max(frame.width, 3) / 2,
               y: frame.midY - max(frame.height, 3) / 2,
               width: max(frame.width, 3), height: max(frame.height, 3))
    }

    static func renderPlan(
        frames: [String: CGRect], viewport: CGRect, zoom: CGFloat,
        isLarge: Bool, emphasized: Set<String>, primary: Set<String> = []
    ) -> RenderPlan {
        let visible = frames.filter { $0.value.intersects(viewport.insetBy(dx: -80, dy: -80)) }
        let visibleIDs = Set(visible.keys)
        guard isLarge else { return RenderPlan(detailIDs: visibleIDs, markerIDs: []) }
        let priorities = emphasized.intersection(visibleIDs).sorted { lhs, rhs in
            if primary.contains(lhs) != primary.contains(rhs) { return primary.contains(lhs) }
            let a = visible[lhs]!, b = visible[rhs]!
            let da = hypot(a.midX - viewport.midX, a.midY - viewport.midY)
            let db = hypot(b.midX - viewport.midX, b.midY - viewport.midY)
            return da == db ? lhs < rhs : da < db
        }
        let priorityIDs = Set(priorities.prefix(maximumDetailedCards))
        guard zoom >= detailZoom else {
            return RenderPlan(detailIDs: priorityIDs, markerIDs: visibleIDs.subtracting(priorityIDs))
        }
        let candidates = visible.keys.filter { !priorityIDs.contains($0) }.sorted { lhs, rhs in
            let a = visible[lhs]!, b = visible[rhs]!
            let da = hypot(a.midX - viewport.midX, a.midY - viewport.midY)
            let db = hypot(b.midX - viewport.midX, b.midY - viewport.midY)
            return da == db ? lhs < rhs : da < db
        }
        let details = priorityIDs.union(candidates.prefix(max(0, maximumDetailedCards - priorityIDs.count)))
        return RenderPlan(detailIDs: details, markerIDs: visibleIDs.subtracting(details))
    }

    struct GroupLink: Equatable {
        let sourceID: String
        let targetID: String
        let count: Int
    }

    private struct GroupPair: Hashable { let source: String; let target: String }

    static func groupLinks(edges: [GraphEdge], membership: [String: String]) -> [GroupLink] {
        var counts: [GroupPair: Int] = [:]
        for edge in edges {
            guard let source = membership[edge.sourceID], let target = membership[edge.targetID], source != target else { continue }
            counts[GroupPair(source: min(source, target), target: max(source, target)), default: 0] += 1
        }
        return counts.map { GroupLink(sourceID: $0.key.source, targetID: $0.key.target, count: $0.value) }
            .sorted { ($0.sourceID, $0.targetID) < ($1.sourceID, $1.targetID) }
    }
}
