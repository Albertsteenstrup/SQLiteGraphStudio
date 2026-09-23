import Foundation

/// Trims a relation list to a per-frame budget.
///
/// Used wherever a catalog holds more relations than the canvas can usefully paint or
/// animate at once — the zoomed-out edge layer and the pulse layer both draw from this,
/// so the two agree on which relations exist for a frame.
enum GraphEdgeSampling {
    /// Keeps every essential item, then fills the remaining budget at an even stride
    /// through the rest.
    ///
    /// The stride matters: taking a prefix would crowd every survivor into whichever
    /// corner of the graph happens to come first in edge order, leaving the rest of the
    /// canvas bare. It is also stable for a given input order, so items do not flicker in
    /// and out between frames while the reader pans.
    static func evenSample<Item>(
        _ items: [Item],
        limit: Int,
        isEssential: (Item) -> Bool = { _ in false }
    ) -> [Item] {
        guard limit > 0 else { return [] }
        guard items.count > limit else { return items }

        var essential: [Item] = []
        var rest: [Item] = []
        for item in items {
            if isEssential(item) {
                essential.append(item)
            } else {
                rest.append(item)
            }
        }
        guard essential.count < limit else { return Array(essential.prefix(limit)) }

        let remaining = limit - essential.count
        guard rest.count > remaining else { return essential + rest }

        var sampled = essential
        sampled.reserveCapacity(limit)
        let step = Double(rest.count) / Double(remaining)
        for index in 0..<remaining {
            sampled.append(rest[min(rest.count - 1, Int(Double(index) * step))])
        }
        return sampled
    }
}
