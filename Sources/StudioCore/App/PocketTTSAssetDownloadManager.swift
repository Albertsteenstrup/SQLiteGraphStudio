import CryptoKit
import Foundation

/// Asset installation status. `assetsInstalled` means only that every pinned file passed size and
/// SHA-256 verification; speech is usable only when `PocketTTSRuntimeInspector` reports `.ready`.
public enum PocketTTSAssetDownloadState: Sendable, Equatable {
    case unavailable(String)
    case available
    case downloading(
        assetID: String,
        assetBytesReceived: Int64,
        assetByteCount: Int64,
        totalBytesReceived: Int64,
        totalByteCount: Int64
    )
    case verifying(assetID: String)
    case paused(assetID: String?, resumableBytes: Int64)
    case assetsInstalled
    case failed(assetID: String?, message: String)
}

/// A user-triggered, resumable installer for the pinned Pocket preset. It is deliberately
/// unavailable unless the packaged runtime and the Pocket streaming provider have both passed
/// inspection. It never starts a transfer during initialization or inspection.
@MainActor
public final class PocketTTSAssetDownloadManager {
    public private(set) var state: PocketTTSAssetDownloadState
    public private(set) var readiness: PocketTTSRuntimeReadiness

    public var canOfferDownload: Bool {
        readiness.canDownloadMissingAssets
    }

    public let installRoot: URL

    private let inspector: PocketTTSRuntimeInspector
    private let assets: [PocketTTSSpeechAssets.Asset]
    private let sessionConfiguration: @Sendable () -> URLSessionConfiguration
    private var activeTransfer: PocketTTSAssetTransfer?
    private var activeAssetID: String?
    private var activePartialURL: URL?
    private var currentRunID = UUID()

    public convenience init(inspector: PocketTTSRuntimeInspector = .bundledDefault()) {
        self.init(
            inspector: inspector,
            assets: PocketTTSSpeechAssets.assets,
            sessionConfiguration: { .ephemeral }
        )
    }

    init(
        inspector: PocketTTSRuntimeInspector,
        assets: [PocketTTSSpeechAssets.Asset],
        sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration
    ) {
        self.inspector = inspector
        self.assets = assets
        self.sessionConfiguration = sessionConfiguration
        installRoot = inspector.presetRoot
        readiness = inspector.inspect()
        state = Self.state(for: readiness)
    }

    /// Rechecks the packaged worker and installed asset state. No network activity occurs here.
    public func refresh() {
        readiness = inspector.inspect()
        guard activeTransfer == nil else { return }
        state = Self.state(for: readiness)
    }

    /// Starts one explicit download attempt. A partial file from an earlier interruption is
    /// resumed with an HTTP Range request; each installed file is verified before it is skipped.
    public func download() async {
        guard activeTransfer == nil else { return }
        refresh()
        guard readiness.canDownloadMissingAssets else {
            state = .unavailable(readiness.explanation)
            return
        }

        let runID = UUID()
        currentRunID = runID
        do {
            try FileManager.default.createDirectory(
                at: installRoot,
                withIntermediateDirectories: true
            )

            var previouslyVerifiedBytes: Int64 = 0
            for asset in assets {
                try Task.checkCancellation()
                let destination = try destinationURL(for: asset)
                if try await Self.matches(destination, asset: asset) {
                    previouslyVerifiedBytes += asset.expectedByteCount
                    continue
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }

                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let partial = destination.appendingPathExtension("partial")
                var existingBytes = Self.fileSize(at: partial)
                if existingBytes > asset.expectedByteCount {
                    try FileManager.default.removeItem(at: partial)
                    existingBytes = 0
                } else if existingBytes == asset.expectedByteCount {
                    if try await Self.matches(partial, asset: asset) {
                        try FileManager.default.moveItem(at: partial, to: destination)
                        previouslyVerifiedBytes += asset.expectedByteCount
                        continue
                    }
                    try FileManager.default.removeItem(at: partial)
                    existingBytes = 0
                }
                let startingOffset = existingBytes
                activeAssetID = asset.id
                activePartialURL = partial
                let baseVerifiedBytes = previouslyVerifiedBytes

                let transfer = PocketTTSAssetTransfer(
                    asset: asset,
                    partialURL: partial,
                    startingOffset: startingOffset,
                    configuration: sessionConfiguration(),
                    onProgress: { [weak self] assetBytes in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.currentRunID == runID,
                                  self.activeAssetID == asset.id,
                                  self.activeTransfer != nil else { return }
                            self.state = .downloading(
                                assetID: asset.id,
                                assetBytesReceived: assetBytes,
                                assetByteCount: asset.expectedByteCount,
                                totalBytesReceived: baseVerifiedBytes + assetBytes,
                                totalByteCount: PocketTTSAssetDownloadManager.totalBytes(in: self.assets)
                            )
                        }
                    }
                )
                activeTransfer = transfer
                state = .downloading(
                    assetID: asset.id,
                    assetBytesReceived: startingOffset,
                    assetByteCount: asset.expectedByteCount,
                    totalBytesReceived: previouslyVerifiedBytes + startingOffset,
                    totalByteCount: Self.totalBytes(in: assets)
                )

                try await transfer.download()
                activeTransfer = nil
                state = .verifying(assetID: asset.id)
                try Task.checkCancellation()
                guard try await Self.matches(partial, asset: asset) else {
                    try? FileManager.default.removeItem(at: partial)
                    throw PocketTTSAssetDownloadError.integrityMismatch(asset.id)
                }

                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: partial, to: destination)
                previouslyVerifiedBytes += asset.expectedByteCount
                activeAssetID = nil
                activePartialURL = nil
            }

