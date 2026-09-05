import Foundation
import Testing
@testable import StudioCore

@Suite(.serialized, .enabled(if: PostgreSQLTestConfiguration.isEnabled && ProcessInfo.processInfo.environment["SGS_POSTGRES_FIXTURE_TESTS"] == "1", "Requires explicitly opted-in owned items fixture"))
struct PostgreSQLStreamingExportTests {
    @Test func exportsAllMatchingRowsInOrderBeyondCurrentPage() async throws {
        let config = try PostgreSQLTestConfiguration.parse(ProcessInfo.processInfo.environment)
        let backend = PostgresDatabaseBackend(configuration: config.connection, password: config.password)
        try await backend.open()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let descriptor = try await backend.fetchDescriptor(named: "public.items")
            let query = TableQueryState(columnFilters: [.init(columnName: "id", value: "602", comparison: .lessThanOrEqual)], sort: .init(columnName: "id", direction: .descending), offset: 100, limit: 50)
            let chunk = try await backend.fetchChunk(query: query, descriptor: descriptor)
            #expect(chunk.rows.count == 50)
            let destination = directory.appendingPathComponent("all.json")
            let count = try await backend.exportTableRows(query: query, descriptor: descriptor, to: destination, format: .json)
            #expect(count == 602)
            let rows = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [[String: Any]])
            #expect(rows.count == 602)
            #expect(rows.first?["id"] as? Int == 602)
            #expect(rows.last?["id"] as? Int == 1)
            #expect(rows.contains { $0["label"] is NSNull })
            let unfiltered = directory.appendingPathComponent("unfiltered.csv")
            #expect(try await backend.exportTableRows(query: .init(offset: 1000, limit: 50), descriptor: descriptor, to: unfiltered, format: .csv) == 1205)
            await backend.close()
        } catch { await backend.close(); throw error }
    }

    @Test func cancellationRemovesPartialAndBackendRemainsReadOnly() async throws {
        let config = try PostgreSQLTestConfiguration.parse(ProcessInfo.processInfo.environment)
        let backend = PostgresDatabaseBackend(configuration: config.connection, password: config.password)
        try await backend.open()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let descriptor = try await backend.fetchDescriptor(named: "public.items")
            let destination = directory.appendingPathComponent("cancelled.json")
            try "previous".write(to: destination, atomically: true, encoding: .utf8)
            let cancellation = ExportCancellation()
            do {
                _ = try await backend.exportTableRows(query: .init(), descriptor: descriptor, to: destination, format: .json, cancellation: cancellation) { count in
                    if count == 128 { cancellation.cancel() }
                }
                Issue.record("Cancelled PostgreSQL export must throw")
            } catch is CancellationError { }
            #expect(try String(contentsOf: destination, encoding: .utf8) == "previous")
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["cancelled.json"])
            let setting = try await backend.executeReadOnlyQuery(sql: "SHOW transaction_read_only")
            #expect(setting.rows.first?.values.first?.displayText == "on")
            #expect(try await backend.fetchChunk(query: .init(limit: 1), descriptor: descriptor).rows.count == 1)
            await backend.close()
        } catch { await backend.close(); throw error }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_POSTGRES_FIXTURE_OWNER"] != nil, "Requires explicit owned-fixture owner role"))
    func taskCancellationBeforeFirstRowInterruptsServerAndPreservesDestination() async throws {
        try await withOwnedFixture({ schema in
            "CREATE VIEW \(schema).slow_rows AS SELECT 1 AS id FROM pg_sleep(20)"
        }) { backend, schema, directory in
            let descriptor = try await backend.fetchDescriptor(named: "\(schema).slow_rows")
            let destination = directory.appendingPathComponent("cancelled.json")
            try "previous".write(to: destination, atomically: true, encoding: .utf8)
            let started = ExportTestProgress()
            let task = Task {
                try await backend.exportTableRows(query: .init(), descriptor: descriptor, to: destination, format: .json) { started.record($0) }
            }
            defer { task.cancel() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while started.count == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(started.count == 0)
            try await Task.sleep(for: .milliseconds(150))
            let active = try await backend.executeReadOnlyQuery(sql: "SELECT pid FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND state = 'active' AND query LIKE '%\(schema)%'")
            let pid = try #require(active.rows.first?.values.first)
            let cancellationStart = ContinuousClock.now
            task.cancel()
            do { _ = try await task.value; Issue.record("Cancelled export succeeded") }
            catch { #expect(error is CancellationError) }
            #expect(cancellationStart.duration(to: .now) < .seconds(1))
            #expect(started.count == 0)
            #expect(try String(contentsOf: destination, encoding: .utf8) == "previous")
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["cancelled.json"])
            try await Task.sleep(for: .milliseconds(250))
            let activity = try await backend.executeReadOnlyQuery(sql: "SELECT count(*) FROM pg_stat_activity WHERE pid = \(pid.displayText) AND state = 'active'")
            #expect(activity.rows.first?.values.first == .integer(0))
            let setting = try await backend.executeReadOnlyQuery(sql: "SHOW transaction_read_only")
            #expect(setting.rows.first?.values.first?.displayText == "on")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_POSTGRES_FIXTURE_OWNER"] != nil, "Requires explicit owned-fixture owner role"))
    func concurrentInsertCannotEnterExportReadSnapshot() async throws {
        try await withOwnedFixture({ schema in
            "CREATE TABLE \(schema).snapshot_rows(id integer PRIMARY KEY); INSERT INTO \(schema).snapshot_rows SELECT generate_series(1,1205)"
        }) { backend, schema, directory in
            let descriptor = try await backend.fetchDescriptor(named: "\(schema).snapshot_rows")
            let destination = directory.appendingPathComponent("snapshot.json")
            let count = try await backend.exportTableRows(query: .init(sort: .init(columnName: "id", direction: .ascending)), descriptor: descriptor, to: destination, format: .json) { count in
                if count == 128 {
                    do { try Self.ownerSQL("INSERT INTO \(schema).snapshot_rows VALUES(1206)") }
                    catch { Issue.record("Owned concurrent insert failed: \(error)") }
                }
            }
            #expect(count == 1205)
            let rows = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [[String: Any]])
            #expect(rows.count == 1205)
            #expect(rows.last?["id"] as? Int == 1205)
            let freshCount = try await backend.executeReadOnlyQuery(sql: "SELECT count(*) FROM \(schema).snapshot_rows")
            #expect(freshCount.rows.first?.values.first == .integer(1206))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_POSTGRES_FIXTURE_OWNER"] != nil, "Requires explicit owned-fixture owner role"))
    func actualExportPreservesArrayBoundsTemporalPrecisionNumericAndNull() async throws {
        try await withOwnedFixture({ schema in
            """
            CREATE TABLE \(schema).exact_values(id integer PRIMARY KEY, amount numeric(30,10), observed timestamp, clock time, tags text[], document json, missing text, literal text);
            INSERT INTO \(schema).exact_values VALUES(1,12345678901234567890.1234567890,'2024-02-29 12:34:56.123456','12:34:56.000001','[0:2]={NULL,"NULL","a,b"}','{ "a" : 1 }',NULL,'NULL')
            """
        }) { backend, schema, directory in
            let descriptor = try await backend.fetchDescriptor(named: "\(schema).exact_values")
            let destination = directory.appendingPathComponent("exact.json")
            #expect(try await backend.exportTableRows(query: .init(), descriptor: descriptor, to: destination, format: .json) == 1)
            let value = try #require((JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [[String: Any]])?.first)
            #expect(value["amount"] as? String == "12345678901234567890.1234567890")
            #expect(value["observed"] as? String == "2024-02-29 12:34:56.123456")
            #expect(value["clock"] as? String == "12:34:56.000001")
            #expect(value["tags"] as? String == "[0:2]={NULL,\"NULL\",\"a,b\"}")
            #expect(value["document"] as? String == "{ \"a\" : 1 }")
            #expect(value["missing"] is NSNull)
            #expect(value["literal"] as? String == "NULL")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_POSTGRES_FIXTURE_OWNER"] != nil, "Requires explicit owned-fixture owner role"))
    func typedArraysEnumsAndMoneySupportStableNextPages() async throws {
        try await withOwnedFixture({ schema in
            """
            CREATE TYPE \(schema).stage AS ENUM ('queued','done');
            CREATE TABLE \(schema).enum_rows(id integer PRIMARY KEY, value \(schema).stage NOT NULL);
            INSERT INTO \(schema).enum_rows VALUES(1,'queued'),(2,'done');
            CREATE TABLE \(schema).array_rows(id integer PRIMARY KEY, value integer[] NOT NULL);
            INSERT INTO \(schema).array_rows VALUES(1,ARRAY[1]),(2,ARRAY[2]);
            CREATE TABLE \(schema).money_rows(id integer PRIMARY KEY, value money NOT NULL);
            INSERT INTO \(schema).money_rows VALUES(1,'-0.01'::numeric::money),(2,0::numeric::money);
            CREATE TABLE \(schema).numeric_rows(id integer PRIMARY KEY, value numeric NOT NULL);
            INSERT INTO \(schema).numeric_rows VALUES(1,'-Infinity'),(2,0),(3,'Infinity'),(4,'NaN');
            CREATE TABLE \(schema).float_rows(id integer PRIMARY KEY, value double precision NOT NULL);
            INSERT INTO \(schema).float_rows VALUES(1,'-Infinity'),(2,0),(3,'Infinity'),(4,'NaN');
            CREATE TABLE \(schema).short_text(id integer PRIMARY KEY, value varchar(3) NOT NULL, fixed char(3), fixed_array char(3)[], flags bit(4), flag_array bit(4)[]);
            INSERT INTO \(schema).short_text VALUES(1,'abc','abc',ARRAY['abc']::char(3)[],B'1010',ARRAY[B'1010']::bit(4)[])
            """
        }) { backend, schema, _ in
            for table in ["enum_rows", "array_rows", "money_rows", "numeric_rows", "float_rows"] {
                do {
                    let descriptor = try await backend.fetchDescriptor(named: "\(schema).\(table)")
                    var query = TableQueryState(sort: .init(columnName: "value", direction: .ascending), limit: 1)
                    let first = try await backend.fetchChunk(query: query, descriptor: descriptor)
                    let row = try #require(first.rows.first)
                    query.offset = 1
                    query.after = .init(values: Dictionary(uniqueKeysWithValues: zip(descriptor.columns.map(\.name), row.values)))
                    let second = try await backend.fetchChunk(query: query, descriptor: descriptor)
                    #expect(second.rows.first?.values.first == .integer(2))
                    var page = second
                    var seen = [row.values[0]] + second.rows.map { $0.values[0] }
                    for _ in 0..<5 where page.hasMore {
                        let last = try #require(page.rows.last)
                        query.offset = seen.count
                        query.after = .init(values: Dictionary(uniqueKeysWithValues: zip(descriptor.columns.map(\.name), last.values)))
                        page = try await backend.fetchChunk(query: query, descriptor: descriptor)
                        seen += page.rows.map { $0.values[0] }
                    }
                    #expect(seen == (1...(table == "numeric_rows" || table == "float_rows" ? 4 : 2)).map { .integer(Int64($0)) })
                    #expect(!page.hasMore)
                    let exact = try await backend.fetchChunk(query: .init(columnFilters: [.init(columnName: "value", value: ResultSerialization.exactText(row.values[1]), comparison: .equal)]), descriptor: descriptor)
                    #expect(exact.rows.count == 1)
                } catch { Issue.record("Typed paging failed for \(table): \(error)") }
            }
            let short = try await backend.fetchDescriptor(named: "\(schema).short_text")
            for (column, value) in [("flags", "1010"), ("flag_array", "{1010}")] {
                let match = try await backend.fetchChunk(query: .init(columnFilters: [.init(columnName: column, value: value, comparison: .equal)]), descriptor: short)
                #expect(match.rows.count == 1)
            }
            for (column, value) in [("value", "abcd"), ("fixed", "abcd"), ("fixed_array", #"{"abcd"}"#), ("flags", "101011"), ("flag_array", "{101011}")] {
                let noMatch = try await backend.fetchChunk(query: .init(columnFilters: [.init(columnName: column, value: value, comparison: .equal)]), descriptor: short)
                #expect(noMatch.rows.isEmpty)
            }
        }
    }

    private func withOwnedFixture(_ definition: (String) -> String,
                                  body: (PostgresDatabaseBackend, String, URL) async throws -> Void) async throws {
        let config = try PostgreSQLTestConfiguration.parse(ProcessInfo.processInfo.environment)
        let schema = "sgs_export_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            do { try Self.ownerSQL("DROP SCHEMA IF EXISTS \(schema) CASCADE") }
            catch { Issue.record("Owned export fixture cleanup failed: \(error)") }
        }
        let reader = "\"" + config.connection.username.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        try Self.ownerSQL("CREATE SCHEMA \(schema); \(definition(schema)); GRANT USAGE ON SCHEMA \(schema) TO \(reader); GRANT SELECT ON ALL TABLES IN SCHEMA \(schema) TO \(reader)")
        let backend = PostgresDatabaseBackend(configuration: config.connection, password: config.password)
        do {
            try await backend.open()
            try await body(backend, schema, directory)
            await backend.close()
        } catch { await backend.close(); throw error }
    }

    private static func ownerSQL(_ sql: String) throws {
        let environment = ProcessInfo.processInfo.environment
        let config = try PostgreSQLTestConfiguration.parse(environment)
        guard let owner = environment["SGS_POSTGRES_FIXTURE_OWNER"], !owner.isEmpty else {
            throw DatabaseUserError(kind: .invalidInput, message: "Set SGS_POSTGRES_FIXTURE_OWNER explicitly for owned-fixture writes.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: environment["SGS_POSTGRES_PSQL"] ?? "/opt/homebrew/opt/postgresql@17/bin/psql")
        process.arguments = ["-X", "-v", "ON_ERROR_STOP=1", "-h", config.connection.host, "-p", String(config.connection.port), "-U", owner, "-d", config.connection.database, "-c", sql]
        var childEnvironment = environment
        childEnvironment["PGPASSWORD"] = environment["SGS_POSTGRES_FIXTURE_OWNER_PASSWORD"] ?? ""
        childEnvironment["PGCONNECT_TIMEOUT"] = "5"
        childEnvironment["PGOPTIONS"] = "-c statement_timeout=5000 -c lock_timeout=2000"
        process.environment = childEnvironment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let message = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DatabaseUserError(kind: .generic, message: "Owned export fixture SQL failed: \(String(decoding: message, as: UTF8.self))")
        }
    }

}


private final class ExportTestProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int?
    var count: Int? { lock.withLock { value } }
    func record(_ count: Int) { lock.withLock { value = count } }
}
