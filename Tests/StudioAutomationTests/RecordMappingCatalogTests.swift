import Foundation
import StudioCore
import Testing
@testable import SQLiteGraphStudio

@Suite(.serialized)
struct RecordMappingCatalogTests {
    @Test @MainActor
    func listsBoundedValidatedSidecarMappingsAndReadsByExactID() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("sgs-record-mapping-catalog-\(UUID().uuidString).sqlite")
        try SampleFixtureBuilder.buildFixture(at: fixture)
        defer {
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(at: SchemaSidecarStore.sidecarURL(for: fixture))
        }

        var mappings = [
            RecordGraphMapping(
                id: "post-authors",
                name: "Author to editor relationships",
                nodeTable: RecordTableID(schemaName: nil, objectName: "authors"),
                nodeIDColumns: ["id"],
                labelColumn: "name",
                edgeTable: RecordTableID(schemaName: nil, objectName: "posts"),
                sourceColumns: ["author_id"],
                targetColumns: ["editor_id"],
                typeColumn: "status",
                edgeScope: [.init(column: "status", value: .text(String(repeating: "p", count: 2_000))) ]
            ),
            RecordGraphMapping(
                id: "broken-map",
                name: "Unavailable vertices",
                nodeTable: RecordTableID(schemaName: nil, objectName: "missing_nodes"),
                nodeIDColumns: ["id"],
                edgeTable: RecordTableID(schemaName: nil, objectName: "posts"),
                sourceColumns: ["author_id"],
                targetColumns: ["editor_id"]
            ),
        ]
        var firstDuplicate = mappings[0]
        firstDuplicate.id = "duplicate-map"
        firstDuplicate.name = "First ambiguous definition"
        var secondDuplicate = firstDuplicate
        secondDuplicate.name = "Second ambiguous definition"
        mappings.append(contentsOf: [firstDuplicate, secondDuplicate])
        try SchemaSidecarStore.save(SchemaSidecar(recordGraphMappings: mappings), for: fixture)

        let tabs = WorkspaceTabController(initialSession: AppSession())
        let coordinator = StudioAutomationCoordinator(workspaces: tabs)
        let contextID = try await connect(coordinator)
        let opened = try await call(coordinator, "studio_open_source", [
            "context_id": contextID,
            "request_id": UUID().uuidString,
            "source_path": fixture.path,
        ], context: contextID)
        #expect(opened["isError"] as? Bool == false)
        let openedContent = content(opened)
        let sourceID = try #require(openedContent["source_id"] as? String)

        let firstPage = try await call(coordinator, "studio_list_record_mappings", [
            "context_id": contextID,
            "source_id": sourceID,
            "limit": 1,
        ], context: contextID)
        #expect(firstPage["isError"] as? Bool == false)
        let first = content(firstPage)
        #expect(first["provenance"] as? String == "source_sidecar.recordGraphMappings")
        #expect(first["read_only"] as? Bool == true)
        #expect(first["total_count"] as? Int == 4)
        #expect(first["has_more"] as? Bool == true)
        #expect(first["next_offset"] as? Int == 1)
        let firstMapping = try #require((first["mappings"] as? [[String: Any]])?.first)
        #expect(firstMapping["mapping_id"] as? String == "post-authors")
        #expect(firstMapping["validation_status"] as? String == "usable")
        #expect(firstMapping["followable"] as? Bool == true)
        #expect(firstMapping["provenance"] as? [String: Any] != nil)
        #expect((firstMapping["source_columns"] as? [String]) == ["author_id"])
        let edgeScope = try #require(firstMapping["edge_scope"] as? [[String: Any]])
        #expect(edgeScope.first?["type"] as? String == "text")
        #expect(edgeScope.first?["value_truncated"] as? Bool == true)
        #expect((edgeScope.first?["value"] as? String)?.utf8.count == 512)

        let secondPage = try await call(coordinator, "studio_list_record_mappings", [
            "context_id": contextID,
            "source_id": sourceID,
            "offset": 1,
        ], context: contextID)
        #expect(secondPage["isError"] as? Bool == false)
        let secondMapping = try #require((content(secondPage)["mappings"] as? [[String: Any]])?.first)
        #expect(secondMapping["mapping_id"] as? String == "broken-map")
        #expect(secondMapping["validation_status"] as? String == "invalid")
        #expect(secondMapping["followable"] as? Bool == false)
        #expect(secondMapping["validation_error"] as? String != nil)

        let duplicatesPage = try await call(coordinator, "studio_list_record_mappings", [
            "context_id": contextID,
            "source_id": sourceID,
            "offset": 2,
        ], context: contextID)
        #expect(duplicatesPage["isError"] as? Bool == false)
        let duplicateMappings = try #require(content(duplicatesPage)["mappings"] as? [[String: Any]])
        #expect(duplicateMappings.count == 2)
        #expect(duplicateMappings.allSatisfy { $0["validation_status"] as? String == "duplicate_mapping_id" })
        #expect(duplicateMappings.allSatisfy { $0["followable"] as? Bool == false })

        let exact = try await call(coordinator, "studio_list_record_mappings", [
            "context_id": contextID,
            "source_id": sourceID,
            "mapping_id": "post-authors",
        ], context: contextID)
        #expect(content(exact)["total_count"] as? Int == 1)
        #expect((content(exact)["mappings"] as? [[String: Any]])?.first?["mapping_id"] as? String == "post-authors")

        let ambiguous = try await call(coordinator, "studio_list_record_mappings", [
            "context_id": contextID,
            "source_id": sourceID,
            "mapping_id": "duplicate-map",
        ], context: contextID)
        #expect(content(ambiguous)["total_count"] as? Int == 2)
        #expect((content(ambiguous)["mappings"] as? [[String: Any]])?.allSatisfy {
            $0["validation_status"] as? String == "duplicate_mapping_id" && $0["followable"] as? Bool == false
        } == true)

        let missing = try await call(coordinator, "studio_list_record_mappings", [
            "context_id": contextID, "mapping_id": "invented",
        ], context: contextID)
        #expect(errorCode(missing) == "OBJECT_NOT_FOUND")
        let badOffset = try await call(coordinator, "studio_list_record_mappings", [
            "context_id": contextID, "offset": -1,
        ], context: contextID)
        #expect(errorCode(badOffset) == "INVALID_ARGUMENT")
        let badLimit = try await call(coordinator, "studio_list_record_mappings", [
            "context_id": contextID, "limit": 6,
        ], context: contextID)
        #expect(errorCode(badLimit) == "INVALID_ARGUMENT")

        await coordinator.close()
        await tabs.closeAllAndWait()
    }

    @MainActor
    private func connect(_ coordinator: StudioAutomationCoordinator) async throws -> String {
        let response = try await call(coordinator, "studio_connect_context", [
            "client_task_id": "mapping-catalog-task",
        ], context: nil)
        return try #require(content(response)["context_id"] as? String)
    }

    @MainActor
    private func call(_ coordinator: StudioAutomationCoordinator, _ name: String,
                      _ arguments: [String: Any], context: String?) async throws -> [String: Any] {
        let input = try JSONSerialization.data(withJSONObject: arguments)
        let output = await coordinator.handle(name, arguments: input, contextID: context, clientID: "mapping-catalog-client")
        return try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
    }

    private func content(_ result: [String: Any]) -> [String: Any] {
        result["structuredContent"] as? [String: Any] ?? [:]
    }

    private func errorCode(_ result: [String: Any]) -> String? {
        (content(result)["error"] as? [String: Any])?["code"] as? String
    }
}
