import Foundation
import GRDB
import Testing
@testable import StudioCore

struct StreamingExportTests {
    @Test func allMatchingExportsBeyondLoadedPageAndIgnoresOffset() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbURL = directory.appendingPathComponent("fixture.sqlite")
        let fixture = try DatabaseQueue(path: dbURL.path)
        try await fixture.write { db in
            try db.execute(sql: "CREATE TABLE items(id INTEGER PRIMARY KEY, label TEXT)")
            try db.execute(sql: "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1205) INSERT INTO items SELECT x, CASE WHEN x%2=0 THEN 'even' ELSE 'odd' END FROM n")
        }
        let service = DatabaseService()
        try await service.open(url: dbURL)
        let descriptor = try await service.fetchDescriptor(named: "items")
        let query = TableQueryState(columnFilters: [.init(columnName: "label", value: "even")], sort: .init(columnName: "id", direction: .descending), offset: 100, limit: 50)
        let chunk = try await service.fetchChunk(query: query, descriptor: descriptor)
        #expect(chunk.rows.count == 50)
        let destination = directory.appendingPathComponent("all.json")
        let count = try await service.exportTableRows(query: query, descriptor: descriptor, to: destination, format: .json)
        #expect(count == 602)
        let objects = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [[String: Any]])
        #expect(objects.count == 602)
        #expect(objects.first?["id"] as? Int == 1204)
        #expect(objects.last?["id"] as? Int == 2)
        await service.close()
    }
    @Test func retainedRowsStreamExactValuesAndCollisionKeys() async throws {
        let directory = try exportDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("exact.json")
        let values: [[DatabaseResultValue]] = [[.null, .text("\\N"), .exactNumeric("12345678901234567890.123400"), .json("{ \"a\" : 1 }"), .array("{NULL,\"NULL\"}")]]
        let count = try await StreamingRowExport.write(names: ["id", "id", "id_2", "json", "array"], rows: values, to: destination, format: .json)
        #expect(count == 1)
        let object = try #require((JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [[String: Any]])?.first)
        #expect(object["id"] is NSNull)
        #expect(object["id_3"] as? String == "\\N")
        #expect(object["id_2"] as? String == "12345678901234567890.123400")
        #expect(object["json"] as? String == "{ \"a\" : 1 }")
        #expect(object["array"] as? String == "{NULL,\"NULL\"}")
        let csv = directory.appendingPathComponent("exact.csv")
        _ = try await StreamingRowExport.write(names: ["value"], rows: [[.null], [.text("\\N")], [.text("")]], to: csv, format: .csv)
        #expect(try String(contentsOf: csv, encoding: .utf8) == "value\n\\N\n\"\\N\"\n\"\"")
    }

    @Test func cancellationBeforePublicationPreservesDestinationAndRemovesPartial() async throws {
        let directory = try exportDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("cancelled.csv")
        try "previous".write(to: destination, atomically: true, encoding: .utf8)
        let cancellation = ExportCancellation()
        do {
            _ = try await StreamingRowExport.write(names: ["id"], rows: (0..<300).map { [.integer(Int64($0))] }, to: destination, format: .csv, cancellation: cancellation) { count in
                if count == 128 { cancellation.cancel() }
            }
            Issue.record("Cancelled export must throw")
        } catch is CancellationError { }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "previous")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["cancelled.csv"])
    }

    @Test func invalidRowPreservesDestinationAndRemovesPartial() async throws {
        let directory = try exportDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("failed.json")
        try "previous".write(to: destination, atomically: true, encoding: .utf8)
        do {
            _ = try await StreamingRowExport.write(names: ["id"], rows: [[.integer(1)], []], to: destination, format: .json)
            Issue.record("Malformed row must fail")
        } catch let error as DatabaseUserError { #expect(error.kind == .invalidInput) }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "previous")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["failed.json"])
    }

    @Test func sqliteCancellationInsideReadQueuePreservesDestination() async throws {
        let directory = try exportDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbURL = directory.appendingPathComponent("fixture.sqlite")
        let fixture = try DatabaseQueue(path: dbURL.path)
        try await fixture.write { db in
            try db.execute(sql: "CREATE TABLE items(id INTEGER PRIMARY KEY)")
            try db.execute(sql: "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1205) INSERT INTO items SELECT x FROM n")
        }
        let service = DatabaseService()
        try await service.open(url: dbURL)
        let descriptor = try await service.fetchDescriptor(named: "items")
        let destination = directory.appendingPathComponent("cancelled.csv")
        try "previous".write(to: destination, atomically: true, encoding: .utf8)
        let cancellation = ExportCancellation()
        do {
            _ = try await service.exportTableRows(query: .init(), descriptor: descriptor, to: destination, format: .csv, cancellation: cancellation) { count in
                if count == 128 { cancellation.cancel() }
            }
            Issue.record("Cancelled database export must throw")
        } catch is CancellationError { }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "previous")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasSuffix(".partial") })
        #expect(try await service.fetchChunk(query: .init(limit: 1), descriptor: descriptor).rows.count == 1)
        await service.close()
    }

    @Test func sqliteExportUsesOneReadSnapshotDuringConcurrentInsert() async throws {
        let directory = try exportDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbURL = directory.appendingPathComponent("fixture.sqlite")
        let fixture = try DatabaseQueue(path: dbURL.path)
        try await fixture.write { db in
            try db.execute(sql: "CREATE TABLE items(id INTEGER PRIMARY KEY)")
            try db.execute(sql: "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1205) INSERT INTO items SELECT x FROM n")
        }
        let service = DatabaseService()
        try await service.open(url: dbURL)
        let descriptor = try await service.fetchDescriptor(named: "items")
        let destination = directory.appendingPathComponent("snapshot.json")
        let count = try await service.exportTableRows(query: .init(), descriptor: descriptor, to: destination, format: .json) { count in
            if count == 128 {
                do { try fixture.writeWithoutTransaction { db in try db.execute(sql: "INSERT INTO items VALUES(1206)") } }
                catch { Issue.record("Concurrent insert failed: \(error)") }
            }
        }
        #expect(count == 1205)
        let rows = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [[String: Any]])
        #expect(rows.count == 1205)
        #expect(rows.last?["id"] as? Int == 1205)
        let freshCount = try await service.countRows(query: .init(), descriptor: descriptor)
        #expect(freshCount == 1206)
        await service.close()
    }

    @Test func staleDisplayedTargetCannotExportDifferentDatabase() async throws {
        let directory = try exportDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.sqlite")
        let second = directory.appendingPathComponent("second.sqlite")
        let service = DatabaseService()
        let fixture = try DatabaseQueue(path: first.path)
        try await fixture.write { db in try db.execute(sql: "CREATE TABLE items(id INTEGER PRIMARY KEY); INSERT INTO items VALUES(1)") }
        try await service.open(url: first)
        let descriptor = try await service.fetchDescriptor(named: "items")
        try await service.open(url: second)
        let destination = directory.appendingPathComponent("result.csv")
        await #expect(throws: CancellationError.self) {
            try await service.exportTableRows(query: .init(), descriptor: descriptor, to: destination, format: .csv, expectedTarget: .sqlite(first))
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        await service.close()
    }

    private func exportDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

}
