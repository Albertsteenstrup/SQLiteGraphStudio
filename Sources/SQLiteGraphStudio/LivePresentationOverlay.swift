import StudioCore
import SwiftUI

/// Controls belong to the presentation rather than the graph so the user can
/// interrupt an agent's explanation even while another pane has focus.
@MainActor
struct LivePresentationOverlay: View {
    let coordinator: StudioAutomationCoordinator

    var body: some View {
        if let presentation = coordinator.activePresentation,
           let point = presentation.currentPoint {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(coordinator.activePresentationTitle ?? "Live explanation")
                        .font(.headline)
                    Spacer(minLength: 12)
                    Text(statusText(presentation.status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(presentation.hasVisibleCurrentPoint ? point.caption : "Updating the view…")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !presentation.displayedHistory.isEmpty {
                    DisclosureGroup("Earlier points") {
                        ForEach(presentation.displayedHistory) { earlier in
                            Text(earlier.caption)
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
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
                // Yield once so SwiftUI can install the point controls before
                // the graph's own render acknowledgement permits the caption.
                await Task.yield()
                coordinator.captionRendered(pointID: point.id)
            }
        }
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
        case .failed(_, let message): "Could not continue: \(message)"
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
