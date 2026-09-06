import Foundation
import GRDB
import Testing
@testable import StudioCore

struct ImportRoundTripTests {
    @Test(arguments: [DataTransferFormat.csv, .json])
    func exportedTextAndNullRoundTripWithoutChangingValues(format: DataTransferFormat) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sgs-import-roundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.sqlite")
        let values: [SQLiteValue] = [.null, .text("\\N"), .text("NULL"), .text(""), .text("   "), .text("quoted \"value\",\nnext line"), .text("first\r\nsecond")]
        let fixture = try DatabaseQueue(path: url.path)
        try await fixture.write { db in
            try db.execute(sql: "CREATE TABLE source(value TEXT); CREATE TABLE destination(value TEXT)")
            for value in values {
                try db.execute(sql: "INSERT INTO source VALUES (?)", arguments: [value.databaseValue])
            }
        }
        let service = DatabaseService()
        try await service.open(url: url)
        do {
            let source = try await service.fetchDescriptor(named: "source")
            let destination = try await service.fetchDescriptor(named: "destination")
            let chunk = try await service.fetchChunk(query: .init(), descriptor: source)
            let exported = try await service.serializeTableRows(descriptor: source, rows: chunk.rows, format: format)
            let imported = try await service.importRows(into: destination, text: exported, format: format)
            #expect(imported.insertedRowCount == values.count)
            #expect(imported.skippedRowCount == 0)
            let result = try await service.executeReadOnlyQuery(sql: "SELECT value FROM destination ORDER BY rowid")
            #expect(result.rows.map(\.values) == values.map { [$0] })
            await service.close()
        } catch {
            await service.close()
            throw error
        }
    }

    @Test(arguments: [DataTransferFormat.csv, .json])
    func omittedFieldsRetainDefaultsWhileExplicitNullRemainsNull(format: DataTransferFormat) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sgs-import-defaults-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.sqlite")
        let fixture = try DatabaseQueue(path: url.path)
        try await fixture.write { db in
            try db.execute(sql: "CREATE TABLE destination(id INTEGER, label TEXT DEFAULT 'fallback', required TEXT NOT NULL DEFAULT 'retained')")
        }
        let service = DatabaseService()
        try await service.open(url: url)
        do {
            let descriptor = try await service.fetchDescriptor(named: "destination")
            let text = format == .csv
                ? "id,label,required\n1\n2,\\N\n3,value,\\N"
                : #"[{"id":1},{"id":2,"label":null},{"id":3,"label":"value","required":null}]"#
            let imported = try await service.importRows(into: descriptor, text: text, format: format)
            #expect(imported.insertedRowCount == 2)
            #expect(imported.skippedRowCount == 1)
            let result = try await service.executeReadOnlyQuery(sql: "SELECT id,label,required FROM destination ORDER BY id")
            #expect(result.rows.map(\.values) == [[.integer(1), .text("fallback"), .text("retained")], [.integer(2), .null, .text("retained")]])
            await service.close()
        } catch {
            await service.close()
            throw error
        }
    }

    @Test func csvImportPreservesQuotedFieldsAndAcceptsLegacyNull() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sgs-csv-fields-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.sqlite")
        let fixture = try DatabaseQueue(path: url.path)
        try await fixture.write { db in try db.execute(sql: "CREATE TABLE destination(value TEXT)") }
        let service = DatabaseService()
        try await service.open(url: url)
        do {
            let descriptor = try await service.fetchDescriptor(named: "destination")
            let imported = try await service.importRows(into: descriptor, text: "value\r\nNULL\r\n\\N\r\n\"\\N\"\r\n\"NULL\"\r\n\"\"", format: .csv)
            #expect(imported.insertedRowCount == 5)
            let result = try await service.executeReadOnlyQuery(sql: "SELECT value FROM destination ORDER BY rowid")
            #expect(result.rows.map(\.values) == [[.null], [.null], [.text("\\N")], [.text("NULL")], [.text("")]])
            await service.close()
        } catch {
            await service.close()
            throw error
        }
    }
}
