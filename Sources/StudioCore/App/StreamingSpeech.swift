import AVFoundation
import Foundation

/// An immutable snapshot of one generated PCM buffer. The backing AVFoundation buffer is copied
/// before it crosses the synthesizer callback boundary, where the system may reuse its storage.
public struct SpeechPCMChunk: @unchecked Sendable {
    public let sampleRate: Double
    public let channelCount: AVAudioChannelCount
    public let frameLength: AVAudioFrameCount
    public let audioBuffer: AVAudioPCMBuffer

    public init(copying source: AVAudioPCMBuffer) throws {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else {
            throw StreamingSpeechError.invalidPCMBuffer
        }

        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: source.audioBufferList)
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else {
            throw StreamingSpeechError.invalidPCMBuffer
        }

        for index in sourceBuffers.indices {
            let sourceAudio = sourceBuffers[index]
            let destinationAudio = destinationBuffers[index]
            guard let sourceData = sourceAudio.mData,
                  let destinationData = destinationAudio.mData,
                  sourceAudio.mDataByteSize <= destinationAudio.mDataByteSize else {
                throw StreamingSpeechError.invalidPCMBuffer
            }

            memcpy(destinationData, sourceData, Int(sourceAudio.mDataByteSize))
            destinationBuffers[index].mDataByteSize = sourceAudio.mDataByteSize
        }

        sampleRate = copy.format.sampleRate
        channelCount = copy.format.channelCount
        frameLength = copy.frameLength
        audioBuffer = copy
    }
}

/// A single-consumer, bounded stream of PCM chunks. A slow audio sink applies backpressure to the
/// synthesizer callback instead of allowing generated audio to grow without limit in memory.
public struct SpeechAudioStream: AsyncSequence, Sendable {
    public typealias Element = SpeechPCMChunk

    private let channel: SpeechPCMChunkChannel
    private let cancellationHandler: @Sendable () -> Void

    init(
        channel: SpeechPCMChunkChannel,
        onCancel: @escaping @Sendable () -> Void = {}
    ) {
        self.channel = channel
        cancellationHandler = onCancel
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(channel: channel, cancellationHandler: cancellationHandler)
    }

    public func cancel() {
        channel.cancel()
        cancellationHandler()
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let channel: SpeechPCMChunkChannel
        private let cancellationHandler: @Sendable () -> Void

        fileprivate init(
            channel: SpeechPCMChunkChannel,
            cancellationHandler: @escaping @Sendable () -> Void
        ) {
            self.channel = channel
            self.cancellationHandler = cancellationHandler
        }

        public mutating func next() async throws -> SpeechPCMChunk? {
            try await channel.next(onCancel: cancellationHandler)
        }
    }
}

/// Public bounded producer for local worker adapters outside this source file. A provider pushes
/// copied PCM chunks from its synthesis callback and returns `stream` to the audio player.
public final class SpeechAudioStreamProducer: @unchecked Sendable {
    private let channel: SpeechPCMChunkChannel
    private let cancellationHandler: @Sendable () -> Void

    public init(
        capacity: Int = 2,
        onCancel: @escaping @Sendable () -> Void = {}
    ) {
        channel = SpeechPCMChunkChannel(capacity: capacity)
        cancellationHandler = onCancel
    }

    public var stream: SpeechAudioStream {
        SpeechAudioStream(channel: channel, onCancel: cancellationHandler)
    }

    @discardableResult
    public func yield(_ chunk: SpeechPCMChunk) -> Bool {
        channel.push(chunk)
    }

    public func finish() {
        channel.finish()
    }

    public func finish(throwing error: any Error) {
        channel.finish(throwing: error)
    }
}

/// Provider boundary used by the narrator and future presentation scheduler. Implementations
/// keep their model or system synthesizer alive between points and expose cancellable PCM streams.
@MainActor
public protocol StreamingSpeechProvider: AnyObject {
    var identifier: String { get }
    var displayName: String { get }
    var isAvailable: Bool { get }

    func prepare() async throws
    func makeStream(for text: String) throws -> SpeechAudioStream
    func cancel()
    func pause()
    func resume()
}

public enum StreamingSpeechError: LocalizedError, Sendable, Equatable {
    case unavailable(String)
    case invalidPCMBuffer
    case concurrentStreamsUnsupported
    case outputStartFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            reason
        case .invalidPCMBuffer:
            "The speech provider returned an invalid PCM audio buffer."
        case .concurrentStreamsUnsupported:
            "This local speech provider supports one active narration stream."
        case .outputStartFailed(let reason):
            "Local speech audio could not start: \(reason)"
        }
    }
}

/// The default no-download provider. AVSpeechSynthesizer remains alive for the app lifetime and
/// writes local PCM chunks; stopping the stream stops synthesis as well as playback.
@MainActor
public final class SystemStreamingSpeechProvider: StreamingSpeechProvider {
    public let identifier = "macos-av-speech"

    private let synthesizer = AVSpeechSynthesizer()
    private var activeChannel: SpeechPCMChunkChannel?
    private var activeStreamID: UUID?

    public init() {}

    public var displayName: String {
        guard let voice else { return "macOS speech" }
        return "macOS speech (\(voice.name))"
    }

    public var isAvailable: Bool {
        voice != nil
    }

