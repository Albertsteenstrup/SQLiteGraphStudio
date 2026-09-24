import SwiftUI

/// Which agent and session produced a review: `[mark] Claude · Table diff visualization clarity`.
///
/// A reader with several reviews open — or one handed over from another tool — can tell at
/// a glance where each came from. It records provenance, not approval.
struct SchemaReviewAuthorLabel: View {
    let author: SchemaReviewDocument.Author

    var body: some View {
        HStack(spacing: 7) {
            SchemaReviewAgentMark(agent: author.agent)
                .frame(width: 18, height: 18)
            Text(author.summary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help("Produced by \(author.summary)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Produced by \(author.summary)")
    }
}

/// A small mark per known agent tool.
///
/// Marks are drawn in code rather than shipped as artwork: Claude's spark is simple enough
/// to draw recognisably, and the other tools get a plain monogram tile rather than an
/// imitation of their logo. An unknown tool gets a neutral glyph beside its own name.
struct SchemaReviewAgentMark: View {
    let agent: SchemaReviewAgent?

    var body: some View {
        switch agent {
        case .claude:
            ClaudeSparkShape()
                .stroke(Color(red: 0.851, green: 0.467, blue: 0.341),
                        style: StrokeStyle(lineWidth: 2.1, lineCap: .round))
                .padding(1)
        case .codex:
            tile(Color.black) { Text(">_").font(.system(size: 9, weight: .heavy, design: .monospaced)) }
        case .opencode:
            tile(Color(white: 0.2)) { Text("oc").font(.system(size: 9, weight: .heavy, design: .monospaced)) }
        case .copilot:
            tile(Color(red: 0.13, green: 0.14, blue: 0.17)) { Image(systemName: "eyeglasses").font(.system(size: 9, weight: .bold)) }
        case nil:
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func tile(_ color: Color, @ViewBuilder glyph: () -> some View) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(color)
            .overlay { glyph().foregroundStyle(.white) }
    }
}

/// Claude's spark: uneven rays radiating from one point.
struct ClaudeSparkShape: Shape {
    private static let rayLengths: [CGFloat] = [1, 0.74, 0.92, 0.68, 0.97, 0.78, 0.88, 0.7, 1, 0.76, 0.9, 0.72]

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        for (index, length) in Self.rayLengths.enumerated() {
            let angle = CGFloat(index) / CGFloat(Self.rayLengths.count) * 2 * .pi - .pi / 2 + 0.12
            let inner = radius * 0.16, outer = radius * length
            path.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
            path.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
        }
        return path
    }
}
