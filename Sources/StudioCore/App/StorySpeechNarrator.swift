import AppKit
import Foundation

@MainActor
public final class StorySpeechNarrator: NSObject, NSSoundDelegate {
    private var speechTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var currentSound: NSSound?
    private var currentAudioURL: URL?
    private var audioCache: [String: Data] = [:]
    private var activeSpeechID = UUID()
    private var isPaused = false
    private var statusHandler: (@MainActor @Sendable (StoryReadAloudStatus) -> Void)?
    private var playbackContinuation: CheckedContinuation<Bool, Never>?

    public override init() {
        super.init()
    }

    public var isKokoroInstalled: Bool {
        KokoroRuntime.isInstalled
    }

    public func install(
        status: @escaping @MainActor @Sendable (StoryReadAloudStatus) -> Void,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        installTask?.cancel()
        installTask = Task.detached(priority: .utility) {
            do {
                try KokoroRuntime.install { progress in
                    await status(.installing(progress))
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    status(.idle)
                    completion(true)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    status(.failed(KokoroRuntime.message(for: error)))
                    completion(false)
                }
            }
        }
    }

    public func speak(
        _ text: String,
        status: @escaping @MainActor @Sendable (StoryReadAloudStatus) -> Void
    ) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            status(.idle)
            return
        }

        statusHandler = status
        activeSpeechID = UUID()
        let speechID = activeSpeechID

        speechTask?.cancel()
        currentSound?.stop()
        currentSound = nil
        removeCurrentAudioFile()

        speechTask = Task.detached(priority: .utility) { [weak self] in
            guard KokoroRuntime.isInstalled else {
                await status(.installRequired)
                return
            }

            await status(.generating)

            do {
                let audioURL = try KokoroRuntime.generateSpeechAudio(for: trimmedText)
                guard !Task.isCancelled else { return }

                await MainActor.run { [weak self] in
                    guard let self, self.activeSpeechID == speechID else {
                        try? FileManager.default.removeItem(at: audioURL)
                        return
                    }

                    self.currentAudioURL = audioURL
                    guard let sound = NSSound(contentsOf: audioURL, byReference: false) else {
                        status(.failed("Kokoro audio could not be loaded."))
                        return
                    }

                    self.currentSound = sound
                    sound.delegate = self
                    guard !self.isPaused else {
                        status(.idle)
                        return
                    }

                    if sound.play() {
                        status(.speaking)
                    } else {
                        status(.failed("Kokoro audio could not be played."))
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard self?.activeSpeechID == speechID else { return }
                    status(.failed(KokoroRuntime.message(for: error)))
                }
            }
        }
    }

    public func prepare(
        _ texts: [String],
        status: @escaping @MainActor @Sendable (StoryReadAloudStatus) -> Void
    ) async -> Bool {
        let keys = orderedUniqueKeys(from: texts)
        guard !keys.isEmpty else {
            status(.idle)
            return true
        }

        guard KokoroRuntime.isInstalled else {
            status(.installRequired)
            return false
        }

        let missingKeys = keys.filter { audioCache[$0] == nil }
        guard !missingKeys.isEmpty else {
            status(.idle)
            return true
        }

        let concurrency = Self.preparationConcurrency(for: missingKeys.count)
        let chunkSize = max(1, Int(ceil(Double(missingKeys.count) / Double(concurrency))))
        let chunks = missingKeys.chunked(into: chunkSize)
        let totalCount = missingKeys.count
        var completedCount = 0

        do {
            try await withThrowingTaskGroup(of: [String: Data].self) { group in
                for chunk in chunks where !chunk.isEmpty {
                    group.addTask {
                        try await Task.detached(priority: .utility) {
                            try KokoroRuntime.generateSpeechAudioDataBatch(for: chunk)
                        }.value
                    }
                }

                for try await batch in group {
                    try Task.checkCancellation()
                    for (key, data) in batch {
                        audioCache[key] = data
                        completedCount += 1
                        status(.preparing("Preparing audio \(completedCount)/\(totalCount)"))
                    }
                }
            }
        } catch {
            guard !Task.isCancelled else { return false }
            status(.failed(KokoroRuntime.message(for: error)))
            return false
        }

        status(.idle)
        return true
    }

    /// Kokoro loads the full model per Python process; keep workers high but bounded by CPU and RAM.
    nonisolated static func preparationConcurrency(for itemCount: Int) -> Int {
        guard itemCount > 1 else { return 1 }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let memorySafeCap = max(1, min(cores, 6))
        return min(itemCount, memorySafeCap)
    }

    public func playPrepared(
        _ text: String,
        status: @escaping @MainActor @Sendable (StoryReadAloudStatus) -> Void
    ) async -> Bool {
        let key = cacheKey(for: text)
        guard !key.isEmpty else {
            status(.idle)
            return true
        }

        guard let data = audioCache[key] else {
            status(.failed("Audio was not prepared for this beat."))
            return false
        }

        statusHandler = status
        activeSpeechID = UUID()
        speechTask?.cancel()
        currentSound?.stop()
        currentSound = nil
        resumePlaybackContinuation(false)

        guard let sound = NSSound(data: data) else {
            status(.failed("Kokoro audio could not be loaded."))
            return false
        }

        currentSound = sound
        sound.delegate = self
        guard !isPaused else {
            status(.idle)
            return true
        }

        guard sound.play() else {
            status(.failed("Kokoro audio could not be played."))
            currentSound = nil
            return false
        }

        status(.speaking)
        return await withCheckedContinuation { continuation in
            playbackContinuation = continuation
        }
    }

    public func pause() {
        isPaused = true
        currentSound?.pause()
    }

    public func resume() {
        isPaused = false
        guard let currentSound else { return }
        if currentSound.isPlaying {
            return
        }
        if currentSound.resume() || currentSound.play() {
            statusHandler?(.speaking)
        }
    }

    public func stop() {
        installTask?.cancel()
        installTask = nil
        speechTask?.cancel()
        speechTask = nil
        currentSound?.stop()
        currentSound = nil
        resumePlaybackContinuation(false)
        removeCurrentAudioFile()
        statusHandler?(.idle)
    }

    public nonisolated func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        Task { @MainActor [weak self] in
            self?.finish(sound)
        }
    }

    private func finish(_ sound: NSSound) {
        guard currentSound === sound else { return }
        currentSound = nil
        removeCurrentAudioFile()
        statusHandler?(.idle)
        resumePlaybackContinuation(true)
    }

    private func removeCurrentAudioFile() {
        if let currentAudioURL {
            try? FileManager.default.removeItem(at: currentAudioURL)
        }
        currentAudioURL = nil
    }

    private func resumePlaybackContinuation(_ didFinish: Bool) {
        guard let playbackContinuation else { return }
        self.playbackContinuation = nil
        playbackContinuation.resume(returning: didFinish)
    }

    private func orderedUniqueKeys(from texts: [String]) -> [String] {
        var seen: Set<String> = []
        var keys: [String] = []
        for text in texts {
            let key = cacheKey(for: text)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            keys.append(key)
        }
        return keys
    }

    private func cacheKey(for text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}