            state = .assetsInstalled
            readiness = inspector.inspect()
        } catch is CancellationError {
            activeTransfer?.cancel()
            activeTransfer = nil
            let partialBytes = activePartialURL.map(Self.fileSize(at:)) ?? 0
            state = .paused(assetID: activeAssetID, resumableBytes: partialBytes)
        } catch {
            if case PocketTTSAssetDownloadError.invalidRange = error,
               let activePartialURL {
                try? FileManager.default.removeItem(at: activePartialURL)
            }
            activeTransfer = nil
            let message = Self.message(for: error)
            state = .failed(assetID: activeAssetID, message: message)
        }
    }

    /// Cancels the active request while retaining its partial file for a later `download()` call.
    public func cancel() {
        activeTransfer?.cancel()
    }

    public func retry() async {
        await download()
    }

    private func destinationURL(for asset: PocketTTSSpeechAssets.Asset) throws -> URL {
        let components = asset.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PocketTTSAssetDownloadError.invalidAssetPath(asset.relativePath)
        }

        let destination = components.reduce(installRoot) { current, component in
            current.appendingPathComponent(String(component))
        }.standardizedFileURL
        let rootPath = installRoot.standardizedFileURL.path + "/"
        guard destination.path.hasPrefix(rootPath) else {
            throw PocketTTSAssetDownloadError.invalidAssetPath(asset.relativePath)
        }
        return destination
    }

    private static func totalBytes(in assets: [PocketTTSSpeechAssets.Asset]) -> Int64 {
        assets.reduce(0) { $0 + $1.expectedByteCount }
    }

    private static func state(for readiness: PocketTTSRuntimeReadiness) -> PocketTTSAssetDownloadState {
        switch readiness {
        case .presetAssetsMissing:
            .available
        case .ready:
            .assetsInstalled
        case .runtimeNotPackaged, .workerAdapterUnavailable:
            .unavailable(readiness.explanation)
        }
    }

    nonisolated private static func fileSize(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    private static func matches(
        _ fileURL: URL,
        asset: PocketTTSSpeechAssets.Asset
    ) async throws -> Bool {
        try await Task.detached(priority: .utility) {
            try matchesOnDisk(fileURL, asset: asset)
        }.value
    }

    nonisolated private static func matchesOnDisk(
        _ fileURL: URL,
        asset: PocketTTSSpeechAssets.Asset
    ) throws -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              fileSize(at: fileURL) == asset.expectedByteCount else { return false }

        let file = try FileHandle(forReadingFrom: fileURL)
        defer { try? file.close() }
        var hasher = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == asset.sha256.lowercased()
    }

    private static func message(for error: any Error) -> String {
        if let localized = error as? LocalizedError,
           let message = localized.errorDescription {
            return message
        }
        return error.localizedDescription
    }
}

private enum PocketTTSAssetDownloadError: LocalizedError {
    case invalidAssetPath(String)
    case invalidResponse
    case invalidStatus(Int)
    case invalidRange
    case fileWrite(String)
    case integrityMismatch(String)

    var errorDescription: String? {
        switch self {
        case .invalidAssetPath(let path):
            "The Pocket TTS asset path is invalid: \(path)."
        case .invalidResponse:
            "Hugging Face returned an invalid response for a pinned Pocket TTS asset."
        case .invalidStatus(let status):
            "Hugging Face returned HTTP \(status) for a pinned Pocket TTS asset."
        case .invalidRange:
            "The Pocket TTS asset server returned an invalid byte range; retry the download."
        case .fileWrite(let message):
            "The Pocket TTS partial download could not be written: \(message)"
        case .integrityMismatch(let assetID):
            "The downloaded Pocket TTS asset \(assetID) did not match its pinned size and SHA-256. The partial file was removed."
        }
    }
}

