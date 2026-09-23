import Foundation
import Testing
@testable import StudioCore

struct MetadataFailureTests {
    @Test func malformedMetadataIsAnError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let sidecar = SchemaSidecarStore.sidecarURL(for: url)
        defer { try? FileManager.default.removeItem(at: sidecar) }
        try Data("{broken".utf8).write(to: sidecar)
        #expect(throws: (any Error).self) { _ = try SchemaSidecarStore.load(for: url) }
    }
    @Test func unsupportedMetadataVersionIsAnError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let sidecar = SchemaSidecarStore.sidecarURL(for: url)
        defer { try? FileManager.default.removeItem(at: sidecar) }
        try Data("{\"version\":999}".utf8).write(to: sidecar)
        #expect(throws: (any Error).self) { _ = try SchemaSidecarStore.load(for: url) }
    }
    @Test func failuresRetainLastGoodValueDeletionClearsAndSwitchingDoesNotLeak() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let other = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let file = SchemaSidecarStore.sidecarURL(for: url)
        defer { try? FileManager.default.removeItem(at: file) }
        var state = SchemaMetadataState()
        state.reload(for: url, descriptors: [])
        #expect(state.status == .absent)
        let good = SchemaSidecar(tables: ["old_table": .init(description: "Keep this", columns: ["missing": "Old field"])])
        try SchemaSidecarStore.save(good, for: url)
        state.reload(for: url, descriptors: [])
        #expect(state.status == .loaded)
        #expect(state.diagnostics.contains { $0.contains("old_table") })
        try Data("{bad".utf8).write(to: file)
        state.reload(for: url, descriptors: [])
        #expect(state.sidecar == good)
        guard case .failed(.malformed) = state.status else { Issue.record("Expected malformed state"); return }
        // Saving over malformed metadata would discard unknown user fields.
        // Repair is explicit: remove the invalid file before saving a new one.
        try FileManager.default.removeItem(at: file)
        try SchemaSidecarStore.save(.empty, for: url)
        state.reload(for: url, descriptors: [])
        #expect(state.status == .loaded)
        #expect(state.diagnostics.isEmpty)
        try FileManager.default.removeItem(at: file)
        state.reload(for: url, descriptors: [])
        #expect(state.status == .removed)
        #expect(state.sidecar == .empty)
        try SchemaSidecarStore.save(good, for: url)
        state.reload(for: url, descriptors: [])
        state.reload(for: other, descriptors: [])
        #expect(state.status == .absent)
        #expect(state.sidecar == .empty)
    }
    @Test func directoryInsteadOfMetadataIsUnreadableAndDoesNotEraseGoodState() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let file = SchemaSidecarStore.sidecarURL(for: url)
        defer { try? FileManager.default.removeItem(at: file) }
        var state = SchemaMetadataState()
        let good = SchemaSidecar(clusters: [.init(id: "c", tables: ["t"])])
        try SchemaSidecarStore.save(good, for: url)
        state.reload(for: url, descriptors: [])
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        state.reload(for: url, descriptors: [])
        #expect(state.sidecar == good)
        guard case .failed(.unreadable) = state.status else { Issue.record("Expected unreadable state"); return }
    }

    @Test func futureVersionWithChangedShapeIsUnsupported() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let file = SchemaSidecarStore.sidecarURL(for: url)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("{\"version\":999,\"tables\":[]}".utf8).write(to: file)
        #expect(throws: SchemaMetadataError.unsupportedVersion(999)) { _ = try SchemaSidecarStore.load(for: url) }
    }
    @Test func legacyStoryEntriesAreBackedUpAndRemovedWithoutReplacingCurrentSchemaFields() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        let file = SchemaSidecarStore.sidecarURL(for: url)
        defer {
            try? FileManager.default.removeItem(at: file)
            let parent = file.deletingLastPathComponent()
            let backups = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
            for backup in backups where backup.lastPathComponent.hasPrefix(file.lastPathComponent + ".stories-backup-") {
                try? FileManager.default.removeItem(at: backup)
            }
        }
        var state = SchemaMetadataState()
        let good = SchemaSidecar(tables: ["t": .init(description: "Good")])
        try SchemaSidecarStore.save(good, for: url)
        state.reload(for: url, descriptors: [])
        let legacy = Data("{\"version\":1,\"tables\":{\"t\":{\"description\":\"Good\"}},\"stories\":[{\"id\":\"same\"},{\"id\":\"same\"}]}".utf8)
        try legacy.write(to: file)
        state.reload(for: url, descriptors: [])
        #expect(state.sidecar == good)
        #expect(state.status == .loaded)
        let rewritten = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(rewritten["stories"] == nil)
        let backups = try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(file.lastPathComponent + ".stories-backup-") }
        #expect(backups.contains { (try? Data(contentsOf: $0)) == legacy })
    }

}
