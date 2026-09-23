import Foundation
import Testing
@testable import StudioCore

struct PocketTTSWorkerSessionTests {
    @Test
    func shortReadyMessageStartsTheWorkerWithoutWaitingForMoreOutput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocket-worker-short-ready-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let binary = root.appendingPathComponent("python/bin/python3")
        try FileManager.default.createDirectory(
            at: binary.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let ready = "{\"type\":\"ready\",\"protocol\":1,\"version\":\"3.1.0\",\"provider\":\"pocket-tts\",\"voice\":\"alba\",\"format\":\"f32le\",\"sample_rate\":24000,\"channels\":1}"
        let script = "#!/bin/sh\nprintf '%s\\n' '\(ready)'\ncat >/dev/null\n"
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let session = PocketTTSWorkerSession(workerRoot: root, presetRoot: root)
        let timeout = Task.detached {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { session.terminate() }
        }
        defer {
            timeout.cancel()
            session.terminate()
        }

        try await session.startAndWaitUntilReady()
        #expect(session.isReady)
    }
}
