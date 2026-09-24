import AVFoundation
import Foundation

@MainActor
final class StreamingSpeechPlayer {
    /// Keep a little audio ahead of the playhead without letting a fast producer
    /// queue an entire utterance that would be slow to interrupt.
    private static let maximumScheduledBuffers = 4

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var connectedFormat: AVAudioFormat?

    init() {}

    func play(
        _ stream: SpeechAudioStream,
        onFirstAudio: @MainActor @Sendable () -> Void
    ) async throws -> Bool {
        var didStart = false
        var pendingDrains: [AudioBufferDrainWaiter] = []

        do {
            for try await chunk in stream {
                try Task.checkCancellation()
                if !didStart {
                    try startOutput(format: chunk.audioBuffer.format)
                }

                // Scheduling only after the preceding buffer has played puts a
                // gap between every tiny Pocket TTS frame. Keep a bounded
                // window queued, then wait only when that window is full.
                if pendingDrains.count == Self.maximumScheduledBuffers {
                    guard await pendingDrains.removeFirst().wait(), !Task.isCancelled else {
                        stopImmediately()
                        return false
                    }
                }

                guard let player else {
                    stopImmediately()
                    return false
                }
                let drain = AudioBufferDrainWaiter(retaining: chunk.audioBuffer)
                player.scheduleBuffer(chunk.audioBuffer, completionCallbackType: .dataPlayedBack) { _ in
                    drain.resolve(true)
                }
                pendingDrains.append(drain)
                if !didStart {
                    didStart = true
                    onFirstAudio()
                }
            }

            // The producer may finish well before the audio device. A point is
            // complete only after the final scheduled buffer has played.
            for drain in pendingDrains {
                guard await drain.wait(), !Task.isCancelled else {
                    stopImmediately()
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
    /// AVAudioPlayerNode may still be reading this buffer after the stream
    /// iterator advances to another chunk.
    private let retainedBuffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    init(retaining buffer: AVAudioPCMBuffer) {
        retainedBuffer = buffer
    }

    func wait() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                install(continuation)
            }
        } onCancel: {
            resolve(false)
        }
    }

    private func install(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
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
