import Foundation
import StudioCore
import Testing
@testable import SQLiteGraphStudio

@Suite(.serialized)
struct ProjectScanIntegrationTests {
    @Test @MainActor
    func scanFlagsPostgresAndSQLiteAsAnExplicitSourceChoice() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sgs-mixed-project-\(UUID().uuidString)", isDirectory: true)
        let postgres = root.appendingPathComponent("backend/postgres/migrations", isDirectory: true)
        let sqlite = root.appendingPathComponent("backend/sqlite/schema.sql")
        try FileManager.default.createDirectory(at: postgres, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sqlite.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "CREATE TABLE public.contract (id UUID PRIMARY KEY);".write(
            to: postgres.appendingPathComponent("0001_contract.sql"), atomically: true, encoding: .utf8)
        try "CREATE TABLE public.vendor (id UUID PRIMARY KEY);".write(
            to: postgres.appendingPathComponent("0002_vendor.sql"), atomically: true, encoding: .utf8)
        try "CREATE TABLE contract (id INTEGER PRIMARY KEY);".write(to: sqlite, atomically: true, encoding: .utf8)

        let tabs = WorkspaceTabController(initialSession: AppSession())
        let coordinator = StudioAutomationCoordinator(workspaces: tabs)
        defer { Task { @MainActor in await coordinator.close(); await tabs.closeAllAndWait() } }
        let connected = try await call(coordinator, "studio_connect_context", ["client_task_id": "mixed-source-scan"])
        let context = try #require(payload(connected)["context_id"] as? String)
        let scan = try await call(coordinator, "studio_scan_project", [
            "context_id": context, "project_path": root.path,
        ], context: context)
        let result = payload(scan)
        #expect(result["source_choice_required"] as? Bool == true)
        #expect(Set(result["available_engines"] as? [String] ?? []) == ["PostgreSQL", "SQLite"])
        let candidates = try #require(result["candidates"] as? [[String: Any]])
        #expect(candidates.contains { $0["engine"] as? String == "PostgreSQL" && $0["supports_rows"] as? Bool == false })
        #expect(candidates.contains { $0["engine"] as? String == "SQLite" && $0["supports_rows"] as? Bool == false })

        await coordinator.close()
        await tabs.closeAllAndWait()
    }