/// A single serialized data task writes directly to disk, so the 219 MB model is never buffered
/// in memory. Retrying uses the saved `.partial` file and verifies the server's Content-Range.
private final class PocketTTSAssetTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let asset: PocketTTSSpeechAssets.Asset
    private let partialURL: URL
    private let startingOffset: Int64
    private let configuration: URLSessionConfiguration
    private let onProgress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var fileHandle: FileHandle?
    private var receivedBytes: Int64 = 0
    private var writeError: (any Error)?
    private var isComplete = false
    private var responseWasAccepted = false
    private var activeBaseOffset: Int64 = 0

    init(
        asset: PocketTTSSpeechAssets.Asset,
        partialURL: URL,
        startingOffset: Int64,
        configuration: URLSessionConfiguration,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) {
        self.asset = asset
        self.partialURL = partialURL
        self.startingOffset = startingOffset
        self.configuration = configuration
        self.onProgress = onProgress
    }

    func download() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                var request = URLRequest(url: asset.downloadURL)
                request.timeoutInterval = 60
                if startingOffset > 0 {
                    request.setValue("bytes=\(startingOffset)-", forHTTPHeaderField: "Range")
                }

                lock.lock()
                self.continuation = continuation
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: OperationQueue()
                )
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            complete(.failure(PocketTTSAssetDownloadError.invalidResponse))
            return
        }

        let appendOffset: Int64
        if response.statusCode == 206 {
            guard let range = response.value(forHTTPHeaderField: "Content-Range"),
                  Self.rangeStart(range) == startingOffset,
                  Self.rangeTotal(range) == asset.expectedByteCount else {
                completionHandler(.cancel)
                complete(.failure(PocketTTSAssetDownloadError.invalidRange))
                return
            }
            appendOffset = startingOffset
        } else if response.statusCode == 200 {
            appendOffset = 0
        } else if response.statusCode == 416, startingOffset > 0 {
            completionHandler(.cancel)
            complete(.failure(PocketTTSAssetDownloadError.invalidRange))
            return
        } else {
            completionHandler(.cancel)
            complete(.failure(PocketTTSAssetDownloadError.invalidStatus(response.statusCode)))
            return
        }

        do {
            if !FileManager.default.fileExists(atPath: partialURL.path) {
                _ = FileManager.default.createFile(atPath: partialURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: partialURL)
            if appendOffset == 0 {
                try handle.truncate(atOffset: 0)
            } else {
                try handle.seekToEnd()
            }
            fileHandle = handle
            activeBaseOffset = appendOffset
            responseWasAccepted = true
            onProgress(appendOffset)
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            complete(.failure(PocketTTSAssetDownloadError.fileWrite(error.localizedDescription)))
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard responseWasAccepted, writeError == nil else { return }
        do {
            try fileHandle?.write(contentsOf: data)
            receivedBytes += Int64(data.count)
            onProgress(activeBaseOffset + receivedBytes)
        } catch {
            writeError = error
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        try? fileHandle?.close()
        fileHandle = nil

        if let writeError {
            complete(.failure(PocketTTSAssetDownloadError.fileWrite(writeError.localizedDescription)))
        } else if let error {
            if (error as? URLError)?.code == .cancelled {
                complete(.failure(CancellationError()))
            } else {
                complete(.failure(error))
            }
        } else if !responseWasAccepted {
            complete(.failure(PocketTTSAssetDownloadError.invalidResponse))
        } else {
            complete(.success(()))
        }
    }

    private func complete(_ result: Result<Void, any Error>) {
        lock.lock()
        guard !isComplete else {
            lock.unlock()
            return
        }
        isComplete = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        self.task = nil
        lock.unlock()

        continuation?.resume(with: result)
        session?.finishTasksAndInvalidate()
    }

    private static func rangeStart(_ contentRange: String) -> Int64? {
        guard let range = contentRange.split(separator: " ").last,
              let first = range.split(separator: "/").first,
              let start = first.split(separator: "-").first else { return nil }
        return Int64(start)
    }

    private static func rangeTotal(_ contentRange: String) -> Int64? {
        guard let range = contentRange.split(separator: "/").last else { return nil }
        return Int64(range)
    }
}
