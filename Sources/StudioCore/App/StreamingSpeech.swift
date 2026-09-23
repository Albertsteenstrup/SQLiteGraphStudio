import AVFoundation
import Foundation
import Darwin

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
    case speechSpoolLimitExceeded
    case speechSpoolFailure(String)
    case speechSpoolCorrupt

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
        case .speechSpoolLimitExceeded:
            "This narration exceeded the local speech spool limit. Shorten the narration or play it in smaller parts."
        case .speechSpoolFailure(let reason):
            "Local speech audio could not be buffered: \(reason)"
        case .speechSpoolCorrupt:
            "Local speech audio could not be read from its temporary buffer."
        }
    }
}

/// The default no-download provider. AVSpeechSynthesizer remains alive for the app lifetime and
/// writes local PCM chunks; stopping the stream stops synthesis as well as playback.
@MainActor
public final class SystemStreamingSpeechProvider: StreamingSpeechProvider {
    public let identifier = "macos-av-speech"

    private let synthesizer = AVSpeechSynthesizer()
    private var activeSpool: SpeechPCMChunkSpool?
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
        let spool = try SpeechPCMChunkSpool(channel: channel)
        activeSpool = spool
        activeStreamID = streamID

        let utterance = AVSpeechUtterance(string: value)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0

        synthesizer.write(utterance) { [weak self] audioBuffer in
            guard let pcmBuffer = audioBuffer as? AVAudioPCMBuffer else {
                spool.finish(throwing: StreamingSpeechError.invalidPCMBuffer)
                return
            }

            guard pcmBuffer.frameLength > 0 else {
                spool.finish()
                Task { @MainActor [weak self] in
                    guard let self, self.activeStreamID == streamID else { return }
                    self.activeSpool = nil
                    self.activeStreamID = nil
                }
                return
            }

            do {
                try spool.append(pcmBuffer)
            } catch {
                spool.finish(throwing: error)
                Task { @MainActor [weak self] in
                    guard let self, self.activeStreamID == streamID else { return }
                    self.synthesizer.stopSpeaking(at: .immediate)
                    self.activeSpool = nil
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
        activeSpool?.cancel()
        activeSpool = nil
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

/// Disk-backed FIFO between AVSpeechSynthesizer's callback and the bounded PCM channel. The
/// callback commits one audio record to a temporary file; a worker reads records and applies normal
/// channel backpressure away from the UI thread. Only the current record, the reader's record, and
/// the channel's fixed capacity are retained in process memory.
final class SpeechPCMChunkSpool: @unchecked Sendable {
    private enum State {
        case open
        case finished
        case failed(any Error)
        case cancelled
    }

    private static let magic: UInt32 = 0x5350_4353
    private static let fixedHeaderSize = 40
    private static let defaultMaximumBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024

    private let condition = NSCondition()
    private let channel: SpeechPCMChunkChannel
    private let fileDescriptor: Int32
    private let maximumBytes: UInt64
    private let workerQueue = DispatchQueue(label: "com.sqlitegraphstudio.speech-pcm-spool", qos: .userInitiated)

    private var state: State = .open
    private var writeOffset: Int64 = 0
    private var readOffset: Int64 = 0

    init(channel: SpeechPCMChunkChannel, maximumBytes: UInt64 = defaultMaximumBytes) throws {
        var template = Array((FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteGraphStudio-speech-XXXXXX").path + "\0").utf8)
        let descriptor = template.withUnsafeMutableBufferPointer { buffer in
            mkstemp(buffer.baseAddress!)
        }
        guard descriptor >= 0 else {
            throw StreamingSpeechError.speechSpoolFailure(String(cString: strerror(errno)))
        }
        let temporaryPath = String(decoding: template.prefix { $0 != 0 }, as: UTF8.self)
        guard Darwin.unlink(temporaryPath) == 0 else {
            let reason = String(cString: strerror(errno))
            _ = Darwin.close(descriptor)
            throw StreamingSpeechError.speechSpoolFailure(reason)
        }

        self.channel = channel
        fileDescriptor = descriptor
        self.maximumBytes = maximumBytes
        workerQueue.async { [self] in drainToChannel() }
    }

    deinit {
        _ = Darwin.close(fileDescriptor)
    }

    /// Serializes the callback buffer without waiting for playback or channel capacity.
    func append(_ source: AVAudioPCMBuffer) throws {
        let record = try encode(source)
        condition.lock()
        guard case .open = state else {
            condition.unlock()
            throw StreamingSpeechError.speechSpoolFailure("The speech stream has already ended.")
        }

        let nextOffset = UInt64(writeOffset) + UInt64(record.count)
        guard nextOffset <= maximumBytes else {
            let error = StreamingSpeechError.speechSpoolLimitExceeded
            state = .failed(error)
            condition.broadcast()
            condition.unlock()
            throw error
        }

        do {
            try write(record, at: writeOffset)
            writeOffset += Int64(record.count)
            condition.broadcast()
            condition.unlock()
        } catch {
            state = .failed(error)
            condition.broadcast()
            condition.unlock()
            throw error
        }
    }

    func finish() {
        finish(with: nil)
    }

    func finish(throwing error: any Error) {
        finish(with: error)
    }

    func cancel() {
        condition.lock()
        state = .cancelled
        condition.broadcast()
        condition.unlock()
        channel.cancel()
    }

    private func finish(with error: (any Error)?) {
        condition.lock()
        guard case .open = state else {
            condition.unlock()
            return
        }
        state = error.map(State.failed) ?? .finished
        condition.broadcast()
        condition.unlock()
    }

    private func drainToChannel() {
        do {
            while let chunk = try readNext() {
                guard channel.push(chunk) else { return }
            }
            channel.finish()
        } catch {
            channel.finish(throwing: error)
        }
    }

    private func readNext() throws -> SpeechPCMChunk? {
        condition.lock()
        while readOffset >= writeOffset {
            switch state {
            case .open:
                condition.wait()
            case .finished:
                condition.unlock()
                return nil
            case .failed(let error):
                condition.unlock()
                throw error
            case .cancelled:
                condition.unlock()
                throw CancellationError()
            }
        }
        let recordOffset = readOffset
        let committedEnd = writeOffset
        condition.unlock()

        let chunk = try decode(at: recordOffset, committedEnd: committedEnd)
        condition.lock()
        readOffset = recordOffset + Int64(chunk.recordByteCount)
        condition.unlock()
        return chunk.value
    }

    private func encode(_ source: AVAudioPCMBuffer) throws -> Data {
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: source.audioBufferList)
        )
        guard !sourceBuffers.isEmpty else {
            throw StreamingSpeechError.invalidPCMBuffer
        }

        var byteSizes: [UInt32] = []
        var payloadSize = 0
        for buffer in sourceBuffers {
            guard buffer.mData != nil else {
                throw StreamingSpeechError.invalidPCMBuffer
            }
            byteSizes.append(buffer.mDataByteSize)
            payloadSize += Int(buffer.mDataByteSize)
        }

        var record = Data(capacity: Self.fixedHeaderSize + byteSizes.count * 4 + payloadSize)
        record.appendInteger(Self.magic)
        record.appendInteger(UInt64(0))
        record.appendInteger(source.format.sampleRate.bitPattern)
        record.appendInteger(UInt32(source.format.channelCount))
        record.appendInteger(UInt32(source.frameLength))
        record.appendInteger(UInt32(source.format.commonFormat.rawValue))
        record.appendInteger(source.format.isInterleaved ? UInt32(1) : UInt32(0))
        record.appendInteger(UInt32(sourceBuffers.count))
        byteSizes.forEach { record.appendInteger($0) }
        for buffer in sourceBuffers {
            guard let data = buffer.mData else {
                throw StreamingSpeechError.invalidPCMBuffer
            }
            record.append(contentsOf: UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: UInt8.self),
                count: Int(buffer.mDataByteSize)
            ))
        }

        let recordSize = UInt64(record.count)
        record.replaceSubrange(4..<12, with: withUnsafeBytes(of: recordSize.littleEndian) { Data($0) })
        return record
    }

    private func decode(at offset: Int64, committedEnd: Int64) throws -> (value: SpeechPCMChunk, recordByteCount: Int) {
        guard committedEnd - offset >= Int64(Self.fixedHeaderSize) else {
            throw StreamingSpeechError.speechSpoolCorrupt
        }
        var header = Data(count: Self.fixedHeaderSize)
        try read(&header, at: offset)
        var cursor = 0
        let magic = try header.readInteger(UInt32.self, at: &cursor)
        let recordLength = try header.readInteger(UInt64.self, at: &cursor)
        let sampleRateBits = try header.readInteger(UInt64.self, at: &cursor)
        let channelCount = try header.readInteger(UInt32.self, at: &cursor)
        let frameLength = try header.readInteger(UInt32.self, at: &cursor)
        let commonFormatValue = try header.readInteger(UInt32.self, at: &cursor)
        let interleaved = try header.readInteger(UInt32.self, at: &cursor) != 0
        let bufferCount = try header.readInteger(UInt32.self, at: &cursor)

        guard magic == Self.magic,
              recordLength >= UInt64(Self.fixedHeaderSize + Int(bufferCount) * 4),
              recordLength <= UInt64(committedEnd - offset),
              bufferCount > 0,
              bufferCount <= 64,
              let commonFormat = AVAudioCommonFormat(rawValue: UInt(commonFormatValue)),
              frameLength > 0,
              channelCount > 0 else {
            throw StreamingSpeechError.speechSpoolCorrupt
        }

        guard let format = AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: Double(bitPattern: sampleRateBits),
            channels: channelCount,
            interleaved: interleaved
        ), let audioBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            throw StreamingSpeechError.speechSpoolCorrupt
        }
        audioBuffer.frameLength = frameLength

        var sizeHeader = Data(count: Int(bufferCount) * 4)
        try read(&sizeHeader, at: offset + Int64(Self.fixedHeaderSize))
        var sizeCursor = 0
        var sizes: [UInt32] = []
        for _ in 0..<bufferCount {
            sizes.append(try sizeHeader.readInteger(UInt32.self, at: &sizeCursor))
        }

        let destinationBuffers = UnsafeMutableAudioBufferListPointer(audioBuffer.mutableAudioBufferList)
        guard destinationBuffers.count == sizes.count else {
            throw StreamingSpeechError.speechSpoolCorrupt
        }

        var payloadOffset = offset + Int64(Self.fixedHeaderSize + Int(bufferCount) * 4)
        for index in destinationBuffers.indices {
            let size = sizes[index]
            guard let destination = destinationBuffers[index].mData,
                  size <= destinationBuffers[index].mDataByteSize else {
                throw StreamingSpeechError.speechSpoolCorrupt
            }
            var bytes = Data(count: Int(size))
            try read(&bytes, at: payloadOffset)
            bytes.withUnsafeBytes { source in
                if let baseAddress = source.baseAddress {
                    memcpy(destination, baseAddress, Int(size))
                }
            }
            destinationBuffers[index].mDataByteSize = size
            payloadOffset += Int64(size)
        }

        guard UInt64(payloadOffset - offset) == recordLength else {
            throw StreamingSpeechError.speechSpoolCorrupt
        }
        return (try SpeechPCMChunk(copying: audioBuffer), Int(recordLength))
    }