    @Test @MainActor
    func projectScanOpensAnExactMigrationVersionAndRejectsDataTools() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sgs-agent-project-\(UUID().uuidString)", isDirectory: true)
        let migrations = root.appendingPathComponent("backend/sqlite/migrations", isDirectory: true)
        try FileManager.default.createDirectory(at: migrations, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "CREATE TABLE customer (id INTEGER PRIMARY KEY, name TEXT);".write(
            to: migrations.appendingPathComponent("0001_customer.sql"), atomically: true, encoding: .utf8)
        try "CREATE TABLE purchase (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customer(id));".write(
            to: migrations.appendingPathComponent("0002_purchase.sql"), atomically: true, encoding: .utf8)

        let tabs = WorkspaceTabController(initialSession: AppSession())
        let coordinator = StudioAutomationCoordinator(workspaces: tabs)
        defer {
            Task { @MainActor in
                await coordinator.close()
                await tabs.closeAllAndWait()
            }
        }
        let connected = try await call(coordinator, "studio_connect_context", ["client_task_id": "project-scan-test"])
        let context = try #require(payload(connected)["context_id"] as? String)
        let scan = try await call(coordinator, "studio_scan_project", [
            "context_id": context, "project_path": root.path,
        ], context: context)
        #expect(scan["isError"] as? Bool == false)
        let candidates = try #require(payload(scan)["candidates"] as? [[String: Any]])
        let candidate = try #require(candidates.first { $0["kind"] as? String == "migrationSet" })
        #expect(candidate["source_path"] as? String == migrations.path)
        #expect(candidate["migration_count"] as? Int == 2)

        let first = try await call(coordinator, "studio_open_source", [
            "context_id": context, "request_id": UUID().uuidString,
            "source_path": migrations.path, "migration_version": "0001",
        ], context: context)
        #expect(first["isError"] as? Bool == false)
        let firstRevision = try #require(payload(first)["source_revision"] as? String)
        let schema = try await call(coordinator, "studio_describe_schema", [
            "context_id": context,
        ], context: context)
        let tables = try #require(payload(schema)["tables"] as? [[String: Any]])
        #expect(tables.contains { $0["id"] as? String == "customer" })
        #expect(!tables.contains { $0["id"] as? String == "purchase" })

        let openedTable = try await call(coordinator, "studio_open_table", [
            "context_id": context, "request_id": UUID().uuidString, "table_id": "customer",
        ], context: context)
        #expect(openedTable["isError"] as? Bool == false)
        #expect(payload(openedTable)["schema_only"] as? Bool == true)
        #expect(payload(openedTable)["loaded_rows"] as? Int == 0)

        let configure = try await call(coordinator, "studio_configure_table", [
            "context_id": context, "request_id": UUID().uuidString, "table_id": "customer", "search_text": "x",
        ], context: context)
        #expect(errorCode(configure) == "SCHEMA_ONLY_SOURCE")
        let rows = try await call(coordinator, "studio_fetch_rows", [
            "context_id": context, "table_id": "customer",
        ], context: context)
        #expect(errorCode(rows) == "SCHEMA_ONLY_SOURCE")
        let query = try await call(coordinator, "studio_run_query", [
            "context_id": context, "request_id": UUID().uuidString, "sql": "SELECT * FROM customer",
        ], context: context)
        #expect(errorCode(query) == "SCHEMA_ONLY_SOURCE")
        let export = try await call(coordinator, "studio_export", [
            "context_id": context, "request_id": UUID().uuidString,
            "object_type": "table_rows", "object_id": "customer", "format": "csv",
            "scope": ["kind": "displayed"], "destination": root.appendingPathComponent("should-not-export.csv").path,
        ], context: context)
        #expect(errorCode(export) == "SCHEMA_ONLY_SOURCE")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("should-not-export.csv").path))

        let later = try await call(coordinator, "studio_open_source", [
            "context_id": context, "request_id": UUID().uuidString,
            "source_path": migrations.path, "migration_version": "0002",
        ], context: context)
        #expect(later["isError"] as? Bool == false)
        #expect(payload(later)["source_revision"] as? String != firstRevision)
        let laterSchema = try await call(coordinator, "studio_describe_schema", [
            "context_id": context,
        ], context: context)
        let laterTables = try #require(payload(laterSchema)["tables"] as? [[String: Any]])
        #expect(laterTables.contains { $0["id"] as? String == "purchase" })

        let invalidVersion = try await call(coordinator, "studio_open_source", [
            "context_id": context, "request_id": UUID().uuidString,
            "source_path": migrations.path, "migration_version": "0999",
        ], context: context)
        #expect(errorCode(invalidVersion) == "INVALID_ARGUMENT")

        let stable = try await call(coordinator, "studio_get_view", ["context_id": context], context: context)
        let stableRevision = try #require(payload(stable)["source_revision"] as? String)
        let repeated = try await call(coordinator, "studio_get_view", ["context_id": context], context: context)
        #expect(payload(repeated)["source_revision"] as? String == stableRevision)
        // Exercise cache invalidation with equal object/key counts and identical
        // file size and timestamp. A refreshed definition still changes identity.
        let migration = migrations.appendingPathComponent("0001_customer.sql")
        let stamp = try #require(FileManager.default.attributesOfItem(atPath: migration.path)[.modificationDate] as? Date)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: migrations.path)
        let directoryStamp = try #require(directoryAttributes[.modificationDate] as? Date)
        let workspaceID = try #require(payload(stable)["workspace_id"] as? String)
        let session = try #require(tabs.tabs.first { $0.id.uuidString == workspaceID }).session
        let priorSQL = try String(contentsOf: migration, encoding: .utf8)
        let changedSQL = priorSQL.replacingOccurrences(of: "name TEXT", with: "name BLOB")
        #expect(changedSQL.utf8.count == priorSQL.utf8.count)
        try changedSQL.write(to: migration, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: migration.path)
        // Atomic replacement changes its containing directory's stamp too,
        // which is another input to source_revision.
        try FileManager.default.setAttributes([.modificationDate: directoryStamp], ofItemAtPath: migrations.path)
        let refreshed = try await call(coordinator, "studio_refresh_source", [
            "context_id": context, "request_id": UUID().uuidString,
        ], context: context)
        #expect(refreshed["isError"] as? Bool == false)
        // refresh_started returns before replay finishes. Wait for the loaded
        // definition, so the revision check actually exercises cache invalidation.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while session.descriptor(named: "customer")?.columns.first(where: { $0.name == "name" })?.declaredType != "BLOB",
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(session.descriptor(named: "customer")?.columns.first(where: { $0.name == "name" })?.declaredType == "BLOB")
        try FileManager.default.setAttributes([.modificationDate: directoryStamp], ofItemAtPath: migrations.path)
        let refreshedDirectoryAttributes = try FileManager.default.attributesOfItem(atPath: migrations.path)
        #expect(refreshedDirectoryAttributes[.size] as? NSNumber == directoryAttributes[.size] as? NSNumber)
        let afterRefresh = try await call(coordinator, "studio_get_view", ["context_id": context], context: context)
        #expect(payload(afterRefresh)["source_revision"] as? String != stableRevision)

        await coordinator.close()
        await tabs.closeAllAndWait()
    }

    @MainActor
    private func call(_ coordinator: StudioAutomationCoordinator, _ name: String,
                      _ arguments: [String: Any], context: String? = nil) async throws -> [String: Any] {
        let input = try JSONSerialization.data(withJSONObject: arguments)
        let output = await coordinator.handle(name, arguments: input, contextID: context, clientID: "project-scan-client")
        return try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
    }

    private func payload(_ result: [String: Any]) -> [String: Any] {
        result["structuredContent"] as? [String: Any] ?? [:]
    }

    private func errorCode(_ result: [String: Any]) -> String? {
        (payload(result)["error"] as? [String: Any])?["code"] as? String
    }
}