private enum KokoroRuntime {
    private static let markerVersion = "kokoro>=0.9.4|voice=af_bella|lang=a|speed=0.82|py=3.10-3.12|v2"

    private struct PythonRuntime {
        let executableURL: URL
        let version: PythonVersion

        var venvDirectoryName: String {
            "venv-py\(version.major)\(version.minor)"
        }
    }

    private struct PythonVersion: Comparable, CustomStringConvertible {
        let major: Int
        let minor: Int
        let patch: Int

        var description: String {
            "\(major).\(minor).\(patch)"
        }

        static func < (lhs: PythonVersion, rhs: PythonVersion) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            return lhs.patch < rhs.patch
        }
    }

    static var isInstalled: Bool {
        guard let root = try? runtimeRoot() else { return false }
        guard let runtime = try? compatiblePythonRuntime() else { return false }
        let markerURL = root.appendingPathComponent("install.marker")
        return FileManager.default.fileExists(atPath: pythonURL(in: root, runtime: runtime).path)
            && (try? String(contentsOf: markerURL, encoding: .utf8)) == markerVersion
    }

    static func generateSpeechAudio(for text: String) throws -> URL {
        let root = try runtimeRoot()
        let runtime = try compatiblePythonRuntime()
        guard isInstalled else {
            throw KokoroRuntimeError.installRequired
        }
        let scriptURL = try writeGeneratorScript(in: root)

        let id = UUID().uuidString
        let inputURL = root.appendingPathComponent("input-\(id).txt")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-graph-studio-kokoro-\(id).wav")
        try text.write(to: inputURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: inputURL) }

        try run(
            executableURL: pythonURL(in: root, runtime: runtime),
            arguments: [
                scriptURL.path,
                "--input",
                inputURL.path,
                "--output",
                outputURL.path,
            ],
            environment: kokoroEnvironment(in: root),
            currentDirectoryURL: root
        )

        guard FileManager.default.fileExists(atPath: outputURL.path),
              ((try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
        else {
            throw KokoroRuntimeError.failed("Kokoro did not produce an audio file.")
        }
        return outputURL
    }

    static func generateSpeechAudioData(for text: String) throws -> Data {
        let audioURL = try generateSpeechAudio(for: text)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        return try Data(contentsOf: audioURL)
    }

    static func generateSpeechAudioDataBatch(for texts: [String]) throws -> [String: Data] {
        let keys = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !keys.isEmpty else { return [:] }
        if keys.count == 1, let onlyKey = keys.first {
            let audioURL = try generateSpeechAudio(for: onlyKey)
            defer { try? FileManager.default.removeItem(at: audioURL) }
            return [onlyKey: try Data(contentsOf: audioURL)]
        }

        let root = try runtimeRoot()
        let runtime = try compatiblePythonRuntime()
        guard isInstalled else {
            throw KokoroRuntimeError.installRequired
        }

        let batchID = UUID().uuidString
        let inputURL = root.appendingPathComponent("batch-input-\(batchID).json")
        let outputDirectory = root.appendingPathComponent("batch-output-\(batchID)", isDirectory: true)
        let scriptURL = try writeBatchGeneratorScript(in: root)

        var payload: [String: String] = [:]
        for (index, key) in keys.enumerated() {
            payload[String(index)] = key
        }

        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(payload).write(to: inputURL, options: .atomic)

        try run(
            executableURL: pythonURL(in: root, runtime: runtime),
            arguments: [
                scriptURL.path,
                "--input-json",
                inputURL.path,
                "--output-dir",
                outputDirectory.path,
            ],
            environment: kokoroEnvironment(in: root),
            currentDirectoryURL: root
        )

        let manifestURL = outputDirectory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw KokoroRuntimeError.failed("Kokoro batch did not produce a manifest.")
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode([String: String].self, from: manifestData)

        var results: [String: Data] = [:]
        results.reserveCapacity(keys.count)
        for (index, key) in keys.enumerated() {
            guard let fileName = manifest[String(index)] else {
                throw KokoroRuntimeError.failed("Kokoro batch missed audio for beat \(index + 1).")
            }
            let audioURL = outputDirectory.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                throw KokoroRuntimeError.failed("Kokoro batch audio file is missing for beat \(index + 1).")
            }
            results[key] = try Data(contentsOf: audioURL)
        }
        return results
    }

    static func message(for error: Error) -> String {
        if let runtimeError = error as? KokoroRuntimeError {
            return runtimeError.message
        }

        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return "Kokoro is unavailable." }
        return "Kokoro is unavailable: \(message)"
    }

    static func install(progress: @escaping @Sendable (String) async -> Void) throws {
        let root = try runtimeRoot()
        let runtime = try compatiblePythonRuntime()
        try ensureInstalled(in: root, runtime: runtime, progress: progress)
    }

    private static func runtimeRoot() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let root = base
            .appendingPathComponent("SQLiteGraphStudio", isDirectory: true)
            .appendingPathComponent("Kokoro-82M", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func ensureInstalled(
        in root: URL,
        runtime: PythonRuntime,
        progress: @escaping @Sendable (String) async -> Void
    ) throws {
        let venvURL = root.appendingPathComponent(runtime.venvDirectoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: pythonURL(in: root, runtime: runtime).path) {
            awaitProgress("Creating Python \(runtime.version.major).\(runtime.version.minor) environment", progress)
            try run(
                executableURL: runtime.executableURL,
                arguments: ["-m", "venv", venvURL.path],
                environment: [:],
                currentDirectoryURL: root,
                progress: progress
            )
        }

        let markerURL = root.appendingPathComponent("install.marker")
        if (try? String(contentsOf: markerURL, encoding: .utf8)) == markerVersion {
            awaitProgress("Kokoro is installed", progress)
            return
        }

        awaitProgress("Updating installer", progress)
        try run(
            executableURL: pythonURL(in: root, runtime: runtime),
            arguments: ["-m", "pip", "install", "--upgrade", "pip"],
            environment: kokoroEnvironment(in: root),
            currentDirectoryURL: root,
            progress: progress
        )
        awaitProgress("Downloading Kokoro and voices", progress)
        try run(
            executableURL: pythonURL(in: root, runtime: runtime),
            arguments: ["-m", "pip", "install", "kokoro>=0.9.4", "soundfile", "misaki[en]"],
            environment: kokoroEnvironment(in: root),
            currentDirectoryURL: root,
            progress: progress
        )

        awaitProgress("Downloading Kokoro model and Bella voice", progress)
        let scriptURL = try writeGeneratorScript(in: root)
        let warmupInputURL = root.appendingPathComponent("install-warmup.txt")
        let warmupOutputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-graph-studio-kokoro-install-\(UUID().uuidString).wav")
        try "Kokoro is ready.".write(to: warmupInputURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: warmupInputURL)
            try? FileManager.default.removeItem(at: warmupOutputURL)
        }
        try run(
            executableURL: pythonURL(in: root, runtime: runtime),
            arguments: [
                scriptURL.path,
                "--input",
                warmupInputURL.path,
                "--output",
                warmupOutputURL.path,
            ],
            environment: kokoroEnvironment(in: root),
            currentDirectoryURL: root,
            progress: progress
        )

        awaitProgress("Saving Kokoro install", progress)
        try markerVersion.write(to: markerURL, atomically: true, encoding: .utf8)
    }

    private static func awaitProgress(
        _ message: String,
        _ progress: @escaping @Sendable (String) async -> Void
    ) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await progress(message)
            semaphore.signal()
        }
        semaphore.wait()
    }

    private static func compatiblePythonRuntime() throws -> PythonRuntime {
        let lowerBound = PythonVersion(major: 3, minor: 10, patch: 0)
        let upperBound = PythonVersion(major: 3, minor: 13, patch: 0)
        var checked: [(URL, PythonVersion)] = []

        for candidate in pythonCandidates() {
            guard let version = pythonVersion(for: candidate) else { continue }
            checked.append((candidate, version))
            if version >= lowerBound && version < upperBound {
                return PythonRuntime(executableURL: candidate, version: version)
            }
        }

        let found = checked
            .map { "\($0.1) at \($0.0.path)" }
            .joined(separator: ", ")
        let suffix = found.isEmpty ? "No Python executable was found." : "Found: \(found)."
        throw KokoroRuntimeError.failed(
            "Kokoro needs Python 3.10, 3.11, or 3.12. \(suffix) Install python@3.12 or python@3.10, then try read aloud again."
        )
    }

    private static func pythonCandidates() -> [URL] {
        let fixedPaths = [
            "/opt/homebrew/bin/python3.12",
            "/usr/local/bin/python3.12",
            "/opt/local/bin/python3.12",
            "/opt/homebrew/bin/python3.11",
            "/usr/local/bin/python3.11",
            "/opt/local/bin/python3.11",
            "/opt/homebrew/bin/python3.10",
            "/usr/local/bin/python3.10",
            "/opt/local/bin/python3.10",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/opt/local/bin/python3",
            "/usr/bin/python3",
        ]

        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .flatMap { directory in
                [
                    "\(directory)/python3.12",
                    "\(directory)/python3.11",
                    "\(directory)/python3.10",
                    "\(directory)/python3",
                ]
            }

        var seen: Set<String> = []
        return (fixedPaths + pathCandidates).compactMap { path in
            guard FileManager.default.isExecutableFile(atPath: path), !seen.contains(path) else {
                return nil
            }
            seen.insert(path)
            return URL(fileURLWithPath: path)
        }
    }

    private static func pythonVersion(for executableURL: URL) -> PythonVersion? {
        guard let output = try? capture(
            executableURL: executableURL,
            arguments: ["--version"]
        ) else {
            return nil
        }

        let components = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .last?
            .split(separator: ".")
            .compactMap { Int($0) } ?? []

        guard components.count >= 2 else { return nil }
        return PythonVersion(
            major: components[0],
            minor: components[1],
            patch: components.count >= 3 ? components[2] : 0
        )
    }

    private static func pythonURL(in root: URL, runtime: PythonRuntime) -> URL {
        root.appendingPathComponent("\(runtime.venvDirectoryName)/bin/python")
    }

    private static func kokoroEnvironment(in root: URL) -> [String: String] {
        [
            "HF_HOME": root.appendingPathComponent("huggingface", isDirectory: true).path,
            "PYTHONUNBUFFERED": "1",
            "PYTORCH_ENABLE_MPS_FALLBACK": "1",
            "XDG_CACHE_HOME": root.appendingPathComponent("cache", isDirectory: true).path,
        ]
    }

    private static func writeGeneratorScript(in root: URL) throws -> URL {
        let scriptURL = root.appendingPathComponent("kokoro_generate.py")
        let script = """
        import argparse
        import pathlib

        import numpy as np
        import soundfile as sf
        from kokoro import KPipeline

        parser = argparse.ArgumentParser()
        parser.add_argument("--input", required=True)
        parser.add_argument("--output", required=True)
        args = parser.parse_args()

        text = pathlib.Path(args.input).read_text(encoding="utf-8").strip()
        if not text:
            raise SystemExit("No text supplied")

        pipeline = KPipeline(lang_code="a")
        generator = pipeline(text, voice="af_bella", speed=0.82, split_pattern=r"\\n+")
        chunks = [audio for _, _, audio in generator]
        if not chunks:
            raise SystemExit("Kokoro produced no audio")

        audio = np.concatenate(chunks) if len(chunks) > 1 else chunks[0]
        sf.write(args.output, audio, 24000)
        """

        if (try? String(contentsOf: scriptURL, encoding: .utf8)) != script {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        }
        return scriptURL
    }

    private static func writeBatchGeneratorScript(in root: URL) throws -> URL {
        let scriptURL = root.appendingPathComponent("kokoro_generate_batch.py")
        let script = """
        import argparse
        import json
        import pathlib

        import numpy as np
        import soundfile as sf
        from kokoro import KPipeline

        parser = argparse.ArgumentParser()
        parser.add_argument("--input-json", required=True)
        parser.add_argument("--output-dir", required=True)
        args = parser.parse_args()

        items = json.loads(pathlib.Path(args.input_json).read_text(encoding="utf-8"))
        if not items:
            raise SystemExit("No text supplied")

        output_dir = pathlib.Path(args.output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)

        pipeline = KPipeline(lang_code="a")
        manifest = {}

        for key in sorted(items, key=lambda value: int(value)):
            text = str(items[key]).strip()
            if not text:
                continue

            generator = pipeline(text, voice="af_bella", speed=0.82, split_pattern=r"\\n+")
            chunks = [audio for _, _, audio in generator]
            if not chunks:
                raise SystemExit(f"Kokoro produced no audio for item {key}")

            audio = np.concatenate(chunks) if len(chunks) > 1 else chunks[0]
            output_name = f"clip-{key}.wav"
            output_path = output_dir / output_name
            sf.write(output_path, audio, 24000)
            manifest[key] = output_name

        (output_dir / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        """

        if (try? String(contentsOf: scriptURL, encoding: .utf8)) != script {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        }
        return scriptURL
    }

    private static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL,
        progress: (@Sendable (String) async -> Void)? = nil
    ) throws {
        let output = ProcessOutputCollector()
        let pipe = Pipe()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        var processEnvironment = ProcessInfo.processInfo.environment
        environment.forEach { key, value in processEnvironment[key] = value }
        process.environment = processEnvironment
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let lines = output.append(data)
            if let progress, let line = lines.last {
                Task {
                    await progress(progressMessage(from: line))
                }
            }
        }
        defer {
            pipe.fileHandleForReading.readabilityHandler = nil
        }

        do {
            try process.run()
        } catch {
            throw KokoroRuntimeError.failed("Could not start Kokoro installer: \(error.localizedDescription)")
        }

        process.waitUntilExit()
        let remainingData = pipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingData.isEmpty {
            _ = output.append(remainingData)
        }
        guard process.terminationStatus == 0 else {
            throw KokoroRuntimeError.failed(summarize(log: output.contents, status: process.terminationStatus))
        }
    }

    private static func progressMessage(from line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Installing Kokoro" }
        if trimmed.count <= 72 {
            return trimmed
        }
        return "\(trimmed.prefix(69))..."
    }

    private static func capture(executableURL: URL, arguments: [String]) throws -> String {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return ""
        }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private static func summarize(log: String, status: Int32) -> String {
        let cleanLog = log.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanLog.isEmpty else {
            return "Kokoro command failed with status \(status)."
        }
        let suffix = String(cleanLog.suffix(700))
        return "Kokoro command failed: \(suffix)"
    }
}

private enum KokoroRuntimeError: Error {
    case installRequired
    case failed(String)

    var message: String {
        switch self {
        case .installRequired:
            return "Install Kokoro before using read aloud."
        case .failed(let message):
            return message
        }
    }
}

private final class ProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""
    private var partialLine = ""

    var contents: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return []
        }

        lock.lock()
        defer { lock.unlock() }

        storage.append(text)
        let combined = partialLine + text
        var lines = combined.components(separatedBy: .newlines)
        partialLine = lines.popLast() ?? ""
        return lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
