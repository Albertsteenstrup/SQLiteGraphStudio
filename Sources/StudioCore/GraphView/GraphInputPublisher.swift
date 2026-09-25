import CoreGraphics
import Foundation

/// Keeps the newest input sample until the next publication opportunity.
/// Repeated samples and samples that return to the last published value are
/// discarded, while a continuous stream never postpones a pending delivery.
struct GraphLatestInput<Value: Equatable> {
    private(set) var pending: Value?
    private(set) var lastPublished: Value?

    mutating func stage(_ value: Value) -> Bool {
        pending = value
        return value != lastPublished
    }

    mutating func take(force: Bool = false) -> Value? {
        guard let value = pending else { return nil }
        pending = nil
        guard force || value != lastPublished else { return nil }
        lastPublished = value
        return value
    }

    mutating func discardPending() {
        pending = nil
    }
}

struct GraphPointerSample: Equatable {
    let point: CGPoint?
    let geometryRevision: Int
}

/// A pending publication opportunity. `cancel` may run from any context,
/// including after the window has already delivered.
struct GraphPublicationWindow: Sendable {
    let cancel: @Sendable () -> Void
}

/// Opens publication windows for `GraphInputPublisher`. The app waits on the
/// task clock; tests open windows explicitly so they never race wall-clock
/// sleeps against a busy main actor.
@MainActor
protocol GraphPublicationScheduling {
    func schedule(after interval: Duration, _ deliver: @escaping @MainActor () -> Void) -> GraphPublicationWindow
}

struct TaskPublicationScheduler: GraphPublicationScheduling {
    func schedule(after interval: Duration, _ deliver: @escaping @MainActor () -> Void) -> GraphPublicationWindow {
        let task = Task { @MainActor in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            deliver()
        }
        return GraphPublicationWindow(cancel: { task.cancel() })
    }
}

/// One scheduled delivery per interval; later input replaces the pending value
/// without cancelling the delivery. This object intentionally is not observable.
@MainActor
final class GraphInputPublisher<Value: Equatable> {
    private let interval: Duration
    private let scheduler: any GraphPublicationScheduling
    private var input = GraphLatestInput<Value>()
    private var window: GraphPublicationWindow?
    private var publish: (@MainActor (Value) -> Void)?

    init(interval: Duration, scheduler: any GraphPublicationScheduling = TaskPublicationScheduler()) {
        self.interval = interval
        self.scheduler = scheduler
    }

    deinit {
        window?.cancel()
    }

    func enqueue(_ value: Value, publish: @escaping @MainActor (Value) -> Void) {
        guard input.stage(value) else {
            self.publish = nil
            return
        }
        self.publish = publish
        guard window == nil else { return }
        window = scheduler.schedule(after: interval) { [weak self] in
            guard let self else { return }
            self.window = nil
            self.deliver()
        }
    }

    func flush(_ value: Value, force: Bool = false, publish: @escaping @MainActor (Value) -> Void) {
        window?.cancel()
        window = nil
        self.publish = publish
        _ = input.stage(value)
        deliver(force: force)
    }

    func cancel() {
        window?.cancel()
        window = nil
        input.discardPending()
        publish = nil
    }

    private func deliver(force: Bool = false) {
        let callback = publish
        publish = nil
        guard let value = input.take(force: force) else { return }
        callback?(value)
    }
}
