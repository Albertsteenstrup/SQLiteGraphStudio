import AVFoundation
import Darwin
import Foundation

/// App-managed Pocket TTS 3.1.0 provider. A single worker keeps the model and preset voice warm
/// across narration points; its stdout is a bounded JSON-lines PCM stream and its stderr is kept
/// out of the audio path.
@MainActor
public final class PocketTTSStreamingSpeechProvider: StreamingSpeechProvider {
    public let identifier = "pocket-tts-3.1.0"
    public let displayName = "Pocket TTS (Alba)"

    public let workerRoot: URL
    public let presetRoot: URL
    private var session: PocketTTSWorkerSession?

    public init(
        workerRoot: URL = PocketTTSRuntimeInspector.bundledDefault().workerRoot,
        presetRoot: URL = PocketTTSRuntimeInspector.bundledDefault().presetRoot
    ) {
        self.workerRoot = workerRoot
        self.presetRoot = presetRoot
    }

    public var isAvailable: Bool {
        let python = workerRoot.appendingPathComponent("python/bin/python3")
        let worker = workerRoot.appendingPathComponent("pocket_tts_worker.py")
        let lock = workerRoot.appendingPathComponent("requirements.lock")
        return [python, worker, lock].allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        } && PocketTTSSpeechAssets.assets.allSatisfy {
            FileManager.default.fileExists(
                atPath: presetRoot.appendingPathComponent($0.relativePath).path
            )
        }
    }

    public func prepare() async throws {
        guard isAvailable else {
            throw StreamingSpeechError.unavailable(
                PocketTTSRuntimeInspector.bundledDefault().inspect().explanation
            )
        }
        if let session, session.isReady {
            return
        }

        session?.terminate()
        let newSession = PocketTTSWorkerSession(workerRoot: workerRoot, presetRoot: presetRoot)
        session = newSession
        do {
            try await withTaskCancellationHandler {
                try await newSession.startAndWaitUntilReady()
                try Task.checkCancellation()
                guard newSession.isReady else {
                    throw PocketTTSWorkerError.workerStopped
                }
            } onCancel: {
                newSession.terminate()
            }
            PocketTTSRuntimeHandshakeCache.shared.markSucceeded(workerRoot: workerRoot)
        } catch {
            PocketTTSRuntimeHandshakeCache.shared.markFailed(workerRoot: workerRoot)
            if session === newSession {
                session = nil
            }
            throw error
        }
    }

    public func makeStream(for text: String) throws -> SpeechAudioStream {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            let producer = SpeechAudioStreamProducer(capacity: 1)
            producer.finish()
            return producer.stream
        }
        guard let session, session.isReady else {
            throw PocketTTSWorkerError.notReady
        }

        let requestID = UUID().uuidString
        let producer = SpeechAudioStreamProducer(capacity: 2, onCancel: { [weak session] in
            session?.cancel(requestID: requestID)
        })
        do {
            try session.begin(requestID: requestID, text: value, producer: producer)
        } catch {
            producer.finish(throwing: error)
            throw error
        }

        // Cancelling the consumer tears down the worker immediately. The next call to prepare()
        // starts a fresh process and reloads the model, avoiding a stuck generator after an
        // interrupted utterance.
        return producer.stream
    }

    public func cancel() {
        guard let session, session.hasActiveRequest else { return }
        session.cancelActive()
        PocketTTSRuntimeHandshakeCache.shared.markFailed(workerRoot: workerRoot)
    }

    public func pause() {
        // The player pauses output. Its bounded queue naturally backpressures the worker.
    }

    public func resume() {
        // Generation resumes when the player drains the existing bounded queue.
    }
}

private enum PocketTTSWorkerError: LocalizedError {
    case notReady
    case invalidProtocol(String)
    case workerFailed(String)
    case workerStopped

    var errorDescription: String? {
        switch self {
        case .notReady:
            "Pocket TTS has not completed its model startup handshake."
        case .invalidProtocol(let detail):
            "Pocket TTS returned an invalid audio stream: \(detail)"
        case .workerFailed(let detail):
            "Pocket TTS could not start or generate speech: \(detail)"
        case .workerStopped:
            "The Pocket TTS worker stopped before narration finished."
        }
    }
}

/// Process and line-framing state live outside the main actor. The stdout reader blocks while it
/// pushes into a two-chunk stream queue, propagating backpressure all the way to the worker pipe.
final class PocketTTSWorkerSession: @unchecked Sendable {
    private enum Startup {
        case starting
        case ready(sampleRate: Double)
        case failed(any Error)
    }

