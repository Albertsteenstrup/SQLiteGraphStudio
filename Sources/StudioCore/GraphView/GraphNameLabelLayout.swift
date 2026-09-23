import AppKit
import CoreGraphics

/// Table names drawn at one readable screen size over tables too small to show their own.
///
/// Enlarging the node under the pointer cannot do this job. At the zoom a large catalog
/// needs, a table is a few points tall; growing it until its name is legible would cover
/// its neighbours and pull the hit target out from under the pointer, and it still names
/// only one table at a time. Labels instead keep the same size at every zoom, never take
/// pointer input, and give way to one another rather than stacking.
enum GraphNameLabelLayout {
    static let fontSize: CGFloat = 11
    static let height: CGFloat = 18
    static let horizontalPadding: CGFloat = 6
    static let symbolSpacing: CGFloat = 4
    static let maximumTitleWidth: CGFloat = 190
    /// Minimum clear space between two labels.
    static let gap: CGFloat = 2
    /// Names considered per frame. A full viewport holds a few hundred at most, so a
    /// migration touching thousands of tables never costs more than this to place.
    static let candidateLimit = 400

    struct Candidate: Equatable {
        let id: String
        /// On-screen bounds of the table being named.
        let anchor: CGRect
        let size: CGSize
        /// Placed even where it overlaps others: the table under the pointer or the one chosen.
        let isPinned: Bool
    }

    struct Placement: Equatable {
        let id: String
        let frame: CGRect
    }

    /// Candidates arrive most important first. Pinned ones claim space before the rest;
    /// any other label that would touch one already placed, or leave the viewport, is
    /// dropped rather than moved far from its table.
    static func place(_ candidates: [Candidate], in viewport: CGRect) -> [Placement] {
        var placed: [Placement] = []
        var occupied: [CGRect] = []
        let ordered = candidates.filter(\.isPinned) + candidates.filter { !$0.isPinned }
        var seen: Set<String> = []

        for candidate in ordered where seen.insert(candidate.id).inserted {
            guard candidate.size.width <= viewport.width, candidate.size.height <= viewport.height else { continue }
            let options = positions(for: candidate, in: viewport)
            let frame = options.first { option in
                viewport.contains(option) && !occupied.contains { $0.insetBy(dx: -gap, dy: -gap).intersects(option) }
            } ?? (candidate.isPinned ? options.first.map { clamped($0, to: viewport) } : nil)
            guard let frame else { continue }
            placed.append(Placement(id: candidate.id, frame: frame))
            occupied.append(frame)
        }
        return placed
    }

    /// Over the table first, so the name reads as the table itself; then one label row
    /// above and one below. Rows are measured from the label, not the table: an overview
    /// table is shorter than its name, so offsets from its own edges would still overlap
    /// a neighbour's name sitting over the same row.
    private static func positions(for candidate: Candidate, in viewport: CGRect) -> [CGRect] {
        let size = candidate.size
        let x = min(max(candidate.anchor.midX - size.width / 2, viewport.minX), viewport.maxX - size.width)
        let centered = candidate.anchor.midY - size.height / 2
        let row = size.height + gap * 2
        return [centered, centered - row, centered + row].map {
            CGRect(x: x, y: $0, width: size.width, height: size.height)
        }
    }

    private static func clamped(_ frame: CGRect, to viewport: CGRect) -> CGRect {
        CGRect(x: min(max(frame.minX, viewport.minX), viewport.maxX - frame.width),
               y: min(max(frame.minY, viewport.minY), viewport.maxY - frame.height),
               width: frame.width, height: frame.height)
    }

    static var font: NSFont { .systemFont(ofSize: fontSize, weight: .semibold) }

    static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Shortens a name from the middle, where database names usually repeat themselves
    /// (`field_research_…_evidence`), keeping the prefix that names its group and the
    /// suffix that names the table.
    static func fittedTitle(_ title: String, maximumWidth: CGFloat = maximumTitleWidth,
                            measure: (String) -> CGFloat = textWidth) -> String {
        guard measure(title) > maximumWidth else { return title }
        let characters = Array(title)
        var low = 0, high = characters.count
        var best = "…"
        while low <= high {
            let kept = (low + high) / 2
            let head = kept - kept / 2
            let candidate = String(characters.prefix(head)) + "…" + String(characters.suffix(kept / 2))
            if measure(candidate) <= maximumWidth {
                best = candidate
                low = kept + 1
            } else {
                high = kept - 1
            }
        }
        return best
    }
}

/// Measured label text, so panning never re-measures a name.
final class GraphNameLabelCache {
    struct Entry {
        let title: String
        let symbol: String
        let symbolWidth: CGFloat
        let size: CGSize
    }

    private var entries: [String: Entry] = [:]

    func entry(title: String, symbol: String) -> Entry {
        let key = symbol + "\u{0}" + title
        if let entry = entries[key] { return entry }
        let fitted = GraphNameLabelLayout.fittedTitle(title)
        let symbolWidth = symbol.isEmpty ? 0 : GraphNameLabelLayout.textWidth(symbol)
        let width = GraphNameLabelLayout.horizontalPadding * 2 + GraphNameLabelLayout.textWidth(fitted)
            + (symbol.isEmpty ? 0 : symbolWidth + GraphNameLabelLayout.symbolSpacing)
        let entry = Entry(title: fitted, symbol: symbol, symbolWidth: symbolWidth,
                          size: CGSize(width: width, height: GraphNameLabelLayout.height))
        if entries.count > 4_096 { entries.removeAll(keepingCapacity: true) }
        entries[key] = entry
        return entry
    }
}