    private var voice: AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(language: "en-US")
            ?? AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix("en") }
    }

    public func prepare() async throws {
        guard isAvailable else {
            throw StreamingSpeechError.unavailable("No local English macOS speech voice is installed.")
        }
    }

    public func makeStream(for text: String) throws -> SpeechAudioStream {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            let channel = SpeechPCMChunkChannel(capacity: 2)
            channel.finish()
            return SpeechAudioStream(channel: channel)
        }
        guard let voice else {
            throw StreamingSpeechError.unavailable("No local English macOS speech voice is installed.")
        }

        cancel()
        let streamID = UUID()
        let channel = SpeechPCMChunkChannel(capacity: 2)
        activeChannel = channel
        activeStreamID = streamID

        let utterance = AVSpeechUtterance(string: value)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0

        synthesizer.write(utterance) { [weak self] audioBuffer in
            guard let pcmBuffer = audioBuffer as? AVAudioPCMBuffer else {
                channel.finish(throwing: StreamingSpeechError.invalidPCMBuffer)
                return
            }

            guard pcmBuffer.frameLength > 0 else {
                channel.finish()
                Task { @MainActor [weak self] in
                    guard let self, self.activeStreamID == streamID else { return }
                    self.activeChannel = nil
                    self.activeStreamID = nil
                }
                return
            }

            do {
                let chunk = try SpeechPCMChunk(copying: pcmBuffer)
                guard channel.push(chunk) else {
                    Task { @MainActor [weak self] in
                        guard let self, self.activeStreamID == streamID else { return }
                        self.synthesizer.stopSpeaking(at: .immediate)
                        self.activeChannel = nil
                        self.activeStreamID = nil
                    }
                    return
                }
            } catch {
                channel.finish(throwing: error)
                Task { @MainActor [weak self] in
                    guard let self, self.activeStreamID == streamID else { return }
                    self.synthesizer.stopSpeaking(at: .immediate)
                    self.activeChannel = nil
                    self.activeStreamID = nil
                }
            }
        }

        return SpeechAudioStream(channel: channel) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.activeStreamID == streamID else { return }
                self.cancel()
            }
        }
    }

    public func cancel() {
        activeChannel?.cancel()
        activeChannel = nil
        activeStreamID = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    public func pause() {
        _ = synthesizer.pauseSpeaking(at: .immediate)
    }

    public func resume() {
        _ = synthesizer.continueSpeaking()
    }
}

/// Thread-safe handoff between AVSpeechSynthesizer's callback and one async stream consumer.
final class SpeechPCMChunkChannel: @unchecked Sendable {
    private enum Terminal {
        case finished
        case cancelled
        case failed(any Error)
    }

    private let condition = NSCondition()
    private let capacity: Int
    private var chunks: [SpeechPCMChunk] = []
    private var terminal: Terminal?
    private var didTerminate = false
    private var waiter: CheckedContinuation<SpeechPCMChunk?, any Error>?

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func push(_ chunk: SpeechPCMChunk) -> Bool {
        condition.lock()
        while chunks.count >= capacity, waiter == nil, !didTerminate {
            condition.wait()
        }

        guard !didTerminate else {
            condition.unlock()
            return false
        }

        if let waiter {
            self.waiter = nil
            condition.unlock()
            waiter.resume(returning: chunk)
        } else {
            chunks.append(chunk)
            condition.unlock()
        }
        return true
    }

    func next(onCancel: @escaping @Sendable () -> Void) async throws -> SpeechPCMChunk? {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                condition.lock()
                if !chunks.isEmpty {
                    let chunk = chunks.removeFirst()
                    condition.broadcast()
                    condition.unlock()
                    continuation.resume(returning: chunk)
                    return
                }

                if let terminal {
                    condition.unlock()
                    resume(continuation, for: terminal)
                    return
                }

                guard waiter == nil else {
                    condition.unlock()
                    continuation.resume(throwing: StreamingSpeechError.concurrentStreamsUnsupported)
                    return
                }

                waiter = continuation
                condition.unlock()
            }
        } onCancel: {
            self.cancel()
            onCancel()
        }
    }

    func finish() {
        finish(with: .finished)
    }

    func finish(throwing error: any Error) {
        finish(with: .failed(error))
    }

    func cancel() {
        condition.lock()
        chunks.removeAll(keepingCapacity: false)
        let pending = waiter
        waiter = nil
        didTerminate = true
        terminal = .cancelled
        condition.broadcast()
        condition.unlock()
        pending?.resume(throwing: CancellationError())
    }

    private func finish(with value: Terminal) {
        condition.lock()
        guard !didTerminate else {
            condition.unlock()
            return
        }
        didTerminate = true
        terminal = value
        let pending = chunks.isEmpty ? waiter : nil
        if pending != nil { waiter = nil }
        condition.broadcast()
        condition.unlock()
        if let pending {
            resume(pending, for: value)
        }
    }

    private func resume(
        _ continuation: CheckedContinuation<SpeechPCMChunk?, any Error>,
        for terminal: Terminal
    ) {
        switch terminal {
        case .finished:
            continuation.resume(returning: nil)
        case .cancelled:
            continuation.resume(throwing: CancellationError())
        case .failed(let error):
            continuation.resume(throwing: error)
        }
    }
}
