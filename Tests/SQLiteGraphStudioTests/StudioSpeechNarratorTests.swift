import AVFoundation
import Foundation
import Testing
@testable import StudioCore

struct StudioSpeechNarratorTests {
    @Test
    func pcmStreamDeliversQueuedChunksBeforeCompletion() async throws {
        let channel = SpeechPCMChunkChannel(capacity: 2)
        let stream = SpeechAudioStream(channel: channel)
        let original = try makePCMBuffer(value: 123)
        let expected = try SpeechPCMChunk(copying: original)
        UnsafeMutableAudioBufferListPointer(original.mutableAudioBufferList)[0]
            .mData!.storeBytes(of: Int16(9), as: Int16.self)

        #expect(channel.push(expected))
        channel.finish()

        var iterator = stream.makeAsyncIterator()
        let received = try await iterator.next()
        #expect(received?.sampleRate == 16_000)
        #expect(received?.channelCount == 1)
        #expect(received?.frameLength == 1)
        let receivedValue = received.map {
            UnsafeMutableAudioBufferListPointer($0.audioBuffer.mutableAudioBufferList)[0]
                .mData!.load(as: Int16.self)
        }
        #expect(receivedValue == 123)
        #expect(try await iterator.next() == nil)
    }

    @Test
    func cancellingStreamUnblocksBackpressuredProducer() async throws {
        let channel = SpeechPCMChunkChannel(capacity: 1)
        let chunk = try SpeechPCMChunk(copying: makePCMBuffer(value: 7))
        #expect(channel.push(chunk))

        let producer = Task.detached {
            channel.push(chunk)
        }
        await Task.yield()
        channel.cancel()

        #expect(await producer.value == false)
        var iterator = SpeechAudioStream(channel: channel).makeAsyncIterator()
        await #expect(throws: CancellationError.self) {
            try await iterator.next()
        }
    }

    @Test
    func diskSpoolStreamsAFullFastUtteranceInFIFOOrder() async throws {
        let channel = SpeechPCMChunkChannel(capacity: 1)
        let spool = try SpeechPCMChunkSpool(channel: channel, maximumBytes: 1_000_000)
        let chunkCount: Int16 = 200
        for value in 0..<chunkCount {
            try spool.append(makePCMBuffer(value: value))
        }
        spool.finish()

        var iterator = SpeechAudioStream(channel: channel).makeAsyncIterator()
        for expected in 0..<chunkCount {
            #expect(try await pcmValue(from: iterator.next()) == expected)
        }
        #expect(try await iterator.next() == nil)
    }

    @Test
    func diskSpoolDeliversCommittedAudioBeforeARealSizeLimitError() async throws {
        let channel = SpeechPCMChunkChannel(capacity: 1)
        let spool = try SpeechPCMChunkSpool(channel: channel, maximumBytes: 64)
        try spool.append(makePCMBuffer(value: 11))
        do {
            try spool.append(makePCMBuffer(value: 12))
            Issue.record("Expected the spool size limit to stop additional audio.")
        } catch let error as StreamingSpeechError {
            #expect(error == .speechSpoolLimitExceeded)
        }

        var iterator = SpeechAudioStream(channel: channel).makeAsyncIterator()
        #expect(try await pcmValue(from: iterator.next()) == 11)
        do {
            _ = try await iterator.next()
            Issue.record("Expected the spool error after all previously committed audio.")
        } catch let error as StreamingSpeechError {
            #expect(error == .speechSpoolLimitExceeded)
        }
    }

    @Test
    func diskSpoolPreservesPlanarFloatAudioFormatAndSamples() async throws {
        let channel = SpeechPCMChunkChannel(capacity: 1)
        let spool = try SpeechPCMChunkSpool(channel: channel)
        try spool.append(makePlanarStereoFloatBuffer(left: 0.25, right: -0.75))
        spool.finish()

        var iterator = SpeechAudioStream(channel: channel).makeAsyncIterator()
        let chunk = try await iterator.next()
        #expect(chunk?.sampleRate == 44_100)
        #expect(chunk?.channelCount == 2)
        #expect(chunk?.frameLength == 1)
        #expect(chunk?.audioBuffer.format.commonFormat == .pcmFormatFloat32)
        let buffers = chunk.map {
            UnsafeMutableAudioBufferListPointer($0.audioBuffer.mutableAudioBufferList)
        }
        #expect(buffers?.count == 2)
        #expect(buffers?.first?.mData?.load(as: Float.self) == 0.25)
        #expect(buffers?.last?.mData?.load(as: Float.self) == -0.75)
        #expect(try await iterator.next() == nil)
    }

    @Test
    func cancellingDiskSpoolWakesAWorkerBlockedOnTheBoundedChannel() async throws {
        let channel = SpeechPCMChunkChannel(capacity: 1)
        let spool = try SpeechPCMChunkSpool(channel: channel)
        let first = try SpeechPCMChunk(copying: makePCMBuffer(value: 1))
        #expect(channel.push(first))
        try spool.append(makePCMBuffer(value: 2))
        try spool.append(makePCMBuffer(value: 3))
        spool.cancel()

        var iterator = SpeechAudioStream(channel: channel).makeAsyncIterator()
        await #expect(throws: CancellationError.self) {
            try await iterator.next()
        }
    }

    @Test @MainActor
    func narratorExposesInjectedProviderStreamToScheduler() async throws {
        let provider = TestStreamingSpeechProvider()
        let narrator = StudioSpeechNarrator(provider: provider)
        let stream = try narrator.streamAudio(for: "hello")

        var iterator = stream.makeAsyncIterator()
        let chunk = try await iterator.next()
        #expect(chunk?.frameLength == 1)
        #expect(try await iterator.next() == nil)
        #expect(narrator.speechProviderIdentifier == "test")
    }

    @Test @MainActor
    func pausingDuringProviderPreparationPreventsAudioFromStarting() async {
        let provider = DelayedPrepareSpeechProvider()
        let narrator = StudioSpeechNarrator(provider: provider)
        let playback = Task { await narrator.playStreamed("wait for me", status: { _ in }) }

        while !provider.prepareStarted { await Task.yield() }
        narrator.pause()
        provider.finishPreparation()

        #expect(await playback.value == false)
        #expect(provider.streamRequestCount == 0)
    }

    @Test
    func pocketPresetPinsOnlyNongatedEnglishAssets() {
        #expect(PocketTTSSpeechAssets.packageVersion == "3.1.0")
        #expect(PocketTTSSpeechAssets.modelVariant == "english_2026-09")
        #expect(PocketTTSSpeechAssets.modelRepository == "kyutai/pocket-tts-without-voice-cloning")
        #expect(PocketTTSSpeechAssets.modelRevision == "e7205b6ee50e654a5ea19f0e9df2b0813b05e921")
        #expect(PocketTTSSpeechAssets.tokenizerRevision == "e7205b6ee50e654a5ea19f0e9df2b0813b05e921")
        #expect(PocketTTSSpeechAssets.presetVoice == "alba")
        #expect(PocketTTSSpeechAssets.license == "CC BY 4.0")
        #expect(PocketTTSSpeechAssets.assets.count == 4)
        #expect(PocketTTSSpeechAssets.assets.allSatisfy { !$0.id.contains("@main") })
        #expect(PocketTTSSpeechAssets.assets.filter { $0.id.contains("config") }.allSatisfy {
            $0.downloadURL.host == "raw.githubusercontent.com"
                && $0.downloadURL.path.contains(PocketTTSSpeechAssets.upstreamRevision)
        })
        #expect(PocketTTSSpeechAssets.assets.filter { !$0.id.contains("config") }.allSatisfy {
            $0.downloadURL.host == "huggingface.co"
                && $0.downloadURL.path.contains(PocketTTSSpeechAssets.modelRepository)
        })
        #expect(PocketTTSSpeechAssets.assets.contains {
            $0.relativePath == "languages/english_2026-09/embeddings/alba.safetensors"
                && $0.expectedByteCount == 6_195_000
                && $0.sha256 == "d291428b416d6c36a1de7835e51dbe1e334b75e5af512bb18dd23a1047fe8f3b"
        })
        #expect(PocketTTSSpeechAssets.assets.contains {
            $0.relativePath == "languages/english_2026-09/model.safetensors"
                && $0.expectedByteCount == 219_029_196
                && $0.sha256 == "916ccd2686e9311cb40054893a3c4284393d658825ffc714a276f3e9b152344f"
        })
        #expect(PocketTTSSpeechAssets.assets.contains {
            $0.relativePath == "languages/english_2026-09/tokenizer.model"
                && $0.expectedByteCount == 59_339
                && $0.sha256 == "d461765ae179566678c93091c5fa6f2984c31bbe990bf1aa62d92c64d91bc3f6"
        })
        #expect(!PocketTTSSpeechAssets.assets.contains {
            $0.downloadURL.absoluteString.contains("huggingface.co/kyutai/pocket-tts/")
        })
        #expect(PocketTTSSpeechAssets.assets.contains {
            $0.relativePath == "config/english_2026-09.yaml"
                && $0.expectedByteCount == 1_710
                && $0.sha256 == PocketTTSSpeechAssets.upstreamConfigurationSHA256
        })
        #expect(PocketTTSSpeechAssets.combinedDownloadSizeBytes == 225_285_245)
        #expect(PocketTTSSpeechAssets.upstreamConfigurationSizeBytes == 1_710)
        #expect(PocketTTSSpeechAssets.upstreamConfigurationSHA256 == "c3f0f611f4c9db070b9fcb7e5f757756d659fb8b2c8c074669f7a0bedb5d348a")
    }

    @Test
    func missingPocketRuntimeIsReportedWithoutUsingPathPython() {
        let root = URL(fileURLWithPath: "/nonexistent/SQLiteGraphStudio/PocketTTSRuntime", isDirectory: true)
        let inspector = PocketTTSRuntimeInspector(
            workerRoot: root,
            presetRoot: root.appendingPathComponent("assets", isDirectory: true)
        )

        guard case .runtimeNotPackaged(let missing) = inspector.inspect() else {
            Issue.record("Expected a missing managed runtime state.")
            return
        }

        #expect(missing.contains("python/bin/python3"))
        #expect(missing.contains("pocket_tts_worker.py"))
        #expect(missing.contains("requirements.lock"))
    }

    private func makePCMBuffer(value: Int16) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else {
            throw StreamingSpeechError.invalidPCMBuffer
        }

        buffer.frameLength = 1
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard let data = audioBuffers.first?.mData else {
            throw StreamingSpeechError.invalidPCMBuffer
        }
        data.storeBytes(of: value, as: Int16.self)
        return buffer
    }

    private func makePlanarStereoFloatBuffer(left: Float, right: Float) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else {
            throw StreamingSpeechError.invalidPCMBuffer
        }
        buffer.frameLength = 1
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard buffers.count == 2,
              let leftData = buffers[0].mData,
              let rightData = buffers[1].mData else {
            throw StreamingSpeechError.invalidPCMBuffer
        }
        leftData.storeBytes(of: left, as: Float.self)
        rightData.storeBytes(of: right, as: Float.self)
        return buffer
    }

    private func pcmValue(from chunk: SpeechPCMChunk?) -> Int16? {
        guard let chunk,
              let data = UnsafeMutableAudioBufferListPointer(chunk.audioBuffer.mutableAudioBufferList)
                .first?.mData else { return nil }
        return data.load(as: Int16.self)
    }
}

