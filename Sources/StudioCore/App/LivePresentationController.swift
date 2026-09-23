import Foundation
import Observation

@MainActor
@Observable
public final class LivePresentationController {
    public enum AdvancePolicy: Sendable, Equatable {
        case automatic
        case manual
    }

    public struct Point: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let caption: String
        public let narration: String?
        public let minimumVisibleTime: Duration
        public let additionalHold: Duration
        public let advancePolicy: AdvancePolicy

        public init(
            id: UUID = UUID(),
            caption: String,
            narration: String? = nil,
            minimumVisibleTime: Duration = .seconds(2),
            additionalHold: Duration = .zero,
            advancePolicy: AdvancePolicy = .automatic
        ) {
            self.id = id
            self.caption = caption
            self.narration = narration
            self.minimumVisibleTime = max(.zero, minimumVisibleTime)
            self.additionalHold = max(.zero, additionalHold)
            self.advancePolicy = advancePolicy
        }
    }

    public enum Status: Sendable, Equatable {
        case idle
        case preparing(pointID: UUID)
        case applied(pointID: UUID)
        case visible(pointID: UUID)
        case generatingAudio(pointID: UUID)
        case speaking(pointID: UUID)
        case waitingForSpeech(pointID: UUID)
        case waitingForHold(pointID: UUID)
        case waitingForNext(pointID: UUID)
        case waitingForPoints(pointID: UUID)
        case paused(pointID: UUID?)
        case completed
        case interrupted
        case failed(pointID: UUID, message: String)
    }

    public typealias SpeechStatusHandler = @MainActor @Sendable (SpeechPlaybackStatus) -> Void
    public typealias NarrationPlayback = @MainActor @Sendable (
        _ text: String,
        _ status: @escaping SpeechStatusHandler
    ) async -> Bool

    public private(set) var currentPoint: Point?
    public private(set) var status: Status = .idle
    public private(set) var pendingPoints: [Point] = []
    public private(set) var displayedHistory: [Point] = []

    @ObservationIgnored private let narrator: StudioSpeechNarrator?
    @ObservationIgnored private let narrationPlayback: NarrationPlayback?
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private var inputFinished = false
    @ObservationIgnored private var isPaused = false
    @ObservationIgnored private var pauseAtPointEnd = false
    @ObservationIgnored private var statusBeforePause: Status?
    @ObservationIgnored private var forwardHistory: [Point] = []
    @ObservationIgnored private var currentRunID = UUID()
    @ObservationIgnored private var hasApplied = false
    @ObservationIgnored private var hasBecomeVisible = false
    @ObservationIgnored private var didStartNarration = false
    @ObservationIgnored private var didFinishNarration = false
    @ObservationIgnored private var didFinishHold = false
    @ObservationIgnored private var remainingHold: Duration = .zero
    @ObservationIgnored private var holdStartedAt: ContinuousClock.Instant?
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    @ObservationIgnored private var narrationTask: Task<Void, Never>?

    public init(
        narrator: StudioSpeechNarrator? = nil,
        narrationPlayback: NarrationPlayback? = nil
    ) {
        self.narrator = narrator
        if let narrationPlayback {
            self.narrationPlayback = narrationPlayback
        } else if let narrator {
            self.narrationPlayback = { text, status in
                await narrator.playStreamed(text, status: status)
            }
        } else {
            self.narrationPlayback = nil
        }
    }

    public var canGoBack: Bool {
        !displayedHistory.isEmpty
    }

    public var canGoForward: Bool {
        !forwardHistory.isEmpty || !pendingPoints.isEmpty
    }

    /// Keep the next caption out of view while the graph is still moving into place.
    public var hasVisibleCurrentPoint: Bool { hasBecomeVisible }

    public func append(_ point: Point) {
        append([point])
    }

    public func append(_ points: [Point]) {
        guard !points.isEmpty else { return }
        inputFinished = false
        pendingPoints.append(contentsOf: points)

        if currentPoint == nil {
            activateNextPoint()
        } else if !isPaused, case .waitingForPoints = activeStatus {
            advanceToNextPoint()
        } else if !isPaused, case .completed = activeStatus {
            advanceToNextPoint()
        }
    }

    /// Replaces only points that have not been displayed. The current point and its visible state
    /// remain intact; old displayed history stays available for Back.
    public func replacePending(with points: [Point]) {
        pendingPoints = points
        inputFinished = false
        if currentPoint == nil {
            activateNextPoint()
        } else if !isPaused, case .waitingForPoints = activeStatus, !pendingPoints.isEmpty {
            advanceToNextPoint()
        } else if !isPaused, case .completed = activeStatus, !pendingPoints.isEmpty {
            advanceToNextPoint()
        } else if !isPaused, case .completed = activeStatus, let currentPoint {
            publish(.waitingForPoints(pointID: currentPoint.id))
        }
    }

    public func finishInput() {
        inputFinished = true
        if currentPoint == nil {
            if pendingPoints.isEmpty {
                publish(.completed)
            } else {
                activateNextPoint()
            }
            return
        }
        maybeAdvance(runID: currentRunID)
    }

    public func markApplied(pointID: UUID) {
        guard currentPoint?.id == pointID,
              acceptsRendererAcknowledgement,
              !hasApplied else { return }
        hasApplied = true
        publish(.applied(pointID: pointID))
    }

    /// Call only after the coordinator receives the renderer's visible acknowledgement.
    /// Narration and visible-time measurement both start at this point.
    public func markVisible(pointID: UUID) {
        guard currentPoint?.id == pointID,
              case .applied = activeStatus,
              hasApplied,
              !hasBecomeVisible else { return }
        hasBecomeVisible = true
        remainingHold = (currentPoint?.minimumVisibleTime ?? .zero)
            + (currentPoint?.additionalHold ?? .zero)
        didFinishHold = remainingHold <= .zero

        let narration = currentPoint?.narration?.trimmingCharacters(in: .whitespacesAndNewlines)
        didFinishNarration = narration?.isEmpty != false
        publish(.visible(pointID: pointID))
        startVisibleWork(runID: currentRunID)
    }

    /// A failed action or render keeps the last visible point in place until Retry, Skip, or End.
    public func markFailed(pointID: UUID, message: String) {
        guard currentPoint?.id == pointID else { return }
        cancelVisibleWork(stopNarrator: true)
        currentRunID = UUID()
        publish(.failed(pointID: pointID, message: message))
    }

    public func pause() {
        guard !isPaused, currentPoint != nil else { return }
        if case .completed = status { return }
        if case .interrupted = status { return }
        if case .failed = status { return }
        pauseAtPointEnd = false
        isPaused = true
        statusBeforePause = status
        pauseHoldTimer()
        narrator?.pause()
        status = .paused(pointID: currentPoint?.id)
    }

    public func resume() {
        guard isPaused else { return }
        pauseAtPointEnd = false
        isPaused = false
        status = statusBeforePause ?? currentPoint.map { .visible(pointID: $0.id) } ?? .idle
        statusBeforePause = nil
        narrator?.resume()
        if hasBecomeVisible {
            startVisibleWork(runID: currentRunID)
            maybeAdvance(runID: currentRunID)
        }
    }

    public func next() {
        pauseAtPointEnd = false
        isPaused = false
        statusBeforePause = nil
        guard currentPoint != nil else {
            activateNextPoint()
            return
        }
        advanceToNextPoint()
    }

    public func back() {
        guard let previous = displayedHistory.popLast() else { return }
        pauseAtPointEnd = false
        isPaused = false
        statusBeforePause = nil
        if let currentPoint {
            forwardHistory.insert(currentPoint, at: 0)
        }
        cancelVisibleWork(stopNarrator: true)
        currentPoint = previous
        resetActivationState()
        publish(.preparing(pointID: previous.id))
    }

    /// Stops current audio and clears undisplayed points while leaving the current view intact.
    public func interrupt() {
        cancelVisibleWork(stopNarrator: true)
        pauseAtPointEnd = false
        currentRunID = UUID()
        pendingPoints.removeAll()
        forwardHistory.removeAll()
        inputFinished = true
        isPaused = false
        statusBeforePause = nil
        publish(.interrupted)
    }

    /// Ends the presentation and removes its current point while preserving displayed history.
    public func end() {
        cancelVisibleWork(stopNarrator: true)
        pauseAtPointEnd = false
        currentRunID = UUID()
        pendingPoints.removeAll()
        forwardHistory.removeAll()
        inputFinished = true
        isPaused = false
        statusBeforePause = nil
        currentPoint = nil
        resetActivationState()
        publish(.interrupted)
    }

    /// Replaces the active and undisplayed sequence after a correction, retaining only points
    /// that were previously displayed in Back history.
    public func replaceCurrentAndPending(with points: [Point]) {
        cancelVisibleWork(stopNarrator: true)
        pauseAtPointEnd = false
        currentRunID = UUID()
        pendingPoints = points
        forwardHistory.removeAll()
        inputFinished = false
        isPaused = false
        statusBeforePause = nil
        currentPoint = nil
        resetActivationState()
        activateNextPoint()
    }

    /// Reissues actions for an unapplied point, or retries only its narration after it was visible.
    public func retryCurrent() {
        guard let currentPoint else { return }
        pauseAtPointEnd = false
        isPaused = false
        statusBeforePause = nil
        cancelVisibleWork(stopNarrator: true)
        currentRunID = UUID()

        if hasBecomeVisible {
            didFinishNarration = currentPoint.narration?.isEmpty != false
            didStartNarration = false
            didFinishHold = remainingHold <= .zero
            publish(.visible(pointID: currentPoint.id))
            startVisibleWork(runID: currentRunID)
        } else {
            hasApplied = false
            publish(.preparing(pointID: currentPoint.id))
        }
    }

    /// A direct graph gesture leaves the current short point audible and visible, but
    /// prevents the queued point from taking over the manually adjusted view.
    public func pauseAfterCurrentPoint() {
        guard currentPoint != nil, !isPaused else { return }
        if case .completed = status { return }
        if case .interrupted = status { return }
        if case .failed = status { return }
        guard hasBecomeVisible else {
            pause()
            return
        }
        pauseAtPointEnd = true
        maybeAdvance(runID: currentRunID)
    }

    private var activeStatus: Status {
        isPaused ? (statusBeforePause ?? status) : status
    }

    private var acceptsRendererAcknowledgement: Bool {
        switch activeStatus {
        case .preparing:
            true
        default:
            false
        }
    }

    private func activateNextPoint() {
        let point: Point?
        if !forwardHistory.isEmpty {
            point = forwardHistory.removeFirst()
        } else if !pendingPoints.isEmpty {
            point = pendingPoints.removeFirst()
        } else {
            point = nil
        }

        guard let point else {
            publish(inputFinished ? .completed : .idle)
            return
        }

        currentPoint = point
        currentRunID = UUID()
        resetActivationState()
        publish(.preparing(pointID: point.id))
    }

    private func advanceToNextPoint() {
        guard currentPoint != nil else {
            activateNextPoint()
            return
        }

        cancelVisibleWork(stopNarrator: true)
        pauseAtPointEnd = false
        if let currentPoint {
            displayedHistory.append(currentPoint)
        }
        currentPoint = nil
        resetActivationState()
        activateNextPoint()
    }

    private func resetActivationState() {
        hasApplied = false
        hasBecomeVisible = false
        didStartNarration = false
        didFinishNarration = false
        didFinishHold = false
        remainingHold = .zero
        holdStartedAt = nil
    }

    private func startVisibleWork(runID: UUID) {
        guard !isPaused, let point = currentPoint, currentRunID == runID, hasBecomeVisible else { return }
        startHoldTimer(runID: runID)
        startNarrationIfNeeded(point: point, runID: runID)
        maybeAdvance(runID: runID)
    }

    private func startHoldTimer(runID: UUID) {
        guard !isPaused, !didFinishHold, holdTask == nil, remainingHold > .zero else {
            if remainingHold <= .zero { didFinishHold = true }
            return
        }

        let duration = remainingHold
        holdStartedAt = clock.now
        holdTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(for: duration)
            } catch {
                return
            }
            guard self.currentRunID == runID else { return }
            self.holdTask = nil
            self.holdStartedAt = nil
            self.remainingHold = .zero
            self.didFinishHold = true
            self.updateWaitingStatus(runID: runID)
            self.maybeAdvance(runID: runID)
        }
    }

    private func startNarrationIfNeeded(point: Point, runID: UUID) {
        guard !isPaused,
              !didStartNarration,
              !didFinishNarration,
              let narration = point.narration?.trimmingCharacters(in: .whitespacesAndNewlines),
              !narration.isEmpty else {
            return
        }

        guard let narrationPlayback else {
            markFailed(
                pointID: point.id,
                message: "Narration was requested, but no local speech provider is available."
            )
            return
        }

        didStartNarration = true
        narrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let didFinish = await narrationPlayback(narration) { [weak self] speechStatus in
                guard let self, self.currentRunID == runID, self.currentPoint?.id == point.id else { return }
                switch speechStatus {
                case .preparing, .generating:
                    self.publish(.generatingAudio(pointID: point.id))
                case .speaking:
                    self.publish(.speaking(pointID: point.id))
                case .failed(let message):
                    self.markFailed(pointID: point.id, message: message)
                default:
                    break
                }
            }

            guard self.currentRunID == runID, self.currentPoint?.id == point.id else { return }
            guard didFinish else {
                self.markFailed(
                    pointID: point.id,
                    message: "Narration stopped before its audio buffers finished."
                )
                return
            }
            self.narrationTask = nil
            self.didFinishNarration = true
            self.updateWaitingStatus(runID: runID)
            self.maybeAdvance(runID: runID)
        }
    }

    private func pauseHoldTimer() {
        guard let holdTask else { return }
        if let holdStartedAt {
            let elapsed = holdStartedAt.duration(to: clock.now)
            remainingHold = elapsed >= remainingHold ? .zero : remainingHold - elapsed
            didFinishHold = remainingHold <= .zero
        }
        holdTask.cancel()
        self.holdTask = nil
        holdStartedAt = nil
    }

    private func updateWaitingStatus(runID: UUID) {
        guard currentRunID == runID, let currentPoint else { return }
        if didFinishNarration, !didFinishHold {
            publish(.waitingForHold(pointID: currentPoint.id))
        } else if didFinishHold, !didFinishNarration {
            publish(.waitingForSpeech(pointID: currentPoint.id))
        } else {
            publish(.visible(pointID: currentPoint.id))
        }
    }

    private func maybeAdvance(runID: UUID) {
        guard currentRunID == runID,
              !isPaused,
              let currentPoint,
              hasBecomeVisible,
              didFinishHold,
              didFinishNarration else {
            return
        }

        if pauseAtPointEnd {
            pause()
            return
        }

        if currentPoint.advancePolicy == .manual {
            publish(.waitingForNext(pointID: currentPoint.id))
        } else if !forwardHistory.isEmpty || !pendingPoints.isEmpty {
            advanceToNextPoint()
        } else if inputFinished {
            publish(.completed)
        } else {
            publish(.waitingForPoints(pointID: currentPoint.id))
        }
    }

    private func cancelVisibleWork(stopNarrator: Bool) {
        holdTask?.cancel()
        holdTask = nil
        holdStartedAt = nil
        narrationTask?.cancel()
        narrationTask = nil
        if stopNarrator {
            narrator?.stop()
        }
    }

    private func publish(_ newStatus: Status) {
        if isPaused {
            statusBeforePause = newStatus
            status = .paused(pointID: currentPoint?.id)
        } else {
            status = newStatus
        }
    }
}
