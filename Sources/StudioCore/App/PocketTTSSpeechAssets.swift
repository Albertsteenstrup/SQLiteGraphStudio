import Foundation

/// Pinned metadata for the first Pocket TTS route. Kyutai's official 2026-09 config at
/// `upstreamRevision` selects the 3.1.0 tokenizer implementation and points at the 2026-09
/// weights and paired SentencePiece tokenizer model in `modelRevision`. The English
/// model and Alba preset are from the nongated `without-voice-cloning` repository. The official
/// HF model card at `licenseURL` declares CC BY 4.0. Model/voice SHA-256 and byte counts below
/// match the Hugging Face file metadata at the pinned revisions. The September tokenizer JSON
/// has the same 4,000-piece order and scores as the paired SentencePiece model. The config's
/// optional voice-cloning weight path points to a separate
/// gated repo, so it is provenance only and is never included in the app's download manifest.
/// No files are fetched by this manifest.
public enum PocketTTSSpeechAssets {
    public static let packageID = "pocket-tts-english-2026-09-alba"
    public static let upstreamRepository = "https://github.com/kyutai-labs/pocket-tts"
    public static let upstreamRevision = "0acce6b2f390150267557770d2098c5caa9a18ac"
    public static let packageVersion = "3.1.0"
    public static let upstreamConfigurationPath = "pocket_tts/config/english_2026-09.yaml"
    public static let upstreamConfigurationURL = URL(
        string: "https://raw.githubusercontent.com/kyutai-labs/pocket-tts/\(upstreamRevision)/\(upstreamConfigurationPath)"
    )!
    public static let upstreamConfigurationSizeBytes: Int64 = 1_710
    public static let upstreamConfigurationSHA256 = "c3f0f611f4c9db070b9fcb7e5f757756d659fb8b2c8c074669f7a0bedb5d348a"

    public static let modelRepository = "kyutai/pocket-tts-without-voice-cloning"
    public static let modelRevision = "e7205b6ee50e654a5ea19f0e9df2b0813b05e921"
    public static let tokenizerRevision = modelRevision
    public static let license = "CC BY 4.0"
    public static let licenseURL = URL(
        string: "https://huggingface.co/kyutai/pocket-tts-without-voice-cloning/blob/\(modelRevision)/README.md"
    )!
    public static let presetVoice = "alba"
    public static let modelVariant = "english_2026-09"

    public struct Asset: Sendable, Equatable, Identifiable {
        public let id: String
        public let relativePath: String
        public let downloadURL: URL
        public let expectedByteCount: Int64
        public let sha256: String
        public let sourceRevision: String

        public init(
            id: String,
            relativePath: String,
            downloadURL: URL,
            expectedByteCount: Int64,
            sha256: String,
            sourceRevision: String
        ) {
            self.id = id
            self.relativePath = relativePath
            self.downloadURL = downloadURL
            self.expectedByteCount = expectedByteCount
            self.sha256 = sha256
            self.sourceRevision = sourceRevision
        }
    }

    /// These byte counts and SHA-256 values are from the upstream config and verified Hugging
    /// Face file metadata/pointers. The folder layout matches the official English 2026-09 config.
    public static let assets: [Asset] = [
        Asset(
            id: "pocket-tts-english-2026-09-config",
            relativePath: "config/english_2026-09.yaml",
            downloadURL: upstreamConfigurationURL,
            expectedByteCount: upstreamConfigurationSizeBytes,
            sha256: upstreamConfigurationSHA256,
            sourceRevision: upstreamRevision
        ),
        Asset(
            id: "pocket-tts-english-2026-09-model",
            relativePath: "languages/english_2026-09/model.safetensors",
            downloadURL: URL(
                string: "https://huggingface.co/\(modelRepository)/resolve/\(modelRevision)/languages/english_2026-09/model.safetensors"
            )!,
            expectedByteCount: 219_029_196,
            sha256: "916ccd2686e9311cb40054893a3c4284393d658825ffc714a276f3e9b152344f",
            sourceRevision: modelRevision
        ),
        Asset(
            id: "pocket-tts-english-2026-09-tokenizer-model",
            relativePath: "languages/english_2026-09/tokenizer.model",
            downloadURL: URL(
                string: "https://huggingface.co/\(modelRepository)/resolve/\(tokenizerRevision)/tokenizer.model"
            )!,
            expectedByteCount: 59_339,
            sha256: "d461765ae179566678c93091c5fa6f2984c31bbe990bf1aa62d92c64d91bc3f6",
            sourceRevision: tokenizerRevision
        ),
        Asset(
            id: "pocket-tts-english-2026-09-alba",
            relativePath: "languages/english_2026-09/embeddings/alba.safetensors",
            downloadURL: URL(
                string: "https://huggingface.co/\(modelRepository)/resolve/\(modelRevision)/languages/english_2026-09/embeddings/alba.safetensors"
            )!,
            expectedByteCount: 6_195_000,
            sha256: "d291428b416d6c36a1de7835e51dbe1e334b75e5af512bb18dd23a1047fe8f3b",
            sourceRevision: modelRevision
        ),
    ]

    public static let combinedDownloadSizeBytes: Int64 = assets.reduce(0) {
        $0 + $1.expectedByteCount
    }
}

