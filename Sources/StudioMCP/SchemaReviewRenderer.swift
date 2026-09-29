import Darwin
import Foundation

/// Runs Graph Studio's hidden review renderer, `SQLiteGraphStudio --render-review-session`,
/// so the inline review view can show exactly what the app draws.
///
/// A helper starts its renderer on the first frame and stops it after two idle minutes.
/// All helpers on the machine share at most two renderers: a running renderer holds one of
/// two lock files, and a view that finds both taken draws its own simplified graph instead.
/// The renderer reads requests from a pipe and exits when the pipe closes, so it never
/// outlives the helper that started it.
///
/// Every mutable property is touched only on `queue`.
public final class SchemaReviewRenderer: @unchecked Sendable {
    public static let shared = SchemaReviewRenderer()

    static let sessionFlag = "--render-review-session"
    static let executableName = "SQLiteGraphStudio"
    static let rendererName = "Graph Studio Review Renderer"
    static let idleTimeout: TimeInterval = 120
    static let slotCount = 2
    /// Opening a large review (hundreds of tables) takes a few seconds; frames after that
    /// take a fraction of a second.
    static let requestTimeout: TimeInterval = 30
    static let maximumResponseBytes = 64 * 1024 * 1024

    private let queue = DispatchQueue(label: "SchemaReviewRenderer")
    private let executableProvider: () -> URL?
    private let slotDirectory: URL
    private let cloneDirectory: URL
    private let idleTimeout: TimeInterval
    private var running: RunningRenderer?
    private var runningVersion: ExecutableVersion?
    private var idleTimer: DispatchSourceTimer?
    private var nextRequestID = 1

