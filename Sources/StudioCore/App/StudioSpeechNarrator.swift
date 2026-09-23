import Foundation

/// Application-owned speech lifecycle. Pocket TTS is preferred only after its packaged worker
/// validates the local model and voice; the built-in provider remains the immediate fallback.
@MainActor
public final class StudioSpeechNarrator {
    private let systemProvider: SystemStreamingSpeechProvider
    private let injectedProvider: (any StreamingSpeechProvider)?
    private let preferredPocketProvider: PocketTTSStreamingSpeechProvider?
    private var provider: any StreamingSpeechProvider
    private let player = StreamingSpeechPlayer()
    private var playbackTask: Task<Bool, Never>?
    private var activeSpeechID = UUID()
    private var isPaused = false
    private var statusHandler: (@MainActor @Sendable (SpeechPlaybackStatus) -> Void)?
    private var preparedTextKeys: Set<String> = []

    public init(provider: (any StreamingSpeechProvider)? = nil) {
        let systemProvider = SystemStreamingSpeechProvider()
        self.systemProvider = systemProvider
        if let provider {
            injectedProvider = provider
            preferredPocketProvider = nil
            self.provider = provider
        } else {
            injectedProvider = nil
            preferredPocketProvider = PocketTTSStreamingSpeechProvider()
            self.provider = systemProvider
        }
    }

    public var isSpeechAvailable: Bool {
        provider.isAvailable || (preferredPocketProvider?.isAvailable ?? false)
    }

    public var speechProviderName: String {
        provider.displayName
    }

    public var speechProviderIdentifier: String {
        provider.identifier
    }

    public var pocketTTSReadiness: PocketTTSRuntimeReadiness {
        PocketTTSRuntimeInspector.bundledDefault().inspect()
    }

    /// Exposes raw streamed PCM for the presentation scheduler without coupling it to this
    /// narrator's legacy prepare/play controls.
    public func streamAudio(for text: String) throws -> SpeechAudioStream {
        guard provider.isAvailable else {
            throw StreamingSpeechError.unavailable("No local speech provider is available.")
        }
        return try provider.makeStream(for: text)
    }

    /// There is no separate model install for the built-in provider. Keep the completion callback
    /// so the current UI can migrate independently to provider-aware setup messaging.
    public func install(
        status: @escaping @MainActor @Sendable (SpeechPlaybackStatus) -> Void,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        playbackTask?.cancel()
        provider.cancel()
        player.stopImmediately()
        status(.installing("Starting local speech"))

        Task { @MainActor [weak self] in
            do {
                guard let self else { return }
                try await self.preparePreferredProvider()
                status(.idle)
                completion(true)
            } catch {
                status(.failed(Self.message(for: error)))
                completion(false)
            }
        }
    }

    public func speak(
        _ text: String,
        status: @escaping @MainActor @Sendable (SpeechPlaybackStatus) -> Void
    ) {
        let key = Self.cacheKey(for: text)
        guard !key.isEmpty else {
            status(.idle)
            return
        }
        statusHandler = status
        let task = beginPlayback(for: key, status: status)
        playbackTask = task
    }

    /// Warms the chosen provider for later presentation points. Audio is generated just in time
    /// per point, keeping queued PCM bounded.
    public func prepare(
        _ texts: [String],
        status: @escaping @MainActor @Sendable (SpeechPlaybackStatus) -> Void
    ) async -> Bool {
        let keys = Self.orderedUniqueKeys(from: texts)
        guard !keys.isEmpty else {
            status(.idle)
            return true
        }

        guard isSpeechAvailable else {
            status(.failed("No local speech provider is available."))
            return false
        }

        status(.preparing("Starting local speech"))
        do {
            try await preparePreferredProvider()
            guard !Task.isCancelled else { return false }
            preparedTextKeys.formUnion(keys)
            status(.idle)
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            status(.failed(Self.message(for: error)))
            return false
        }
    }

