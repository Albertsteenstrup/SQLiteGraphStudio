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
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(coordinator.activePresentationTitle ?? "Live explanation")
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    if spokenPoint {
                        Image(systemName: "waveform")
                            .accessibilityLabel("Audio narration")
                    }
                    Text(statusText(presentation.status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if spokenPoint && presentation.hasVisibleCurrentPoint && !presentation.status.isFailed {
                        Button(showsTranscript ? "Hide text" : "Show text") {
                            expandedTranscriptForID = showsTranscript ? nil : presentationID
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }
                }
                if presentation.needsViewReplay {
                    explanationText("View changed. Continue to replay this point.")
                } else if let failure = failureMessage(presentation.status) {
                    explanationText(failure)
                } else if !presentation.hasVisibleCurrentPoint {
                    explanationText("Updating the view…")
                } else if showsTranscript {
                    explanationText(point.caption)
                }
                if showsTranscript && !presentation.displayedHistory.isEmpty {
                    DisclosureGroup("Earlier points") {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(presentation.displayedHistory) { earlier in
                                    Text(earlier.caption)
                                        .font(.caption)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(maxHeight: 160)
                    }
                    .font(.caption)
                }
                HStack(spacing: 8) {
                    Button("Back") { coordinator.userControlPresentation("back") }
                        .disabled(!presentation.canGoBack)
                    Button(presentation.status.isPaused ? "Continue" : "Pause") {
                        coordinator.userControlPresentation(presentation.status.isPaused ? "continue" : "pause")
                    }
                    .disabled(presentation.status.isCompleted)
                    Button("Next") { coordinator.userControlPresentation("next") }
                        .disabled(!presentation.canGoForward)
                    if presentation.status.isFailed {
                        Button("Retry") { coordinator.userControlPresentation("repeat") }
                    }
                    Spacer()
                    Menu("More") {
                        if !presentation.status.isFailed {
                            Button("Repeat this point") { coordinator.userControlPresentation("repeat") }
                        }
                        Button("Return to previous view") { coordinator.userControlPresentation("return") }
                    }
                    Button("End") { coordinator.userControlPresentation("end") }
                }
                .controlSize(.small)
            }
            .padding(16)
            .frame(maxWidth: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 8)
            .task(id: point.id) {
                // Yield once so SwiftUI can install the controls before the
                // graph's render acknowledgement permits this point to speak.
                await Task.yield()
                coordinator.captionRendered(pointID: point.id)
            }
        }
    }

    private func explanationText(_ value: String) -> some View {
        Text(value)
            .font(.body)
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
}