    private let process: Process
    private let input: Pipe
    private let output: Pipe
    private let workerRoot: URL
    private let lock = NSLock()
    private var startup: Startup = .starting
    private var startupWaiter: CheckedContinuation<Void, any Error>?
    private var lineBuffer = Data()
    private var activeRequestID: String?
    private var activeProducer: SpeechAudioStreamProducer?
    private var sampleRate: Double = 24_000
    private var didTerminate = false

    init(workerRoot: URL, presetRoot: URL) {
        self.workerRoot = workerRoot
        process = Process()
        input = Pipe()
        output = Pipe()

        process.executableURL = workerRoot.appendingPathComponent("python/bin/python3")
        process.arguments = [
            workerRoot.appendingPathComponent("pocket_tts_worker.py").path,
            "--preset-root",
            presetRoot.path,
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PYTHONNOUSERSITE": "1",
            "PYTHONPATH": workerRoot.appendingPathComponent(
                "python/lib/python3.12/site-packages",
                isDirectory: true
            ).path,
            "TOKENIZERS_PARALLELISM": "false",
            "HF_HUB_OFFLINE": "1",
            "TRANSFORMERS_OFFLINE": "1",
        ]) { _, new in new }
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .ready = startup { return !didTerminate && process.isRunning }
        return false
    }

    var hasActiveRequest: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeRequestID != nil
    }

    func startAndWaitUntilReady() async throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            // FileHandle.read(upToCount:) may wait for the entire requested count. The
            // worker's short ready line then remains unread while it waits for a command.
            // A POSIX read on the readable descriptor returns the bytes available now.
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                self.receive(Data(buffer.prefix(count)))
            } else if count == 0 {
                self.workerDidStop()
            } else if errno != EINTR && errno != EAGAIN {
                self.fail(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
            }
        }
        process.terminationHandler = { [weak self] _ in
            self?.workerDidStop()
        }

        try lock.withLock {
            guard !didTerminate else { throw PocketTTSWorkerError.workerStopped }
            try process.run()
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            switch startup {
            case .starting:
                startupWaiter = continuation
                lock.unlock()
            case .ready:
                lock.unlock()
                continuation.resume()
            case .failed(let error):
                lock.unlock()
                continuation.resume(throwing: error)
            }
        }
    }

    func begin(
        requestID: String,
        text: String,
        producer: SpeechAudioStreamProducer
    ) throws {
        lock.lock()
        guard !didTerminate, case .ready = startup, activeRequestID == nil else {
            lock.unlock()
            throw PocketTTSWorkerError.notReady
        }
        activeRequestID = requestID
        activeProducer = producer
        lock.unlock()

        do {
            try send(["type": "synthesize", "id": requestID, "text": text])
        } catch {
            lock.lock()
            if activeRequestID == requestID {
                activeRequestID = nil
                activeProducer = nil
            }
            lock.unlock()
            throw error
        }
    }

    func cancelActive() {
        lock.lock()
        let requestID = activeRequestID
        lock.unlock()
        guard let requestID else { return }
        cancel(requestID: requestID)
    }

    func cancel(requestID: String) {
        lock.lock()
        guard activeRequestID == requestID else {
            lock.unlock()
            return
        }
        activeProducer?.finish(throwing: CancellationError())
        activeProducer = nil
        activeRequestID = nil
        lock.unlock()

        try? send(["type": "cancel", "id": requestID])
        terminate()
    }

    func terminate() {
        lock.lock()
        guard !didTerminate else {
            lock.unlock()
            return
        }
        didTerminate = true
        let producer = activeProducer
        activeProducer = nil
        activeRequestID = nil
        let waiter = startupWaiter
        startupWaiter = nil
        if case .starting = startup {
            startup = .failed(PocketTTSWorkerError.workerStopped)
        }
        lock.unlock()

        producer?.finish(throwing: CancellationError())
        waiter?.resume(throwing: PocketTTSWorkerError.workerStopped)
        PocketTTSRuntimeHandshakeCache.shared.markFailed(workerRoot: workerRoot)
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        if process.isRunning {
            process.terminate()
        }
    }

    private func send(_ object: [String: String]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
        data.append(0x0A)
        do {
            try input.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw PocketTTSWorkerError.workerFailed(error.localizedDescription)
        }
    }

    private func receive(_ data: Data) {
        lock.lock()
        lineBuffer.append(data)
        guard lineBuffer.count <= 2 * 1024 * 1024 else {
            lock.unlock()
            fail(PocketTTSWorkerError.invalidProtocol("a worker message exceeded the size limit"))
            return
        }

        var lines: [Data] = []
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            lines.append(lineBuffer.prefix(upTo: newline))
            lineBuffer.removeSubrange(...newline)
        }
        lock.unlock()

        for line in lines where !line.isEmpty {
            do {
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let type = message["type"] as? String else {
                    throw PocketTTSWorkerError.invalidProtocol("message is not a typed JSON object")
                }
                handle(message, type: type)
            } catch {
                fail(error)
            }
        }
    }

    private func handle(_ message: [String: Any], type: String) {
        switch type {
        case "ready":
            guard message["protocol"] as? Int == 1,
                  message["version"] as? String == "3.1.0",
                  message["provider"] as? String == "pocket-tts",
                  message["voice"] as? String == "alba",
                  message["format"] as? String == "f32le",
                  let rate = message["sample_rate"] as? Double,
                  rate > 0,
                  message["channels"] as? Int == 1 else {
                fail(PocketTTSWorkerError.invalidProtocol("startup handshake did not match Pocket TTS 3.1.0"))
                return
            }

            lock.lock()
            sampleRate = rate
            startup = .ready(sampleRate: rate)
            let waiter = startupWaiter
            startupWaiter = nil
            lock.unlock()
            waiter?.resume()

        case "startup_error":
            let detail = message["message"] as? String ?? "unknown startup error"
            fail(PocketTTSWorkerError.workerFailed(detail))

        case "chunk":
            handleChunk(message)

        case "finished":
            guard let requestID = message["id"] as? String else { return }
            lock.lock()
            guard activeRequestID == requestID else {
                lock.unlock()
                return
            }
            let producer = activeProducer
            activeProducer = nil
            activeRequestID = nil
            lock.unlock()
            producer?.finish()

        case "error":
            let detail = message["message"] as? String ?? "unknown worker error"
            let requestID = message["id"] as? String
            lock.lock()
            if let requestID, requestID == activeRequestID {
                let producer = activeProducer
                activeProducer = nil
                activeRequestID = nil
                lock.unlock()
                producer?.finish(throwing: PocketTTSWorkerError.workerFailed(detail))
            } else {
                lock.unlock()
                fail(PocketTTSWorkerError.workerFailed(detail))
            }

        default:
            fail(PocketTTSWorkerError.invalidProtocol("unknown event \(type)"))
        }
    }

    private func handleChunk(_ message: [String: Any]) {
        guard let requestID = message["id"] as? String,
              let sampleCount = message["sample_count"] as? Int,
              sampleCount > 0,
              sampleCount <= 12_000,
              let encodedPCM = message["pcm"] as? String,
              let pcm = Data(base64Encoded: encodedPCM),
              pcm.count == sampleCount * MemoryLayout<Float>.size else {
            fail(PocketTTSWorkerError.invalidProtocol("PCM frame data was invalid"))
            return
        }

        lock.lock()
        guard activeRequestID == requestID,
              case .ready(let rate) = startup,
              let producer = activeProducer else {
            lock.unlock()
            return
        }
        lock.unlock()

        do {
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: rate,
                channels: 1,
                interleaved: false
            ), let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sampleCount)
            ), let channel = buffer.floatChannelData?.pointee else {
                throw StreamingSpeechError.invalidPCMBuffer
            }
            buffer.frameLength = AVAudioFrameCount(sampleCount)
            pcm.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                memcpy(channel, base, pcm.count)
            }
            let chunk = try SpeechPCMChunk(copying: buffer)
            guard producer.yield(chunk) else { return }
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: any Error) {
        lock.lock()
        let waiter = startupWaiter
        startupWaiter = nil
        startup = .failed(error)
        let producer = activeProducer
        activeProducer = nil
        activeRequestID = nil
        lock.unlock()

        waiter?.resume(throwing: error)
        producer?.finish(throwing: error)
        PocketTTSRuntimeHandshakeCache.shared.markFailed(workerRoot: workerRoot)
        if process.isRunning { process.terminate() }
    }

    private func workerDidStop() {
        lock.lock()
        let waiter = startupWaiter
        startupWaiter = nil
        if case .starting = startup {
            startup = .failed(PocketTTSWorkerError.workerStopped)
        }
        let producer = activeProducer
        activeProducer = nil
        activeRequestID = nil
        lock.unlock()

        waiter?.resume(throwing: PocketTTSWorkerError.workerStopped)
        producer?.finish(throwing: PocketTTSWorkerError.workerStopped)
        PocketTTSRuntimeHandshakeCache.shared.markFailed(workerRoot: workerRoot)
    }
}
