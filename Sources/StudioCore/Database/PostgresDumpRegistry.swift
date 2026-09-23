import Foundation

/// A single ownership claim on a restored PostgreSQL dump. Each database
/// service closes its own connection pool, then releases this lease. The shared
/// server is shut down only when the final lease is released.
final class PostgresDumpLease: @unchecked Sendable {
    let session: PostgresDumpSession

    private let lock = NSLock()
    private var didRelease = false
    private let releaseBody: @Sendable () async -> Void

    fileprivate init(session: PostgresDumpSession, release: @escaping @Sendable () async -> Void) {
        self.session = session
        self.releaseBody = release
    }

    func release() async {
        guard claimRelease() else { return }
        await releaseBody()
    }

    private func claimRelease() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didRelease else { return false }
        didRelease = true
        return true
    }
}

/// Lets one cancelled opener stop waiting without cancelling another tab's
/// shared preparation. The unstructured waiter relinquishes its reservation;
/// the registry cancels preparation only when no reservations remain.
private final class PostgresDumpPreparationWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var resolution: Result<PostgresDumpSession, any Error>?
    private var continuation: CheckedContinuation<PostgresDumpSession, any Error>?

    func value(of preparation: Task<PostgresDumpSession, Error>) async throws -> PostgresDumpSession {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let resolution {
                lock.unlock()
                continuation.resume(with: resolution)
                return
            }
            self.continuation = continuation
            lock.unlock()

            Task { [weak self] in
                do { self?.resolve(.success(try await preparation.value)) }
                catch { self?.resolve(.failure(error)) }
            }
        }
    }

    func cancel() {
        resolve(.failure(CancellationError()))
    }

    private func resolve(_ result: Result<PostgresDumpSession, any Error>) {
        lock.lock()
        guard resolution == nil else { lock.unlock(); return }
        resolution = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// Coalesces concurrent opens of the same unchanged archive into one private
/// restored database. The key includes a file fingerprint so replacing a dump
/// at the same path creates a fresh runtime.
actor PostgresDumpRegistry {
    typealias Progress = @Sendable (String) async -> Void
    typealias Prepare = @Sendable (URL, @escaping Progress) async throws -> PostgresDumpSession

    static let shared = PostgresDumpRegistry { url, progress in
        try await PostgresDumpSession.prepare(url: url, progress: progress)
    }

    private struct SourceKey: Hashable, Sendable {
        let path: String
        let byteCount: Int?
        let modifiedAt: Date?

        init(url: URL) {
            let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
            path = canonicalURL.path
            let values = try? canonicalURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            byteCount = values?.fileSize
            modifiedAt = values?.contentModificationDate
        }
    }

    private struct Entry {
        let id: UUID
        let preparation: Task<PostgresDumpSession, Error>
        var owners: Int
    }

    private let prepare: Prepare
    private var entries: [SourceKey: Entry] = [:]
    private var retiring: [UUID: Task<Void, Never>] = [:]

    init(prepare: @escaping Prepare) {
        self.prepare = prepare
    }

    /// Current open reservations and returned leases for this source. Kept
    /// internal so lifecycle tests can coordinate concurrent cancellation cases.
    func ownershipCount(for url: URL) -> Int {
        entries[SourceKey(url: url)]?.owners ?? 0
    }

    func acquire(url: URL, progress: @escaping Progress = { _ in }) async throws -> PostgresDumpLease {
        let key = SourceKey(url: url)
        let entryID: UUID
        let preparation: Task<PostgresDumpSession, Error>

        if var entry = entries[key] {
            entry.owners += 1
            entries[key] = entry
            entryID = entry.id
            preparation = entry.preparation
        } else {
            let id = UUID()
            let prepare = self.prepare
            let task = Task { try await prepare(url, progress) }
            entries[key] = Entry(id: id, preparation: task, owners: 1)
            entryID = id
            preparation = task
        }

        let waiter = PostgresDumpPreparationWaiter()
        do {
            let session = try await withTaskCancellationHandler {
                try await waiter.value(of: preparation)
            } onCancel: {
                waiter.cancel()
            }
            try Task.checkCancellation()
            return PostgresDumpLease(session: session) { [weak self] in
                await self?.release(key: key, entryID: entryID)
            }
        } catch {
            await release(key: key, entryID: entryID)
            throw error
        }
    }

    private func release(key: SourceKey, entryID: UUID) async {
        guard var entry = entries[key], entry.id == entryID else {
            await retiring[entryID]?.value
            return
        }
        entry.owners -= 1
        guard entry.owners == 0 else {
            entries[key] = entry
            return
        }

        // Remove ownership before awaiting teardown so a new open can prepare
        // a fresh copy while the previous server is finishing its shutdown.
        entries.removeValue(forKey: key)
        let preparation = entry.preparation
        let cleanup = Task {
            preparation.cancel()
            if let session = try? await preparation.value { await session.close() }
        }
        retiring[entryID] = cleanup
        await cleanup.value
        retiring.removeValue(forKey: entryID)
    }
}
