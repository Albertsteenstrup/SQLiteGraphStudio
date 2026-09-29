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
            Text(author.summary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help("Produced by \(author.summary)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Produced by \(author.summary)")
    }
}

/// Agent artwork supplied for the known tools; unknown tools keep a neutral glyph.
struct SchemaReviewAgentMark: View {
    let agent: SchemaReviewAgent?

    var body: some View {
        switch agent {
        case .claude:
            Image("AgentClaude", bundle: .module)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 20, height: 20)
        case .codex:
            Image("AgentCodex", bundle: .module)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 20, height: 20)
        case .opencode:
            GeometryReader { _ in
                Image("AgentOpenCode", bundle: .module)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 100, height: 56)
                    .offset(x: -12, y: -14)
            }
            .frame(width: 76, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        case .copilot:
            Image(systemName: "eyeglasses")
                .font(.system(size: 15, weight: .bold))
                .frame(width: 20, height: 20)
        case nil:
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
        }
    }
}
