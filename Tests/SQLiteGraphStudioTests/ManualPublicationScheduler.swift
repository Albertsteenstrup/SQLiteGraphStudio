import Synchronization
@testable import StudioCore

/// Opens `GraphInputPublisher` windows only when a test calls `elapse()`, so
/// scheduler tests stay deterministic when parallel suites keep the main
/// actor busy.
@MainActor
final class ManualPublicationScheduler: GraphPublicationScheduling {
    private final class Window: Sendable {
        let deliver: @MainActor () -> Void
        private let cancelled = Mutex(false)

        init(deliver: @escaping @MainActor () -> Void) {
            self.deliver = deliver
        }

        var isCancelled: Bool { cancelled.withLock { $0 } }
        func cancel() { cancelled.withLock { $0 = true } }
    }

    private var windows: [Window] = []
    private(set) var requestedIntervals: [Duration] = []

    /// Windows that are scheduled and not cancelled.
    var openWindowCount: Int { windows.count { !$0.isCancelled } }

    func schedule(after interval: Duration, _ deliver: @escaping @MainActor () -> Void) -> GraphPublicationWindow {
        let window = Window(deliver: deliver)
        windows.append(window)
        requestedIntervals.append(interval)
        return GraphPublicationWindow(cancel: { window.cancel() })
    }

    /// Delivers every open window, as if its interval had passed.
    func elapse() {
        let due = windows
        windows.removeAll()
        for window in due where !window.isCancelled {
            window.deliver()
        }
    }
}
