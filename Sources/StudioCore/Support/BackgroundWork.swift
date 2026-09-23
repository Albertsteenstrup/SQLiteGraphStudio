import Foundation

/// Runs blocking work off the current actor while keeping it cancellable.
///
/// `Task.detached` inherits neither cancellation nor priority from its caller,
/// and awaiting a detached task is not interrupted by the waiter's own
/// cancellation either. Both together mean a plain `await Task.detached { … }.value`
/// keeps running at full speed after the caller is cancelled, which is exactly
/// what a Cancel button must not do.
public enum BackgroundWork {
    public static func run<T: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: priority, operation: work)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