    private func write(_ data: Data, at offset: Int64) throws {
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else {
                    throw StreamingSpeechError.invalidPCMBuffer
                }
                var completed = 0
                while completed < rawBuffer.count {
                    let count = Darwin.pwrite(
                        fileDescriptor,
                        baseAddress.advanced(by: completed),
                        rawBuffer.count - completed,
                        off_t(offset) + off_t(completed)
                    )
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        throw StreamingSpeechError.speechSpoolFailure(String(cString: strerror(errno)))
                    }
                    completed += count
                }
            }
        } catch let error as StreamingSpeechError {
            throw error
        } catch {
            throw StreamingSpeechError.speechSpoolFailure(error.localizedDescription)
        }
    }

    private func read(_ data: inout Data, at offset: Int64) throws {
        do {
            try data.withUnsafeMutableBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else {
                    throw StreamingSpeechError.speechSpoolCorrupt
                }
                var completed = 0
                while completed < rawBuffer.count {
                    let count = Darwin.pread(
                        fileDescriptor,
                        baseAddress.advanced(by: completed),
                        rawBuffer.count - completed,
                        off_t(offset) + off_t(completed)
                    )
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        throw StreamingSpeechError.speechSpoolCorrupt
                    }
                    completed += count
                }
            }
        } catch let error as StreamingSpeechError {
            throw error
        } catch {
            throw StreamingSpeechError.speechSpoolFailure(error.localizedDescription)
        }
    }
}

private extension Data {
    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func readInteger<T: FixedWidthInteger>(_ type: T.Type, at offset: inout Int) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset + size <= count else { throw StreamingSpeechError.speechSpoolCorrupt }
        let value = withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
        offset += size
        return T(littleEndian: value)
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
