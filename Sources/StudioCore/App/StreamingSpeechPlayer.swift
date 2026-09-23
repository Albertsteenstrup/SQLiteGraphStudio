import AVFoundation
import Foundation

@MainActor
final class StreamingSpeechPlayer {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var connectedFormat: AVAudioFormat?

    init() {}

    func play(
        _ stream: SpeechAudioStream,
        onFirstAudio: @MainActor @Sendable () -> Void
    ) async throws -> Bool {
        var didStart = false

        do {
            for try await chunk in stream {
                try Task.checkCancellation()
                if !didStart {
                    try startOutput(format: chunk.audioBuffer.format)
                    didStart = true
                    onFirstAudio()
                }

                guard await scheduleAndDrain(chunk.audioBuffer) else {
                    return false
                }
            }

            return didStart
        } catch {
            stopImmediately()
            throw error
        }
    }

    func pause() {
        player?.pause()
    }

    func resume() {
        guard connectedFormat != nil,
              let engine,
              let player else { return }
        do {
            if !engine.isRunning {
                try engine.start()
            }
            player.play()
        } catch {
            stopImmediately()
        }
    }

    func stopImmediately() {
        player?.stop()
        if engine?.isRunning == true {
            engine?.stop()
        }
        connectedFormat = nil
    }

    private func startOutput(format: AVAudioFormat) throws {
        let (engine, player) = audioGraph()
        if let connectedFormat, Self.formatsMatch(connectedFormat, format), engine.isRunning {
            player.play()
            return
        }

        player.stop()
        if engine.isRunning {
            engine.stop()
        }
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        connectedFormat = format
        engine.prepare()

        do {
            try engine.start()
            player.play()
        } catch {
            connectedFormat = nil
            throw StreamingSpeechError.outputStartFailed(error.localizedDescription)
        }
    }

    private func scheduleAndDrain(_ buffer: AVAudioPCMBuffer) async -> Bool {
        guard let player else { return false }
        let waiter = AudioBufferDrainWaiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard waiter.install(continuation) else { return }
                player.scheduleBuffer(
                    buffer,
                    completionCallbackType: .dataPlayedBack
                ) { _ in
                    waiter.resolve(true)
                }
            }
        } onCancel: {
            waiter.resolve(false)
            Task { @MainActor [weak self] in
                self?.stopImmediately()
            }
        }
    }

    /// Creating AVAudioEngine or AVAudioPlayerNode can fail in a process with no audio device.
    /// Keep stream inspection and narrator setup usable in headless contexts; construct the
    /// hardware-backed graph only when the first PCM chunk is ready to play.
    private func audioGraph() -> (AVAudioEngine, AVAudioPlayerNode) {
        if let engine, let player {
            return (engine, player)
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        self.engine = engine
        self.player = player
        return (engine, player)
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }
}

private final class AudioBufferDrainWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func install(_ continuation: CheckedContinuation<Bool, Never>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func resolve(_ result: Bool) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}
