import Foundation
import Testing
@testable import StudioCore

/// The whole open path for a migration model, short of SwiftUI rendering.
struct MigrationDocumentTests {

    private func makeDirectory(_ files: [(String, String)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-document-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("migrations", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, sql) in files {
            try sql.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return root
    }

    private var sampleFiles: [(String, String)] {
        [
            ("0001_init.sql", "create table a (id int primary key);"),
            ("0002_more.sql", "create table b (id int primary key, a_id int references a(id));"),
            ("0003_last.sql", "create table c (id int primary key);"),
        ]
    }

    @Test func openingAMigrationFolderServesASchemaOnlyCatalog() async throws {
        let directory = try makeDirectory(sampleFiles)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

        let service = DatabaseService()
        let set = try ProjectScanner.migrationSet(at: directory)
        let collector = ProgressCollector()
        try await service.open(migrations: set, through: nil, sourceURL: directory) { message in
            await collector.append(message)
        }

        #expect(await service.isMigrationModel)
        #expect(await service.capabilities.canRunQueries == false)
        #expect(await service.capabilities.canBrowseRows == false)
        // Notes, clusters and stories still work: they live in a local sidecar.
        #expect(await service.capabilities.supportsAIWorkspace)
        #expect(await service.currentTarget == .migrations(directory.standardizedFileURL))
        let messages = await collector.messages
        #expect(messages.contains { $0.contains("Reading 3 migrations") })

        let snapshot = try await service.loadCatalogSnapshot()
        #expect(snapshot.descriptors.map(\.name) == ["public.a", "public.b", "public.c"])
        #expect(snapshot.graph.edges.count == 1)
        #expect(await service.migrationModel?.fileCount == 3)

        let tables = try await service.listTables()
        #expect(tables.map(\.displayName) == ["a", "b", "c"])
        // Row counts are unknown rather than invented.
        #expect(tables.allSatisfy { $0.rowCount == nil })

        await service.close()
        #expect(await service.isMigrationModel == false)
    }

    @Test func steppingToAnEarlierVersionKeepsTheDocumentIdentity() async throws {
        let directory = try makeDirectory(sampleFiles)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

        let service = DatabaseService()
        let set = try ProjectScanner.migrationSet(at: directory)
        try await service.open(migrations: set, through: nil, sourceURL: directory)
        let latestTarget = try #require(await service.currentTarget)

        try await service.open(migrations: set, through: "0002", sourceURL: directory)
        let snapshot = try await service.loadCatalogSnapshot()
        #expect(snapshot.descriptors.map(\.name) == ["public.a", "public.b"])

        // Graph layout, saved queries and notes are keyed by the target, so they
        // must belong to the migration set rather than to one revision of it.
        #expect(await service.currentTarget == latestTarget)
        #expect(await service.currentTarget?.stableStorageKey == latestTarget.stableStorageKey)
        #expect(latestTarget.isMigrationModel)
        #expect(latestTarget.isPostgres == false)
        await service.close()
    }

    @Test func reopeningByTargetResolvesTheFolderAgain() async throws {
        let directory = try makeDirectory(sampleFiles)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

        let service = DatabaseService()
        try await service.open(target: .migrations(directory))
        let snapshot = try await service.loadCatalogSnapshot()
        #expect(snapshot.descriptors.count == 3)
        await service.close()
    }

    @Test func rowAndQueryWorkIsRefusedWithAnExplanation() async throws {
        let directory = try makeDirectory(sampleFiles)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

        let service = DatabaseService()
        try await service.open(target: .migrations(directory))

        await #expect(throws: DatabaseUserError.self) {
            _ = try await service.executeReadOnlyQuery(sql: "select 1")
        }
        let descriptor = try await service.fetchDescriptor(named: "public.b")
        let chunk = try await service.fetchChunk(query: TableQueryState(), descriptor: descriptor)
        #expect(chunk.rows.isEmpty)
        #expect(chunk.totalRowCount == 0)
        await service.close()
    }

    @Test func aMigrationTargetRoundTripsThroughItsStoredForm() throws {
        let target = DatabaseTarget.migrations(URL(fileURLWithPath: "/tmp/repo/migrations"))
        let data = try JSONEncoder().encode(target)
        let restored = try JSONDecoder().decode(DatabaseTarget.self, from: data)
        #expect(restored == target)
        #expect(restored.displayName == "migrations")
        #expect(restored.fileURL?.path == "/tmp/repo/migrations")
    }

    @MainActor @Test func schemaOnlyCapabilitiesDisableEveryWrite() {
        let capabilities = AppSession.capabilities(for: .migrations(URL(fileURLWithPath: "/tmp/m")))
        #expect(capabilities.isReadOnly)
        #expect(capabilities.canEditRows == false)
        #expect(capabilities.canInsertRows == false)
        #expect(capabilities.canDeleteRows == false)
        #expect(capabilities.canImportRows == false)
        #expect(capabilities.canCreateTable == false)
        #expect(capabilities.canAlterSchema == false)
        #expect(capabilities.canDropColumns == false)
        #expect(capabilities.canBrowseRows == false)
        #expect(capabilities.canRunQueries == false)
        #expect(capabilities.supportsAIWorkspace)
    }
}

private actor ProgressCollector {
    var messages: [String] = []
    func append(_ message: String) { messages.append(message) }
}