    public convenience init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.init(executableProvider: { SchemaReviewRenderer.findExecutable() },
                  slotDirectory: MCPBridgePaths.runtimeDirectory.appendingPathComponent("renderers", isDirectory: true),
                  cloneDirectory: caches.appendingPathComponent(MCPBridgePaths.appBundleIdentifier, isDirectory: true)
                      .appendingPathComponent("Review Renderer", isDirectory: true),
                  idleTimeout: Self.idleTimeout)
    }

    init(executableProvider: @escaping () -> URL?, slotDirectory: URL, cloneDirectory: URL, idleTimeout: TimeInterval) {
        self.executableProvider = executableProvider
        self.slotDirectory = slotDirectory
        self.cloneDirectory = cloneDirectory
        self.idleTimeout = idleTimeout
    }

    deinit {
        idleTimer?.cancel()
        running?.stop()
    }

    /// Sends one request and returns the renderer's reply. Starts the renderer when needed.
    func request(_ request: [String: Any]) throws -> [String: Any] {
        try queue.sync {
            idleTimer?.cancel()
            idleTimer = nil
            defer { scheduleIdleStopLocked() }
            let renderer = try runningLocked()
            var message = request
            message["id"] = nextRequestID
            nextRequestID += 1
            do {
                let response = try renderer.exchange(message, timeout: Self.requestTimeout)
                guard response["ok"] as? Bool == true else {
                    throw RendererError.failed(response["error"] as? String ?? "The renderer could not draw this review.")
                }
                return response
            } catch let error as RendererError {
                // A renderer that stopped answering is replaced on the next request.
                if case .failed = error, !renderer.isAlive { stopLocked() }
                if case .timedOut = error { stopLocked() }
                throw error
            }
        }
    }

    /// Stops the renderer now, releasing its slot for another helper.
    public func stop() {
        queue.sync { stopLocked() }
    }

    var isRunning: Bool {
        queue.sync { running?.isAlive == true }
    }

    // MARK: Process lifecycle

    private func runningLocked() throws -> RunningRenderer {
        guard let executable = executableProvider() else {
            throw RendererError.unavailable("Graph Studio's renderer could not be found next to this helper or in an installed app.")
        }
        let version = try ExecutableVersion(executable)
        if let running, running.isAlive, runningVersion == version { return running }
        // Installing a newer app must also update long-lived embedded viewers.
        stopLocked()
        guard let slot = RendererSlot.acquire(in: slotDirectory, count: Self.slotCount) else {
            throw RendererError.busy("Graph Studio is already drawing reviews for \(Self.slotCount) other sessions.")
        }
        do {
            let clone = try Self.clone(of: executable, in: cloneDirectory)
            let renderer = try RunningRenderer(executable: clone, arguments: [Self.sessionFlag], slot: slot)
            running = renderer
            runningVersion = version
            return renderer
        } catch {
            slot.release()
            throw RendererError.unavailable("Graph Studio's renderer could not be started: \(error.localizedDescription)")
        }
    }

    private func scheduleIdleStopLocked() {
        guard running != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + idleTimeout)
        timer.setEventHandler { [weak self] in self?.stopLocked() }
        idleTimer = timer
        timer.resume()
    }

    private func stopLocked() {
        idleTimer?.cancel()
        idleTimer = nil
        running?.stop()
        running = nil
        runningVersion = nil
    }

    private struct ExecutableVersion: Equatable {
        let path: String
        let inode: UInt64
        let size: UInt64
        let modified: Date

        init(_ executable: URL) throws {
            let source = executable.resolvingSymlinksInPath()
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            path = source.path
            inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            modified = attributes[.modificationDate] as? Date ?? .distantPast
        }

        var cacheKey: String {
            "\(inode)-\(size)-\(modified.timeIntervalSince1970.bitPattern)"
        }
    }

    /// macOS ties a running process to an app by its executable file: a renderer started from
    /// Graph Studio's own executable would receive the documents meant for the app (`open -a`,
    /// a double-click in Finder), even from outside the bundle through a link. The renderer
    /// runs from a clone instead, a separate file that shares the executable's storage on
    /// APFS. It is made once per app build; clones of other builds are removed.
    static func clone(of executable: URL, in directory: URL) throws -> URL {
        let source = executable.resolvingSymlinksInPath()
        let version = try ExecutableVersion(source)
        let size = version.size
        let key = version.cacheKey
        let folder = directory.appendingPathComponent(key, isDirectory: true)
        let destination = folder.appendingPathComponent(rendererName)
        if let existing = try? FileManager.default.attributesOfItem(atPath: destination.path),
           (existing[.size] as? NSNumber)?.uint64Value == size {
            return destination
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Clone to a private name and rename, so helpers starting at once never run a
        // partial file.
        let staging = folder.appendingPathComponent(".\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: staging)
        if Darwin.rename(staging.path, destination.path) != 0 {
            try? FileManager.default.removeItem(at: staging)
            guard FileManager.default.isExecutableFile(atPath: destination.path) else {
                throw RendererError.unavailable("Graph Studio's renderer could not be prepared.")
            }
        }
        for other in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where other.lastPathComponent != key {
            try? FileManager.default.removeItem(at: other)
        }
        return destination
    }

    /// The app executable beside this helper (inside the app bundle, or in the same build
    /// directory during development), else the installed app's.
    static func findExecutable() -> URL? {
        var candidates: [URL] = []
        if let helper = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            candidates.append(helper.deletingLastPathComponent().appendingPathComponent(executableName))
        }
        if let app = UnixSocketMCPBridge.findApplication() {
            candidates.append(app.appendingPathComponent("Contents/MacOS", isDirectory: true).appendingPathComponent(executableName))
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    enum RendererError: Error {
        case unavailable(String)
        case busy(String)
        case timedOut(String)
        case failed(String)

        var code: String {
            switch self {
            case .unavailable: "RENDERER_UNAVAILABLE"
            case .busy: "RENDERER_BUSY"
            case .timedOut: "RENDERER_TIMEOUT"
            case .failed: "RENDERER_FAILED"
            }
        }

        var message: String {
            switch self {
            case .unavailable(let message), .busy(let message), .timedOut(let message), .failed(let message): message
            }
        }
    }
}

/// One of the machine-wide renderer slots: an exclusive lock on a private file, held for
/// as long as the renderer runs and released by the kernel if the helper dies.
struct RendererSlot {
    let descriptor: Int32

    static func acquire(in directory: URL, count: Int) -> RendererSlot? {
        let path = directory.standardizedFileURL.path
        let parent = directory.deletingLastPathComponent().standardizedFileURL.path
        // Only this user may add to the parent, and only this user may enter the slots folder.
        for (folder, disallowed) in [(parent, mode_t(0o022)), (path, mode_t(0o077))] {
            if Darwin.mkdir(folder, 0o700) != 0 && errno != EEXIST { return nil }
            var info = stat()
            guard lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), info.st_mode & disallowed == 0 else { return nil }
        }
        for index in 0..<count {
            let fd = Darwin.open("\(path)/slot-\(index).lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { continue }
            var info = stat()
            if fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
               flock(fd, LOCK_EX | LOCK_NB) == 0 {
                return RendererSlot(descriptor: fd)
            }
            Darwin.close(fd)
        }
        return nil
    }

    func release() {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

/// A started renderer process and its request and reply pipes.
final class RunningRenderer {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let slot: RendererSlot
    private var buffer = Data()
    private var stopped = false

    init(executable: URL, arguments: [String], slot: RendererSlot) throws {
        let requests = Pipe(), replies = Pipe()
        process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = requests
        process.standardOutput = replies
        process.standardError = FileHandle.nullDevice
        input = requests.fileHandleForWriting
        output = replies.fileHandleForReading
        self.slot = slot
        // A renderer that exits must surface as an error here, never as SIGPIPE in the helper.
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
    }

    var isAlive: Bool { !stopped && process.isRunning }

    func exchange(_ request: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        guard JSONSerialization.isValidJSONObject(request) else {
            throw SchemaReviewRenderer.RendererError.failed("The render request was not valid JSON.")
        }
        var line = try JSONSerialization.data(withJSONObject: request)
        line.append(0x0A)
        try write(line)
        let reply = try readLine(deadline: Date().addingTimeInterval(timeout))
        guard let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              object["id"] as? Int == request["id"] as? Int
        else {
            throw SchemaReviewRenderer.RendererError.failed("The renderer returned an unreadable reply.")
        }
        return object
    }

    /// Closing the request pipe asks the renderer to exit; one that doesn't is terminated.
    func stop() {
        guard !stopped else { return }
        stopped = true
        try? input.close()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
        try? output.close()
        slot.release()
    }

    private func write(_ data: Data) throws {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(input.fileDescriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw SchemaReviewRenderer.RendererError.failed("The renderer stopped.")
                }
                offset += written
            }
        }
    }

    private func readLine(deadline: Date) throws -> Data {
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw SchemaReviewRenderer.RendererError.timedOut("The renderer did not answer in time.")
            }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining, 1) * 1000))
            if ready < 0 && errno != EINTR { throw SchemaReviewRenderer.RendererError.failed("The renderer stopped.") }
            guard ready > 0 else { continue }
            let count = chunk.withUnsafeMutableBytes { Darwin.read(output.fileDescriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw SchemaReviewRenderer.RendererError.failed("The renderer stopped.") }
            buffer.append(contentsOf: chunk[..<count])
            guard buffer.count <= SchemaReviewRenderer.maximumResponseBytes else {
                throw SchemaReviewRenderer.RendererError.failed("The renderer's reply exceeded the size limit.")
            }
        }
    }
}
