import Foundation
import StudioCore
import Testing
@testable import SQLiteGraphStudio

@Suite(.serialized)
struct DurableAnnotationTests {
    @Test @MainActor
    func noteWritesRequireCurrentRevisionAndRefreshTheWorkspace() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sgs-durable-notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("fixture.sqlite")
        try SampleFixtureBuilder.buildFixture(at: database)

        let tabs = WorkspaceTabController(initialSession: AppSession())
        let coordinator = StudioAutomationCoordinator(workspaces: tabs)
        let connected = try await call(coordinator, "studio_connect_context", [
            "client_task_id": "durable-note-test",
        ], context: nil)
        let context = try #require(content(connected)["context_id"] as? String)
        let opened = try await call(coordinator, "studio_open_source", [
            "context_id": context, "request_id": UUID().uuidString,
            "source_path": database.path,
        ], context: context)
        let sourceID = try #require(content(opened)["source_id"] as? String)
        let sourceTab = try #require(tabs.tabs.first { $0.session.databaseURL == database })
        let declaredRelation = try #require(sourceTab.session.graph.edges.first)

        let first = try await call(coordinator, "studio_get_annotations", [
            "context_id": context, "source_id": sourceID,
        ], context: context)
        let originalRevision = try #require(content(first)["metadata_revision"] as? String)
        #expect((content(first)["notes"] as? [[String: Any]])?.isEmpty == true)

        let write = try await call(coordinator, "studio_update_annotations", [
            "context_id": context, "source_id": sourceID, "request_id": UUID().uuidString,
            "expected_metadata_revision": originalRevision,
            "tables": ["authors": ["description": "People who write posts"]],
            "notes_upsert": [["id": "author-process", "text": "Editorial review uses these authors.",
                              "table_id": "authors"],
                             ["id": "declared-relation", "text": "This declared key joins these tables.",
                              "relation_id": declaredRelation.id]],
        ], context: context)
        #expect(write["isError"] as? Bool == false)
        let savedRevision = try #require(content(write)["metadata_revision"] as? String)
        #expect(savedRevision != originalRevision)

        let fresh = try await call(coordinator, "studio_get_annotations", [
            "context_id": context, "source_id": sourceID,
        ], context: context)
        #expect(content(fresh)["metadata_revision"] as? String == savedRevision)
        let notes = try #require(content(fresh)["notes"] as? [[String: Any]])
        #expect(notes.count == 2)
        #expect(notes.first?["id"] as? String == "author-process")
        #expect(try SchemaSidecarStore.load(for: database).notes.count == 2)
        #expect(sourceTab.session.schemaSidecar.notes.count == 2)

        let relationPage = try await call(coordinator, "studio_get_annotations", [
            "context_id": context, "source_id": sourceID,
            "object_ids": ["authors", declaredRelation.sourceID], "note_offset": 1, "note_limit": 1,
        ], context: context)
        #expect(content(relationPage)["note_count"] as? Int == 2)
        #expect((content(relationPage)["notes"] as? [[String: Any]])?.first?["id"] as? String == "declared-relation")

        let stale = try await call(coordinator, "studio_update_annotations", [
            "context_id": context, "source_id": sourceID, "request_id": UUID().uuidString,
            "expected_metadata_revision": originalRevision,
            "notes_upsert": [["id": "stale", "text": "Should not overwrite anything"]],
        ], context: context)
        #expect(errorCode(stale) == "METADATA_CONFLICT")
        #expect(try SchemaSidecarStore.load(for: database).notes.map(\.id) == ["author-process", "declared-relation"])

        await coordinator.close()
        await tabs.closeAllAndWait()
    }

    @MainActor
    private func call(_ coordinator: StudioAutomationCoordinator, _ name: String,
                      _ arguments: [String: Any], context: String?) async throws -> [String: Any] {
        let input = try JSONSerialization.data(withJSONObject: arguments)
        let output = await coordinator.handle(name, arguments: input, contextID: context, clientID: "durable-note-client")
        return try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
    }

    private func content(_ result: [String: Any]) -> [String: Any] {
        result["structuredContent"] as? [String: Any] ?? [:]
    }

    private func errorCode(_ result: [String: Any]) -> String? {
        (content(result)["error"] as? [String: Any])?["code"] as? String
    }
}
