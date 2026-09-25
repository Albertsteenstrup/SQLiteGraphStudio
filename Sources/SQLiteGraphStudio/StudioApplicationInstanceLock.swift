import Darwin
import Foundation
import StudioMCP

/// Launch Services' single-instance setting is scoped to the app it resolves.
/// Development builds in separate worktrees have different bundle paths, so
/// hold one user-wide lock before SwiftUI creates any windows or sessions.
final class StudioApplicationInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }

    /// Returns nil when another Graph Studio process already holds the lock.
    static func acquire(directory: URL = MCPBridgePaths.runtimeDirectory) throws -> StudioApplicationInstanceLock? {
        let path = directory.standardizedFileURL.path
        if Darwin.mkdir(path, 0o700) != 0 && errno != EEXIST {
            throw LockError("Could not create Graph Studio's private runtime directory.")
        }
        var directoryInfo = stat()
        guard lstat(path, &directoryInfo) == 0,
              directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              directoryInfo.st_uid == getuid(),
              directoryInfo.st_mode & 0o077 == 0 else {
            throw LockError("Graph Studio's runtime directory has unsafe ownership or permissions.")
        }

        let lockPath = directory.appendingPathComponent("application.lock").path
        let fd = Darwin.open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw LockError("Could not open Graph Studio's application lock.") }
        var fileInfo = stat()
        guard fstat(fd, &fileInfo) == 0,
              fileInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              fileInfo.st_uid == getuid(),
              fileInfo.st_mode & 0o077 == 0 else {
            _ = Darwin.close(fd)
            throw LockError("Graph Studio's application lock has unsafe ownership or permissions.")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK || errno == EAGAIN
            _ = Darwin.close(fd)
            if busy { return nil }
            throw LockError("Could not acquire Graph Studio's application lock.")
        }
        return StudioApplicationInstanceLock(descriptor: fd)
    }

    /// Older development builds do not take application.lock. Their live MCP
    /// listener is a second signal that we must reuse their app, not start UI.
    static func existingBridgeIsListening() -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { _ = Darwin.close(fd) }
        var address = sockaddr_un()
        let path = MCPBridgePaths.socketURL.path
        let bytes = Array(path.utf8) + [0]
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    private struct LockError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
