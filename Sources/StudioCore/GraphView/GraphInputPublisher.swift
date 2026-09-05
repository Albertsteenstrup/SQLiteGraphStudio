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

/// One scheduled delivery per interval; later input replaces the pending value
/// without cancelling the delivery. This object intentionally is not observable.
@MainActor
final class GraphInputPublisher<Value: Equatable> {
    private let interval: Duration
    private var input = GraphLatestInput<Value>()
    private var task: Task<Void, Never>?
    private var publish: (@MainActor (Value) -> Void)?

    init(interval: Duration) {
        self.interval = interval
    }

    deinit {
        task?.cancel()
    }

    func enqueue(_ value: Value, publish: @escaping @MainActor (Value) -> Void) {
        guard input.stage(value) else {
            self.publish = nil
            return
        }
        self.publish = publish
        guard task == nil else { return }
        let interval = interval
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, let self else { return }
            self.task = nil
            self.deliver()
        }
    }

    func flush(_ value: Value, force: Bool = false, publish: @escaping @MainActor (Value) -> Void) {
        task?.cancel()
        task = nil
        self.publish = publish
        _ = input.stage(value)
        deliver(force: force)
    }

    func cancel() {
        task?.cancel()
        task = nil
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
