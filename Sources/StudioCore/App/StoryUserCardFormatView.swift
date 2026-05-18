import SwiftUI

struct StoryUserCardFormatView: View {
    let actor: String?
    let goal: String?
    let benefit: String?
    let fallbackText: String?
    let conversation: [String]
    let acceptanceCriteria: [String]

    private var trimmedActor: String? { cleaned(actor) }
    private var trimmedGoal: String? { cleaned(goal) }
    private var trimmedBenefit: String? { cleaned(benefit) }
    private var trimmedFallback: String? { cleaned(fallbackText) }
    private var visibleConversation: [String] { conversation.compactMap { cleaned($0) } }
    private var visibleAcceptanceCriteria: [String] { acceptanceCriteria.compactMap { cleaned($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if trimmedActor != nil || trimmedGoal != nil || trimmedBenefit != nil {
                VStack(alignment: .leading, spacing: 7) {
                    storyPart("As", value: trimmedActor)
                    storyPart("I want", value: trimmedGoal)
                    storyPart("So that", value: trimmedBenefit)
                }
            } else if let trimmedFallback {
                Text(trimmedFallback)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(StudioPalette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !visibleConversation.isEmpty {
                detailSection("Conversation", items: visibleConversation)
            }

            if !visibleAcceptanceCriteria.isEmpty {
                detailSection("Acceptance", items: visibleAcceptanceCriteria)
            }
        }
    }

    private func storyPart(_ label: String, value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(StudioPalette.tertiaryText)
                .frame(width: 48, alignment: .leading)

            Text(value ?? "Not specified")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(value == nil ? StudioPalette.tertiaryText : StudioPalette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detailSection(_ title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(StudioPalette.tertiaryText)

            ForEach(Array(items.prefix(4).enumerated()), id: \.offset) { _, item in
                Text(item)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(StudioPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
