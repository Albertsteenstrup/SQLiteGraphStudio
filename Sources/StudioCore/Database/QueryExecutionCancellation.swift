import Foundation

/// A deadline owns its operation task so timeout and caller cancellation both
/// wait for backend cleanup before returning. GRDB async reads interrupt their
/// leased SQLite connection; PostgreSQL installs a lease-scoped close handler.
func withQueryTimeout<Value: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    guard seconds.isFinite, seconds > 0, seconds <= 86_400 else {
        throw DatabaseUserError(kind: .invalidInput, message: "Query timeout must be between 0 and 86400 seconds.")
    }
    return try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw DatabaseUserError(kind: .timeout, message: "Query timed out after \(seconds.formatted()) seconds.")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