    public func playPrepared(
        _ text: String,
        status: @escaping @MainActor @Sendable (SpeechPlaybackStatus) -> Void
    ) async -> Bool {
        let key = Self.cacheKey(for: text)
        guard !key.isEmpty else {
            status(.idle)
            return true
        }

        guard preparedTextKeys.contains(key) else {
            status(.failed("Audio was not prepared for this point."))
            return false
        }

        return await playStreamed(text, status: status)
    }

    /// Starts or replaces the current PCM stream and returns only after the output buffers drain.
    /// This is also the direct entry point for schedulers that do not use legacy story preparation.
    public func playStreamed(
        _ text: String,
        status: @escaping @MainActor @Sendable (SpeechPlaybackStatus) -> Void
    ) async -> Bool {
        let key = Self.cacheKey(for: text)
        guard !key.isEmpty else {
            status(.idle)
            return true
        }

        statusHandler = status
        let task = beginPlayback(for: key, status: status)
        let speechID = activeSpeechID
        playbackTask = task
        let didFinish = await task.value
        if activeSpeechID == speechID {
            playbackTask = nil
        }
        return didFinish
    }

    public func pause() {
        isPaused = true
        provider.pause()
        player.pause()
    }

    public func resume() {
        isPaused = false
        provider.resume()
        player.resume()
        if playbackTask != nil {
            statusHandler?(.speaking)
        }
    }

    public func stop() {
        activeSpeechID = UUID()
        playbackTask?.cancel()
        playbackTask = nil
        provider.cancel()
        player.stopImmediately()
        statusHandler?(.idle)
    }

    private func beginPlayback(
        for text: String,
        status: @escaping @MainActor @Sendable (SpeechPlaybackStatus) -> Void
    ) -> Task<Bool, Never> {
        activeSpeechID = UUID()
        let speechID = activeSpeechID
        playbackTask?.cancel()
        provider.cancel()
        player.stopImmediately()

        guard !isPaused else {
            status(.idle)
            return Task { false }
        }

        status(.generating)
        let player = self.player
        return Task { @MainActor [weak self] in
            do {
                guard let self else { return false }
                try await self.preparePreferredProvider()
                guard !Task.isCancelled,
                      !self.isPaused,
                      self.activeSpeechID == speechID else { return false }
                let provider = self.provider
                let stream = try provider.makeStream(for: text)
                let didFinish = try await player.play(stream) { [weak self] in
                    guard let self, self.activeSpeechID == speechID else { return }
                    status(.speaking)
                }
                guard self.activeSpeechID == speechID else { return false }
                status(.idle)
                return didFinish
            } catch is CancellationError {
                return false
            } catch {
                guard let self, self.activeSpeechID == speechID else { return false }
                status(.failed(Self.message(for: error)))
                return false
            }
        }
    }

    /// Keep macOS speech available immediately. Pocket TTS is promoted only after the bundled
    /// runtime and downloaded files pass the worker's real model and preset startup handshake.
    private func preparePreferredProvider() async throws {
        if let injectedProvider {
            provider = injectedProvider
            try await injectedProvider.prepare()
            return
        }

        if let pocket = preferredPocketProvider, pocket.isAvailable {
            do {
                try await pocket.prepare()
                provider = pocket
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                provider = systemProvider
                try await systemProvider.prepare()
                return
            }
        }

        provider = systemProvider
        try await systemProvider.prepare()
    }

    private static func orderedUniqueKeys(from texts: [String]) -> [String] {
        var seen: Set<String> = []
        return texts.compactMap { text in
            let key = cacheKey(for: text)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return key
        }
    }

    private static func cacheKey(for text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func message(for error: any Error) -> String {
        if let localized = error as? LocalizedError,
           let message = localized.errorDescription {
            return message
        }
        return error.localizedDescription
    }
}

/// Source-compatibility while presentation call sites migrate to the neutral application API.
@available(*, deprecated, renamed: "StudioSpeechNarrator")
public typealias StorySpeechNarrator = StudioSpeechNarrator
