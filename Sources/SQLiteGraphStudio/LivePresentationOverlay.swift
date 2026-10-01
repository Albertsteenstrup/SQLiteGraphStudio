import Foundation
import StudioCore
import SwiftUI

/// Controls belong to the presentation rather than the graph so the user can
/// interrupt an agent's explanation even while another pane has focus.
@MainActor
struct LivePresentationOverlay: View {
    let coordinator: StudioAutomationCoordinator
    @State private var expandedTranscriptForID: String?

    var body: some View {
        if let presentation = coordinator.activePresentation,
           let point = presentation.currentPoint {
            let spokenPoint = point.narration?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let presentationID = coordinator.activePresentationID
            let showsTranscript = !spokenPoint || (presentationID != nil && expandedTranscriptForID == presentationID)
            let isPaused = presentation.status.isPaused
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    if spokenPoint {
                        Image(systemName: "waveform")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .symbolEffect(.variableColor.iterative, isActive: presentation.status.isSpeaking)
                            .accessibilityLabel("Audio narration")
                    }
                    Text(coordinator.activePresentationTitle ?? "Live explanation")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Text(statusText(presentation.status))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if presentation.needsViewReplay {
                    explanationText("View changed. Continue to replay this point.")
                } else if let failure = failureMessage(presentation.status) {
                    explanationText(failure)
                } else if !presentation.hasVisibleCurrentPoint {
                    explanationText("Updating the view…", secondary: true)
                } else if showsTranscript {
                    explanationText(point.caption)
                }
                if showsTranscript && !presentation.displayedHistory.isEmpty {
                    DisclosureGroup("Earlier points") {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(presentation.displayedHistory) { earlier in
                                    Text(earlier.caption)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.top, 6)
                        }
                        .frame(maxHeight: 160)
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Button { coordinator.userControlPresentation("back") } label: {
                        Image(systemName: "backward.end.fill")
                    }
                    .disabled(!presentation.canGoBack)
                    .help("Previous point")
                    .accessibilityLabel("Back")

                    Button {
                        coordinator.userControlPresentation(isPaused ? "continue" : "pause")
                    } label: {
                        Image(systemName: isPaused ? "play.fill" : "pause.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.studioIconPrimary)
                    .controlSize(.large)
                    .disabled(presentation.status.isCompleted)
                    .help(isPaused ? "Continue" : "Pause")
                    .accessibilityLabel(isPaused ? "Continue" : "Pause")

                    Button { coordinator.userControlPresentation("next") } label: {
                        Image(systemName: "forward.end.fill")
                    }
                    .disabled(!presentation.canGoForward)
                    .help("Next point")
                    .accessibilityLabel("Next")

                    if presentation.status.isFailed {
                        Button("Retry") { coordinator.userControlPresentation("repeat") }
                            .buttonStyle(.studio)
                            .controlSize(.small)
                            .padding(.leading, 6)
                    }

                    Spacer()

                    if spokenPoint && presentation.hasVisibleCurrentPoint && !presentation.status.isFailed {
                        Button {
                            expandedTranscriptForID = showsTranscript ? nil : presentationID
                        } label: {
                            Image(systemName: showsTranscript ? "captions.bubble.fill" : "captions.bubble")
                        }
                        .help(showsTranscript ? "Hide text" : "Show text")
                        .accessibilityLabel(showsTranscript ? "Hide text" : "Show text")
                    }

                    StudioMenu(.quiet, iconOnly: true) {
                        if !presentation.status.isFailed {
                            Button("Repeat this point") { coordinator.userControlPresentation("repeat") }
                        }
                        Button("Return to previous view") { coordinator.userControlPresentation("return") }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .help("More")

                    Button { coordinator.userControlPresentation("end") } label: {
                        Image(systemName: "xmark")
                    }
                    .help("End explanation")
                    .accessibilityLabel("End")
                }
                .buttonStyle(.studioIcon)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .frame(maxWidth: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.12), radius: 24, y: 10)
            .task(id: point.id) {
                // Yield once so SwiftUI can install the controls before the
                // graph's render acknowledgement permits this point to speak.
                await Task.yield()
                coordinator.captionRendered(pointID: point.id)
            }
        }
    }

    private func explanationText(_ value: String, secondary: Bool = false) -> some View {
        Text(value)
            .font(.system(size: 13.5))
            .foregroundStyle(secondary ? .secondary : .primary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func failureMessage(_ status: LivePresentationController.Status) -> String? {
        if case .failed(_, let message) = status { return message }
        return nil
    }

    private func statusText(_ status: LivePresentationController.Status) -> String {
        switch status {
        case .preparing, .applied: "Updating view"
        case .generatingAudio: "Preparing voice"
        case .speaking: "Speaking"
        case .paused: "Paused"
        case .waitingForNext: "Ready for next"
        case .waitingForPoints: "Waiting for agent"
        case .completed: "Finished"
        case .failed: "Could not continue"
        default: "Showing"
        }
    }
}

private extension LivePresentationController.Status {
    var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }

    var isSpeaking: Bool {
        if case .speaking = self { return true }
        return false
    }
}