@MainActor
private final class TestStreamingSpeechProvider: StreamingSpeechProvider {
    let identifier = "test"
    let displayName = "Test speech"
    let isAvailable = true

    func prepare() async throws {}

    func makeStream(for text: String) throws -> SpeechAudioStream {
        let producer = SpeechAudioStreamProducer(capacity: 1)
        let buffer = try makeTestPCMBuffer()
        producer.yield(try SpeechPCMChunk(copying: buffer))
        producer.finish()
        return producer.stream
    }

    func cancel() {}
    func pause() {}
    func resume() {}

    private func makeTestPCMBuffer() throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else {
            throw StreamingSpeechError.invalidPCMBuffer
        }
        buffer.frameLength = 1
        return buffer
    }
}

@MainActor
private final class DelayedPrepareSpeechProvider: StreamingSpeechProvider {
    let identifier = "delayed-test"
    let displayName = "Delayed test"
    let isAvailable = true
    private(set) var prepareStarted = false
    private(set) var streamRequestCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func prepare() async throws {
        prepareStarted = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finishPreparation() {
        continuation?.resume()
        continuation = nil
    }

    func makeStream(for text: String) throws -> SpeechAudioStream {
        streamRequestCount += 1
        let producer = SpeechAudioStreamProducer(capacity: 1)
        producer.finish()
        return producer.stream
    }

    func cancel() {}
    func pause() {}
    func resume() {}
}