public enum PocketTTSRuntimeReadiness: Sendable, Equatable {
    case runtimeNotPackaged(missing: [String])
    case presetAssetsMissing([String])
    case workerAdapterUnavailable
    case ready

    public var canUsePocketTTS: Bool {
        if case .ready = self { return true }
        return false
    }

    /// Downloads are offered only when the complete managed runtime/provider is present and the
    /// pinned model files are the remaining setup step.
    public var canDownloadMissingAssets: Bool {
        if case .presetAssetsMissing = self { return true }
        return false
    }

    public var explanation: String {
        switch self {
        case .runtimeNotPackaged(let missing):
            let list = missing.joined(separator: ", ")
            return "Pocket TTS is unavailable because this build is missing its managed runtime (\(list)). The built-in macOS voice remains available; no model or Python setup has been installed."
        case .presetAssetsMissing(let assets):
            let list = assets.joined(separator: ", ")
            return "The managed Pocket TTS runtime and streaming provider are present, but pinned English 2026-09 assets are missing (\(list)). You can download the verified nongated preset files in the app."
        case .workerAdapterUnavailable:
            return "Pocket TTS files are present, but its local worker has not completed a model startup check in this session. The built-in macOS voice remains available."
        case .ready:
            return "Pocket TTS is ready with the pinned English 2026-09 preset voice."
        }
    }
}

/// Checks for a complete app-managed worker before selecting Pocket TTS. A Python interpreter on
/// PATH is deliberately ignored so the delivered app never depends on terminal setup.
public struct PocketTTSRuntimeInspector: Sendable {
    public let workerRoot: URL
    public let presetRoot: URL
    private let pocketTTSProviderAvailable: Bool

    public init(workerRoot: URL, presetRoot: URL) {
        self.workerRoot = workerRoot
        self.presetRoot = presetRoot
        pocketTTSProviderAvailable = false
    }

    /// Internal injection point for a build that contains the Swift adapter and a prepared runtime.
    /// The inspector still requires a process-local successful model handshake before `.ready`.
    init(
        workerRoot: URL,
        presetRoot: URL,
        pocketTTSProviderAvailable: Bool
    ) {
        self.workerRoot = workerRoot
        self.presetRoot = presetRoot
        self.pocketTTSProviderAvailable = pocketTTSProviderAvailable
    }

    public static func bundledDefault() -> Self {
        let resourceRoot = Bundle.main.resourceURL ?? URL(fileURLWithPath: "/")
        let supportRoot = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        return Self(
            workerRoot: Self.bundledRuntimeRoot(in: resourceRoot),
            presetRoot: supportRoot
                .appendingPathComponent("SQLiteGraphStudio/Speech/PocketTTS", isDirectory: true)
                .appendingPathComponent(PocketTTSSpeechAssets.modelRevision, isDirectory: true),
            pocketTTSProviderAvailable: true
        )
    }

    private static func bundledRuntimeRoot(in resourceRoot: URL) -> URL {
        let root = resourceRoot.appendingPathComponent("PocketTTSRuntime", isDirectory: true)
#if arch(arm64)
        let architecture = "arm64"
#elseif arch(x86_64)
        let architecture = "x86_64"
#else
        return root
#endif
        let architectureRoot = root.appendingPathComponent(architecture, isDirectory: true)
        let python = architectureRoot.appendingPathComponent("python/bin/python3")
        return FileManager.default.fileExists(atPath: python.path) ? architectureRoot : root
    }

    public func inspect() -> PocketTTSRuntimeReadiness {
        let requiredRuntimeFiles = [
            "python/bin/python3",
            "pocket_tts_worker.py",
            "requirements.lock",
        ]
        let missingRuntimeFiles = requiredRuntimeFiles.filter {
            !FileManager.default.fileExists(atPath: workerRoot.appendingPathComponent($0).path)
        }
        guard missingRuntimeFiles.isEmpty else {
            return .runtimeNotPackaged(missing: missingRuntimeFiles)
        }

        let missingAssets = PocketTTSSpeechAssets.assets.compactMap { asset in
            let file = presetRoot.appendingPathComponent(asset.relativePath)
            return FileManager.default.fileExists(atPath: file.path) ? nil : asset.relativePath
        }
        guard missingAssets.isEmpty else {
            return .presetAssetsMissing(missingAssets)
        }

        guard pocketTTSProviderAvailable,
              PocketTTSRuntimeHandshakeCache.shared.hasSucceeded(workerRoot: workerRoot) else {
            return .workerAdapterUnavailable
        }

        return .ready
    }
}

/// Readiness is marked only after the packaged process reports that the pinned model and voice
/// have loaded. A file-presence check alone never enables Pocket TTS as a speech provider.
final class PocketTTSRuntimeHandshakeCache: @unchecked Sendable {
    static let shared = PocketTTSRuntimeHandshakeCache()

    private let lock = NSLock()
    private var successfulRoots: Set<String> = []

    private init() {}

    func markSucceeded(workerRoot: URL) {
        lock.lock()
        successfulRoots.insert(workerRoot.standardizedFileURL.path)
        lock.unlock()
    }

    func markFailed(workerRoot: URL) {
        lock.lock()
        successfulRoots.remove(workerRoot.standardizedFileURL.path)
        lock.unlock()
    }

    func hasSucceeded(workerRoot: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return successfulRoots.contains(workerRoot.standardizedFileURL.path)
    }
}
