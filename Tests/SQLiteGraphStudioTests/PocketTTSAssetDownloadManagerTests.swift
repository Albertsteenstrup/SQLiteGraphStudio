import CryptoKit
import Foundation
import Testing
@testable import StudioCore

@Suite(.serialized)
struct PocketTTSAssetDownloadManagerTests {
    @Test @MainActor
    func downloadOfferStaysClosedWithoutBundledRuntimeAndProvider() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        PocketTTSURLProtocol.configure(responseBody: Data())

        let inspector = PocketTTSRuntimeInspector(
            workerRoot: directory.appendingPathComponent("missing-runtime"),
            presetRoot: directory.appendingPathComponent("model", isDirectory: true)
        )
        let manager = PocketTTSAssetDownloadManager(
            inspector: inspector,
            assets: PocketTTSSpeechAssets.assets,
            sessionConfiguration: { .ephemeral }
        )

        #expect(!manager.canOfferDownload)
        guard case .unavailable = manager.state else {
            Issue.record("Expected an explicit unavailable state when the worker is not packaged.")
            return
        }

        await manager.download()

        #expect(!manager.canOfferDownload)
        guard case .unavailable = manager.state else {
            Issue.record("A download attempt must not bypass the missing runtime/provider gate.")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: manager.installRoot.path))
        #expect(PocketTTSURLProtocol.requestedRanges.isEmpty)
    }

    @Test @MainActor
    func resumesPartialAssetAndInstallsOnlyAfterSizeAndHashVerification() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtimeRoot = directory.appendingPathComponent("runtime", isDirectory: true)
        try createRequiredRuntimeFiles(at: runtimeRoot)

        let presetRoot = directory.appendingPathComponent("SQLiteGraphStudio/Speech/PocketTTS/rev", isDirectory: true)
        let inspector = PocketTTSRuntimeInspector(
            workerRoot: runtimeRoot,
            presetRoot: presetRoot,
            pocketTTSProviderAvailable: true
        )
        let content = Data("resume-with-range-and-verify".utf8)
        let resumedByteCount = 9
        let asset = PocketTTSSpeechAssets.Asset(
            id: "test-asset",
            relativePath: "languages/test/preset.bin",
            downloadURL: URL(string: "https://pocket-tts.invalid/preset.bin")!,
            expectedByteCount: Int64(content.count),
            sha256: SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined(),
            sourceRevision: "test-revision"
        )
        PocketTTSURLProtocol.configure(responseBody: content)

        let destination = presetRoot.appendingPathComponent(asset.relativePath)
        let partial = destination.appendingPathExtension("partial")
        try FileManager.default.createDirectory(
            at: partial.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.prefix(resumedByteCount).write(to: partial)

        let manager = PocketTTSAssetDownloadManager(
            inspector: inspector,
            assets: [asset],
            sessionConfiguration: {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [PocketTTSURLProtocol.self]
                return configuration
            }
        )

        #expect(manager.canOfferDownload)
        await manager.download()

        #expect(manager.state == .assetsInstalled)
        #expect(try Data(contentsOf: destination) == content)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(PocketTTSURLProtocol.requestedRanges == ["bytes=\(resumedByteCount)-"])
    }

    @Test @MainActor
    func hashMismatchDoesNotInstallAnAsset() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtimeRoot = directory.appendingPathComponent("runtime", isDirectory: true)
        try createRequiredRuntimeFiles(at: runtimeRoot)

        let presetRoot = directory.appendingPathComponent("assets", isDirectory: true)
        let inspector = PocketTTSRuntimeInspector(
            workerRoot: runtimeRoot,
            presetRoot: presetRoot,
            pocketTTSProviderAvailable: true
        )
        let body = Data("content that fails the pinned digest".utf8)
        let asset = PocketTTSSpeechAssets.Asset(
            id: "wrong-digest",
            relativePath: "payload.bin",
            downloadURL: URL(string: "https://pocket-tts.invalid/payload.bin")!,
            expectedByteCount: Int64(body.count),
            sha256: String(repeating: "0", count: 64),
            sourceRevision: "test-revision"
        )
        PocketTTSURLProtocol.configure(responseBody: body)
        let manager = PocketTTSAssetDownloadManager(
            inspector: inspector,
            assets: [asset],
            sessionConfiguration: {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [PocketTTSURLProtocol.self]
                return configuration
            }
        )

        await manager.download()

        guard case .failed(let assetID, let message) = manager.state else {
            Issue.record("Expected a verification failure for a modified asset.")
            return
        }
        #expect(assetID == asset.id)
        #expect(message.contains("did not match its pinned size and SHA-256"))
        #expect(!FileManager.default.fileExists(atPath: presetRoot.appendingPathComponent(asset.relativePath).path))
        #expect(!FileManager.default.fileExists(atPath: presetRoot.appendingPathComponent(asset.relativePath).appendingPathExtension("partial").path))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketTTSAssetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func createRequiredRuntimeFiles(at root: URL) throws {
        for path in ["python/bin/python3", "pocket_tts_worker.py", "requirements.lock"] {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: file)
        }
    }
}

private final class PocketTTSURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseBody = Data()
    nonisolated(unsafe) private static var rangeHeaders: [String?] = []

    static var requestedRanges: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return rangeHeaders
    }

    static func configure(responseBody: Data) {
        lock.lock()
        self.responseBody = responseBody
        rangeHeaders = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "pocket-tts.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let body = Self.responseBody
        let rangeHeader = request.value(forHTTPHeaderField: "Range")
        Self.rangeHeaders.append(rangeHeader)
        Self.lock.unlock()

        let offset: Int
        if let rangeHeader,
           let start = rangeHeader.split(separator: "=").last?.split(separator: "-").first,
           let parsed = Int(start) {
            offset = parsed
        } else {
            offset = 0
        }
        guard offset <= body.count else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let statusCode = offset > 0 ? 206 : 200
        let responseData = body.subdata(in: offset..<body.count)
        var headers = [
            "Accept-Ranges": "bytes",
            "Content-Length": String(responseData.count),
        ]
        if statusCode == 206 {
            headers["Content-Range"] = "bytes \(offset)-\(body.count - 1)/\(body.count)"
        }

        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
