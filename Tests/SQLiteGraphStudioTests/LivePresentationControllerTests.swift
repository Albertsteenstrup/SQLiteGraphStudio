import Foundation
import Testing
@testable import StudioCore

struct LivePresentationControllerTests {
    @Test @MainActor
    func narrationAndMinimumHoldMustBothFinishAfterRendererAcknowledgesVisibility() async throws {
        let first = LivePresentationController.Point(
            caption: "First",
            narration: "Narrate the first point.",
            minimumVisibleTime: .milliseconds(20)
        )
        let second = LivePresentationController.Point(caption: "Second")
        let gate = PresentationNarrationGate()
        let controller = LivePresentationController(narrationPlayback: { text, status in
            await gate.play(text, status: status)
        })

        controller.append([first, second])
        controller.finishInput()
        #expect(controller.status == .preparing(pointID: first.id))
        controller.markApplied(pointID: first.id)
        #expect(controller.status == .applied(pointID: first.id))
        #expect(!gate.hasStarted)

        controller.markVisible(pointID: UUID())
        #expect(controller.status == .applied(pointID: first.id))
        controller.markVisible(pointID: first.id)
        for _ in 0..<20 where !gate.hasStarted {
            await Task.yield()
        }
        #expect(gate.hasStarted)

        try await Task.sleep(for: .milliseconds(40))
        #expect(controller.status == .waitingForSpeech(pointID: first.id))
        gate.finish()
        for _ in 0..<20 where controller.currentPoint?.id == first.id {
            await Task.yield()
        }

        #expect(controller.currentPoint?.id == second.id)
        #expect(controller.status == .preparing(pointID: second.id))
    }

    @Test @MainActor
    func manualPointsSupportNextAndBackAndInterruptRejectsLateVisibility() {
        let first = LivePresentationController.Point(
            caption: "First",
            minimumVisibleTime: .zero,
            advancePolicy: .manual
        )
        let second = LivePresentationController.Point(
            caption: "Second",
            minimumVisibleTime: .zero,
            advancePolicy: .manual
        )
        let controller = LivePresentationController()
        controller.append([first, second])
        controller.finishInput()

        controller.markApplied(pointID: first.id)
        controller.markVisible(pointID: first.id)
        #expect(controller.status == .waitingForNext(pointID: first.id))
        controller.next()
        #expect(controller.currentPoint?.id == second.id)

        controller.markApplied(pointID: second.id)
        controller.markVisible(pointID: second.id)
        controller.back()
        #expect(controller.currentPoint?.id == first.id)
        #expect(controller.status == .preparing(pointID: first.id))

        controller.interrupt()
        controller.markVisible(pointID: first.id)
        #expect(controller.status == .interrupted)
    }

    @Test @MainActor
    func correctionReplacesCurrentAndPendingButKeepsDisplayedHistoryAndEndHidesCurrent() {
        let first = LivePresentationController.Point(
            caption: "First",
            minimumVisibleTime: .zero,
            advancePolicy: .manual
        )
        let second = LivePresentationController.Point(
            caption: "Second",
            minimumVisibleTime: .zero,
            advancePolicy: .manual
        )
        let replacement = LivePresentationController.Point(caption: "Corrected")
        let replacementNext = LivePresentationController.Point(caption: "Next")
        let controller = LivePresentationController()
        controller.append([first, second])
        controller.finishInput()

        controller.markApplied(pointID: first.id)
        controller.markVisible(pointID: first.id)
        controller.next()
        controller.markApplied(pointID: second.id)
        controller.markVisible(pointID: second.id)

        controller.replaceCurrentAndPending(with: [replacement, replacementNext])
        #expect(controller.currentPoint?.id == replacement.id)
        #expect(controller.pendingPoints.map(\.id) == [replacementNext.id])
        #expect(controller.displayedHistory.map(\.id) == [first.id])

        controller.end()
        #expect(controller.currentPoint == nil)
        #expect(controller.pendingPoints.isEmpty)
        #expect(controller.status == .interrupted)
    }

    @Test @MainActor
    func requestedNarrationWithoutProviderFailsInsteadOfAdvancingSilently() {
        let point = LivePresentationController.Point(
            caption: "Narrated point",
            narration: "This must be spoken.",
            minimumVisibleTime: .zero
        )
        let controller = LivePresentationController()
        controller.append(point)
        controller.markApplied(pointID: point.id)
        controller.markVisible(pointID: point.id)

        #expect(controller.status == .failed(
            pointID: point.id,
            message: "Narration was requested, but no local speech provider is available."
        ))
    }

    @Test @MainActor
    func manualGraphInteractionFinishesCurrentSpeechThenPausesBeforeNextView() async {
        let first = LivePresentationController.Point(caption: "First", narration: "First narration", minimumVisibleTime: .zero)
        let second = LivePresentationController.Point(caption: "Second", minimumVisibleTime: .zero)
        let gate = PresentationNarrationGate()
        let controller = LivePresentationController(narrationPlayback: { text, status in
            await gate.play(text, status: status)
        })
        controller.append([first, second])
        controller.markApplied(pointID: first.id)
        controller.markVisible(pointID: first.id)
        for _ in 0..<20 where !gate.hasStarted { await Task.yield() }
        #expect(gate.hasStarted)

        controller.pauseAfterCurrentPoint()
        #expect(controller.currentPoint?.id == first.id)
        #expect(controller.status != .paused(pointID: first.id))
        gate.finish()
        for _ in 0..<20 where controller.status != .paused(pointID: first.id) { await Task.yield() }
        #expect(controller.status == .paused(pointID: first.id))
        #expect(controller.pendingPoints.map(\.id) == [second.id])

        controller.resume()
        #expect(controller.currentPoint?.id == second.id)
        #expect(controller.status == .preparing(pointID: second.id))
    }
}

@MainActor
private final class PresentationNarrationGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var hasStarted = false

    func play(
        _ text: String,
        status: @escaping LivePresentationController.SpeechStatusHandler
    ) async -> Bool {
        hasStarted = true
        status(.speaking)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finish() {
        continuation?.resume(returning: true)
        continuation = nil
    }
}
