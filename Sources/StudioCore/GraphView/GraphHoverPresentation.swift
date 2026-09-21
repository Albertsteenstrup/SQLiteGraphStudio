import CoreGraphics
import Foundation
import SwiftUI

/// Hover changes screen geometry only; it never feeds back into the saved layout.
enum GraphHoverPresentation {
    static let detailScale: CGFloat = 1.025

    static func cardScale(hovered: Bool, connected: Bool) -> CGFloat {
        hovered ? detailScale : (connected ? 1.015 : 1)
    }

    static func enlarged(_ frame: CGRect, scale: CGFloat, padding: CGFloat = 0) -> CGRect {
        frame.insetBy(dx: -(frame.width * (scale - 1) / 2 + padding),
                      dy: -(frame.height * (scale - 1) / 2 + padding))
    }

    static func markerFrame(_ frame: CGRect, hovered: Bool, connected: Bool) -> CGRect {
        let base = GraphExploration.markerFrame(for: frame)
        if hovered { return enlarged(base, scale: 1.14, padding: 2) }
        if connected { return enlarged(base, scale: 1.08, padding: 1) }
        return base
    }

    struct Label: Identifiable, Equatable {
        let id: String
        let frame: CGRect
        let anchor: CGPoint
        let isPrimary: Bool
    }

    struct Preview {
        var labels: [Label] = []
        var additionalTableCount = 0
    }

    /// Pack readable annotations near their nodes. Annotations are not pointer
    /// targets: moving between the actual nodes must not chase moving popovers.
    static func preview(hoveredID: String?, neighborIDs: Set<String>, frames: [String: CGRect],
                        viewport: CGRect, excluding reservedAreas: [CGRect] = []) -> Preview {
        guard let hoveredID, let hoveredFrame = frames[hoveredID],
              viewport.intersects(hoveredFrame), viewport.width >= 180, viewport.height >= 120 else { return Preview() }
        let bounds = viewport.insetBy(dx: 10, dy: 10)
        let width = min(284, bounds.width)
        let height: CGFloat = 78
        let pointerExclusion = hoveredFrame.insetBy(dx: -4, dy: -4)
        let neighbors = neighborIDs.subtracting([hoveredID]).filter { frames[$0] != nil }
        let ordered = neighbors.sorted { a, b in
            let af = frames[a]!, bf = frames[b]!
            let ad = hypot(af.midX - hoveredFrame.midX, af.midY - hoveredFrame.midY)
            let bd = hypot(bf.midX - hoveredFrame.midX, bf.midY - hoveredFrame.midY)
            return ad == bd ? a < b : ad < bd
        }
        var result = Preview()
        var occupied: [CGRect] = []
        // Dense hubs stay bounded; the primary label reports any remaining tables.
        for id in [hoveredID] + Array(ordered.prefix(GraphExploration.pageSize)) {
            guard let anchorFrame = frames[id], viewport.intersects(anchorFrame) else { continue }
            let anchor = CGPoint(x: anchorFrame.midX, y: anchorFrame.midY)
            // Nearby positions first; a viewport grid is a bounded fallback for dense schemas.
            var candidates = [
                CGPoint(x: anchor.x - width / 2, y: anchorFrame.minY - height - 10),
                CGPoint(x: anchor.x - width / 2, y: anchorFrame.maxY + 10),
                CGPoint(x: anchorFrame.maxX + 10, y: anchor.y - height / 2),
                CGPoint(x: anchorFrame.minX - width - 10, y: anchor.y - height / 2)
            ]
            for y in stride(from: bounds.minY, through: bounds.maxY - height, by: height + 8) {
                for x in stride(from: bounds.minX, through: bounds.maxX - width, by: width + 8) {
                    candidates.append(CGPoint(x: x, y: y))
                }
            }
            let available = candidates.map { origin in
                CGRect(x: min(max(origin.x, bounds.minX), bounds.maxX - width),
                       y: min(max(origin.y, bounds.minY), bounds.maxY - height), width: width, height: height)
            }.filter { candidate in
                !candidate.intersects(pointerExclusion)
                    && !reservedAreas.contains { $0.intersects(candidate) }
                    && !occupied.contains { $0.insetBy(dx: -4, dy: -4).intersects(candidate) }
            }
            guard let frame = available.min(by: { a, b in
                hypot(a.midX - anchor.x, a.midY - anchor.y) < hypot(b.midX - anchor.x, b.midY - anchor.y)
            }) else { continue }
            result.labels.append(Label(id: id, frame: frame, anchor: anchor, isPrimary: id == hoveredID))
            occupied.append(frame)
        }
        result.additionalTableCount = neighbors.count - result.labels.filter { !$0.isPrimary }.count
        return result
    }
}

struct GraphHoverLabel: View {
    let title: String
    let fieldCount: Int
    let rowCount: Int?
    let relationCount: Int
    let isPrimary: Bool
    let additionalTableCount: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.replacingOccurrences(of: "_", with: "_\u{200B}"))
                .accessibilityLabel(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Text("\(fieldCount.formatted()) fields")
                Text(rowCount.map { "\($0.formatted()) " + ($0 == 1 ? "row" : "rows") } ?? "Rows unknown")
            }
            .font(.system(size: 11))
            .lineLimit(1)
            .foregroundStyle(StudioPalette.secondaryText)
            if isPrimary {
                Text("\(relationCount.formatted()) " + (relationCount == 1 ? "relation" : "relations") + (additionalTableCount > 0 ? " · \(additionalTableCount) more " + (additionalTableCount == 1 ? "table" : "tables") : ""))
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(StudioPalette.secondaryText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(color.opacity(isPrimary ? 0.95 : 0.55), lineWidth: isPrimary ? 2 : 1) }
        .accessibilityElement(children: .combine)
    }
}
