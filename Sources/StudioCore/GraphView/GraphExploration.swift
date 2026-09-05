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
        return pageOrdered(ordered, index: index)
    }

    /// Group memberships are already unique and sorted by the grouping model.
    static func pageOrdered(_ ordered: [String], index: Int) -> Page {
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

    private struct RenderCandidate {
        let id: String
        let priority: Int
        let distanceSquared: CGFloat
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
        isLarge: Bool, emphasized: Set<String>, primary: Set<String> = [], retained: Set<String> = []
    ) -> RenderPlan {
        let paddedViewport = viewport.insetBy(dx: -80, dy: -80)
        let centerX = viewport.midX, centerY = viewport.midY
        let includesOrdinaryDetails = zoom >= detailZoom
        var visibleIDs: Set<String> = []
        var retainedIDs: Set<String> = []
        var candidates: [RenderCandidate] = []
        if isLarge { candidates.reserveCapacity(frames.count) }

        for (id, frame) in frames {
            let isVisible = frame.intersects(paddedViewport)
            let isRetained = retained.contains(id)
            guard isVisible || isRetained else { continue }
            if isVisible { visibleIDs.insert(id) }
            if isRetained { retainedIDs.insert(id) }
            guard isLarge else { continue }

            // Resolve membership once per candidate. Sorting uses scalar ranks and
            // distances instead of repeatedly hashing IDs into sets/dictionaries.
            let isPrimary = primary.contains(id)
            let priority: Int
            if isRetained {
                priority = isPrimary ? 0 : 1
            } else if isPrimary {
                priority = 2
            } else if emphasized.contains(id) {
                priority = 3
            } else {
                guard includesOrdinaryDetails else { continue }
                priority = 4
            }
            let dx = frame.midX - centerX, dy = frame.midY - centerY
            candidates.append(RenderCandidate(id: id, priority: priority, distanceSquared: dx * dx + dy * dy))
        }

        guard isLarge else { return RenderPlan(detailIDs: visibleIDs.union(retainedIDs), markerIDs: []) }
        candidates.sort { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.distanceSquared == rhs.distanceSquared
                ? lhs.id < rhs.id
                : lhs.distanceSquared < rhs.distanceSquared
        }
        let details = Set(candidates.prefix(maximumDetailedCards).map(\.id))
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
