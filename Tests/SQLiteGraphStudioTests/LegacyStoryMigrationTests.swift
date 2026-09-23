import Foundation
import Testing
@testable import StudioCore

struct LegacyStoryMigrationTests {
    @Test
    func migrationBacksUpBytesAndPreservesUnrelatedMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("model.sqlite")
        let metadata = SchemaSidecarStore.sidecarURL(for: source)
        let original = Data("""
        {
          "version": 1,
          "stories": [{"id":"old-flow","title":"Old flow","playback":[]}],
          "clusters": [{"id":"process","tables":["orders"],"extra":{"owner":"team"}}],
          "tables": {"orders":{"description":"Old note","columns":{"id":"Key"},"customNote":"Keep this"},
                     "orphan":{"customNote":"Keep orphan metadata"}},
          "recordGraphMappings": [],
          "extension": {"retained":[1,2,3]}
        }
        """.utf8)
        try original.write(to: metadata)

        var loaded = try SchemaSidecarStore.load(for: source)
        #expect(loaded.tables["orders"]?.description == "Old note")
        let migrated = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        #expect(migrated["stories"] == nil)
        let backupNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(metadata.lastPathComponent + ".stories-backup-") }
        #expect(backupNames.count == 1)
        let backup = directory.appendingPathComponent(try #require(backupNames.first))
        #expect(try Data(contentsOf: backup) == original)

        loaded.tables["orders"]?.description = "New note"
        loaded.tables.removeValue(forKey: "orphan")
        try SchemaSidecarStore.save(loaded, for: source)
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        #expect(saved["stories"] == nil)
        #expect((saved["extension"] as? [String: Any])?["retained"] as? [Int] == [1, 2, 3])
        let clusters = try #require(saved["clusters"] as? [[String: Any]])
        #expect((clusters.first?["extra"] as? [String: String])?["owner"] == "team")
        let tables = try #require(saved["tables"] as? [String: [String: Any]])
        #expect(tables["orders"]?["customNote"] as? String == "Keep this")
        #expect(tables["orders"]?["description"] as? String == "New note")
        #expect(tables["orphan"]?["customNote"] as? String == "Keep orphan metadata")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(metadata.lastPathComponent + ".stories-backup-") }.count == 1)
    }

    @Test
    func invalidLegacySidecarStaysUntouched() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("invalid.sqlite")
        let metadata = SchemaSidecarStore.sidecarURL(for: source)
        let original = Data("""
        {"version":1,"stories":[{"id":"old"}],"clusters":[{"id":"duplicate","tables":[]},{"id":"duplicate","tables":[]}]}
        """.utf8)
        try original.write(to: metadata)

        #expect(throws: SchemaMetadataError.self) { _ = try SchemaSidecarStore.load(for: source) }
        #expect(try Data(contentsOf: metadata) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    }
}
