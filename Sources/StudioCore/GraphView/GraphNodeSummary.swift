import SwiftUI

/// One shared name/count row for detailed cards and the same nodes in overview.
struct GraphNodeSummary: View {
    let title: String
    let fieldCount: Int
    let rowCount: Int?
    var showsDetailRows = false
    var hasDescription = false
    var nameOpacity: Double = 1
    var metadataOpacity: Double = 1
    var schemaChange: SchemaTableChange? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: showsDetailRows ? 13 : 12, weight: .semibold))
                .foregroundStyle(StudioPalette.primaryText)
                .underline(hasDescription, color: StudioPalette.primaryText.opacity(0.4))
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(nameOpacity)

            Spacer(minLength: 0)

            if schemaChange == nil || schemaChange?.kind == .unchanged {
                countPill(fieldCount == 1 ? "1 field" : "\(fieldCount) fields", surfaceOpacity: 1)
            }
            if let schemaChange {
                SchemaChangeBadge(change: schemaChange)
            } else {
                countPill(rowCount.map { $0 == 1 ? "1 row" : "\(compactRowCount($0)) rows" } ?? "— rows",
                          surfaceOpacity: 0.74)
            }
        }
    }

    private func countPill(_ title: String, surfaceOpacity: Double) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .lineLimit(1).fixedSize()
            .foregroundStyle(StudioPalette.secondaryText)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(StudioPalette.headerSurface.opacity(surfaceOpacity), in: Capsule())
            .opacity(metadataOpacity)
    }

    private func compactRowCount(_ count: Int) -> String {
        switch count {
        case 0..<1_000:
            return "\(count)"
        case 1_000..<10_000:
            let k = Double(count) / 1_000
            return k.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(k))K" : String(format: "%.1fK", k)
        case 10_000..<1_000_000:
            return "\(count / 1_000)K"
        case 1_000_000..<10_000_000:
            let m = Double(count) / 1_000_000
            return m.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(m))M" : String(format: "%.1fM", m)
        case 10_000_000..<1_000_000_000:
            return "\(count / 1_000_000)M"
        case 1_000_000_000..<10_000_000_000:
            let b = Double(count) / 1_000_000_000
            return b.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(b))B" : String(format: "%.1fB", b)
        default:
            return "\(count / 1_000_000_000)B"
        }
    }
}
