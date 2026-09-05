import Foundation
import Testing
@testable import StudioCore

@Suite(.serialized)
struct PostgreSQLIntegrationTests {
    @Test(.enabled(if: PostgreSQLTestConfiguration.isEnabled, "Set SGS_POSTGRES_TESTS=1 to run PostgreSQL integration tests"))
    func optedInConnectionIsReadOnlyAndCanReadCatalog() async throws {
        let config = try PostgreSQLTestConfiguration.parse(ProcessInfo.processInfo.environment)
        let backend = PostgresDatabaseBackend(configuration: config.connection, password: config.password)

        do {
            try await backend.open()
            let setting = try await backend.executeReadOnlyQuery(
                sql: "SELECT current_setting('transaction_read_only') AS read_only"
            )
            #expect(setting.rows.first?.values.first?.displayText.lowercased() == "on")

            let snapshot = try await backend.loadCatalogSnapshot()
            #expect(snapshot.descriptors.allSatisfy { $0.schemaName != "pg_catalog" && $0.schemaName != "information_schema" })
            #expect(snapshot.descriptors.allSatisfy { !($0.schemaName ?? "").hasPrefix("pg_temp_") })

            let visibleObjectCount = try await backend.executeReadOnlyQuery(sql: """
                SELECT count(*) AS object_count
                FROM pg_catalog.pg_class AS c
                JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
                WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
                  AND n.nspname !~ '^pg_temp_'
                  AND c.relkind IN ('r', 'p', 'v', 'm')
                  AND has_schema_privilege(n.oid, 'USAGE')
                  AND has_table_privilege(c.oid, 'SELECT')
                """)
            #expect(visibleObjectCount.rows.first?.values.first?.displayText == String(snapshot.descriptors.count))
            #expect(snapshot.graph.nodes.count == snapshot.descriptors.count)

            let metadataCounts = try await backend.executeReadOnlyQuery(sql: """
                SELECT
                  (SELECT count(*) FROM pg_catalog.pg_trigger t WHERE t.tgrelid = c.oid AND NOT t.tgisinternal) AS triggers,
                  (SELECT count(*) FROM pg_catalog.pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'c') AS checks
                FROM pg_catalog.pg_class c
                JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
                  AND n.nspname !~ '^pg_temp_'
                  AND c.relkind IN ('r', 'p', 'v', 'm')
                  AND has_schema_privilege(n.oid, 'USAGE')
                  AND has_table_privilege(c.oid, 'SELECT')
                """, rowLimit: max(snapshot.descriptors.count, 1))
            let expectedTriggers = metadataCounts.rows.reduce(0) { $0 + (Int($1.values[0].displayText) ?? 0) }
            let expectedChecks = metadataCounts.rows.reduce(0) { $0 + (Int($1.values[1].displayText) ?? 0) }
            #expect(snapshot.descriptors.reduce(0) { $0 + $1.triggers.count } == expectedTriggers)
            #expect(snapshot.descriptors.reduce(0) { $0 + $1.constraints.filter { $0.kind == .check }.count } == expectedChecks)
            await Self.verifySharedExploration(snapshot: snapshot)

            let scalar = try await backend.executeReadOnlyQuery(sql: "SELECT 1 AS value")
            #expect(scalar.rows.first?.values.first == .integer(1))
            _ = try await backend.explainQueryPlan(sql: "SELECT 1")

            await #expect(throws: DatabaseUserError.self) {
                try await backend.executeReadOnlyQuery(
                    sql: "CREATE TEMP TABLE sgs_read_only_probe(value integer)"
                )
            }
            await backend.close()
        } catch {
            await backend.close()
            throw error
        }
    }

    @Test(.enabled(if: PostgreSQLTestConfiguration.isEnabled, "Set SGS_POSTGRES_TESTS=1 to run PostgreSQL integration tests"))
    func fetchingStopsAtRequestedRowLimit() async throws {
        let config = try PostgreSQLTestConfiguration.parse(ProcessInfo.processInfo.environment)
        let backend = PostgresDatabaseBackend(configuration: config.connection, password: config.password)
        try await backend.open()
        do {
            let clock = ContinuousClock()
            let start = clock.now
            let result = try await backend.executeReadOnlyQuery(sql: "SELECT n, pg_sleep(0.01) FROM generate_series(1, 200) AS n", rowLimit: 5)
            #expect(result.rows.count == 5)
            #expect(result.isTruncated)
            #expect(start.duration(to: clock.now) < .seconds(1))
            await backend.close()
        } catch { await backend.close(); throw error }
    }

    @Test(.enabled(if: PostgreSQLTestConfiguration.isEnabled, "Set SGS_POSTGRES_TESTS=1 to run PostgreSQL integration tests"))
    func cancellationStopsServerWorkAndBackendCanBeReused() async throws {
        let config = try PostgreSQLTestConfiguration.parse(ProcessInfo.processInfo.environment)
        let backend = PostgresDatabaseBackend(configuration: config.connection, password: config.password)
        try await backend.open()
        do {
            let task = Task { try await backend.executeReadOnlyQuery(sql: "SELECT pg_sleep(20) AS sgs_cancel_probe") }
            try await Task.sleep(for: .milliseconds(150))
            let running = try await backend.executeReadOnlyQuery(sql: "SELECT pid FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND state = 'active' AND query = 'FETCH FORWARD 501 FROM sgs_query_cursor'")
            let pidValue = try #require(running.rows.first?.values.first)
            guard case .integer(let pid) = pidValue else { throw CancellationError() }
            let start = ContinuousClock.now
            task.cancel()
            do { _ = try await task.value; Issue.record("Cancelled PostgreSQL query succeeded") } catch { }
            #expect(start.duration(to: .now) < .seconds(1))
            try await Task.sleep(for: .milliseconds(250))
            let activity = try await backend.executeReadOnlyQuery(sql: "SELECT count(*) FROM pg_stat_activity WHERE pid = \(pid) AND state = 'active'")
            #expect(activity.rows.first?.values.first == .integer(0))
            let setting = try await backend.executeReadOnlyQuery(sql: "SHOW transaction_read_only")
            #expect(setting.rows.first?.values.first?.displayText == "on")
            await backend.close()
        } catch { await backend.close(); throw error }
    }

    @Test(.enabled(if: PostgreSQLTestConfiguration.isEnabled, "Set SGS_POSTGRES_TESTS=1 to run PostgreSQL integration tests"))
    func timeoutStopsWorkAndReadStatementsKeepTheirSemantics() async throws {
        let config = try PostgreSQLTestConfiguration.parse(ProcessInfo.processInfo.environment)
        let backend = PostgresDatabaseBackend(configuration: config.connection, password: config.password)
        try await backend.open()
        do {
            do {
                _ = try await backend.executeReadOnlyQuery(sql: "SELECT pg_sleep(20)", timeoutSeconds: 0.1)
                Issue.record("Expected PostgreSQL timeout")
            } catch let error as DatabaseUserError { #expect(error.kind == .timeout) }
            for sql in ["/* leading */ VALUES (1), (2); -- trailing", "WITH n AS (SELECT 1 AS x UNION ALL SELECT 2) SELECT * FROM n;", "SELECT ';' AS text /* ; */;", "/* leading */ SHOW transaction_read_only", "-- leading\n EXPLAIN SELECT 1"] {
                let result = try await backend.executeReadOnlyQuery(sql: sql, rowLimit: 1)
                #expect(result.rows.count == 1)
            }
            let duplicate = try await backend.executeReadOnlyQuery(sql: "SELECT 1 AS id, 2 AS id")
            #expect(duplicate.rows.first?.values == [.integer(1), .integer(2)])
            #expect(Set(duplicate.columns.map(\.id)).count == 2)
            let exact = try await backend.executeReadOnlyQuery(sql: "VALUES (1), (2)", rowLimit: 2)
            #expect(!exact.isTruncated)
            let empty = try await backend.executeReadOnlyQuery(sql: "SELECT 1 AS label WHERE false")
            #expect(empty.columns.map(\.name) == ["label"])
            #expect(empty.rows.isEmpty)
            _ = try await backend.explainQueryPlan(sql: "/* comment */ EXPLAIN SELECT 1")
            await backend.close()
        } catch { await backend.close(); throw error }
    }

    @Test(.enabled(if: PostgreSQLTestConfiguration.isEnabled, "Set SGS_POSTGRES_TESTS=1 to run PostgreSQL integration tests"))
    func repeatedEarlyCancellationLeavesPoolReusable() async throws {
        let config = try PostgreSQLTestConfiguration.parse(ProcessInfo.processInfo.environment)
        let backend = PostgresDatabaseBackend(configuration: config.connection, password: config.password)
        try await backend.open()
        do {
            for index in 0..<300 {
                let task = Task { try await backend.executeReadOnlyQuery(sql: "SELECT pg_sleep(1)") }
                if index % 3 != 0 { try await Task.sleep(for: .microseconds(100 * (index % 30))) }
                task.cancel()
                do { _ = try await task.value; Issue.record("Early cancellation returned a result") } catch { }
            }
            let result = try await backend.executeReadOnlyQuery(sql: "SELECT 123")
            #expect(result.rows.first?.values == [.integer(123)])
            await backend.close()
        } catch { await backend.close(); throw error }
    }

    @Test(.enabled(if: PostgreSQLTestConfiguration.isEnabled, "Set SGS_POSTGRES_TESTS=1 to run PostgreSQL integration tests"))
    func utilityResponsesStopAtCapAndReplaceTheirConnection() async throws {
        let config = try PostgreSQLTestConfiguration.parse(ProcessInfo.processInfo.environment)
        let backend = PostgresDatabaseBackend(configuration: config.connection, password: config.password)
        try await backend.open()
        do {
            var previousPID = try await backend.executeReadOnlyQuery(sql: "SELECT pg_backend_pid()")
            for sql in ["SHOW ALL", "EXPLAIN SELECT n FROM generate_series(1, 10) AS n ORDER BY n"] {
                let result = try await backend.executeReadOnlyQuery(sql: sql, rowLimit: 1)
                #expect(result.rows.count == 1)
                #expect(result.isTruncated)
                #expect(!result.columns.isEmpty)
                if sql == "SHOW ALL" {
                    #expect(result.columns.map(\.name) == ["name", "setting", "description"])
                }
                let replacement = try await backend.executeReadOnlyQuery(sql: "SELECT pg_backend_pid(), current_setting('transaction_read_only')")
                #expect(replacement.rows.first?.values.first != previousPID.rows.first?.values.first)
                #expect(replacement.rows.first?.values.last?.displayText == "on")
                previousPID = replacement
            }
            let plan = try await backend.explainQueryPlan(sql: "SELECT n FROM generate_series(1, 10) AS n ORDER BY n")
            #expect(plan.count > 1)
            await backend.close()
        } catch { await backend.close(); throw error }
    }

    @Test(.enabled(if: PostgreSQLTestConfiguration.isEnabled, "Set SGS_POSTGRES_TESTS=1 to verify exact special numeric values"))
    func numericSpecialsMoneyAndScaleSurviveTheWire() async throws {
        let config = try PostgreSQLTestConfiguration.parse(ProcessInfo.processInfo.environment)
        let backend = PostgresDatabaseBackend(configuration: config.connection, password: config.password)
        try await backend.open()
        do {
            let result = try await backend.executeReadOnlyQuery(sql: "SELECT 'NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric, 1.2::numeric(20,8), '-0.01'::numeric::money, ARRAY[1::numeric(20,8)]")
            #expect(result.rows.first?.values == [.exactNumeric("NaN"), .exactNumeric("Infinity"), .exactNumeric("-Infinity"), .exactNumeric("1.20000000"), .exactNumeric("-0.01"), .array(#"{"1.00000000"}"#)])
            await backend.close()
        } catch { await backend.close(); throw error }
    }

    @MainActor
    private static func verifySharedExploration(snapshot: CatalogSnapshot) {
        let descriptors = Dictionary(uniqueKeysWithValues: snapshot.descriptors.map { ($0.name, $0) })
        let grouping = GraphGrouping.resolve(graph: snapshot.graph, descriptors: descriptors)
        #expect(grouping.nodeCount == snapshot.graph.nodes.count)
        let layout = GraphLayoutModel()
        layout.setClusterHints(grouping.nodeToGroup)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            layout.reset(for: snapshot.graph, presentation: .compact, descriptorLookup: { descriptors[$0] })
            layout.stabilize(graph: snapshot.graph, presentation: .compact,
                             descriptorLookup: { descriptors[$0] }, nodeSizeLookup: nil)
        }
        let positions = layout.allPositions(for: snapshot.graph)
        #expect(positions.count == snapshot.graph.nodes.count)
        #expect(positions.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        let sizes = Dictionary(uniqueKeysWithValues: snapshot.graph.nodes.map {
            ($0.id, GraphCardLayout.nodeSize(title: $0.title, descriptor: descriptors[$0.id], style: .collapsed, hovered: false))
        })
        if snapshot.graph.nodes.count > GraphLayoutModel.largeGraphOverviewThreshold {
            #expect(LargeGraphLayout.isNonOverlapping(positions, sizes: sizes))
        }
        print("Live PostgreSQL: \(snapshot.graph.nodes.count) objects, \(snapshot.graph.edges.count) relationships, \(grouping.groupCount) groups; shared layout \(elapsed)")
    }

    @Test(.enabled(if: PostgreSQLTestConfiguration.isEnabled, "Set SGS_POSTGRES_TESTS=1 to run PostgreSQL integration tests"))
    func startingAQueryAfterLeaseClosureCompletesWithAnError() async throws {
        let config = try PostgreSQLTestConfiguration.parse(ProcessInfo.processInfo.environment)
        let backend = PostgresDatabaseBackend(configuration: config.connection, password: config.password)
        try await backend.open()
        let completion = ClosedLeaseQueryCompletion()
        let task = Task {
            defer { completion.finish() }
            do {
                try await backend.withReadOnlyTransaction { connection in
                    try await connection.close()
                    _ = try await PostgresDatabaseBackend.querySequence("SELECT 1", on: connection)
                }
                Issue.record("A query on a closed lease unexpectedly succeeded")
            } catch { }
        }
        // Keep the regression itself bounded even if the driver strands its
        // response promise. The external runner also enforces a process deadline.
        try await Task.sleep(for: .milliseconds(300))
        #expect(completion.didFinish, "A closed-channel query stranded its response promise")
        if completion.didFinish {
            await task.value
            await backend.close()
        } else {
            task.cancel()
        }
    }

    @Test(.enabled(if: PostgreSQLTestConfiguration.isEnabled, "Set SGS_POSTGRES_TESTS=1 to run PostgreSQL integration tests"))
    func cancellationAroundFailedStatementRollbackKeepsPoolReusable() async throws {
        let config = try PostgreSQLTestConfiguration.parse(ProcessInfo.processInfo.environment)
        let backend = PostgresDatabaseBackend(configuration: config.connection, password: config.password)
        try await backend.open()
        do {
            for index in 0..<300 {
                let failureReached = ClosedLeaseQueryCompletion()
                let task = Task {
                    do {
                        try await backend.withReadOnlyTransaction { connection in
                            do {
                                let rows = try await PostgresDatabaseBackend.querySequence("SELECT 1 / 0", on: connection)
                                for try await _ in rows { }
                            } catch {
                                failureReached.finish()
                                throw error
                            }
                        }
                    } catch { }
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while !failureReached.didFinish, ContinuousClock.now < deadline { await Task.yield() }
                #expect(failureReached.didFinish)
                if index % 3 != 0 { try await Task.sleep(for: .microseconds(50 * (index % 3))) }
                task.cancel()
                await task.value
                let reused = try await backend.executeReadOnlyQuery(sql: "SELECT 123")
                #expect(reused.rows.first?.values == [.integer(123)])
            }
            await backend.close()
        } catch { await backend.close(); throw error }
    }

}

struct PostgreSQLTestConfiguration {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["SGS_POSTGRES_TESTS"] == "1" }
    let connection: PostgresConnectionConfiguration
    let password: String

    static func parse(_ environment: [String: String]) throws -> Self {
        func required(_ key: String) throws -> String {
            guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                throw ConfigurationError.invalid(key)
            }
            return value
        }
        guard environment["SGS_POSTGRES_TESTS"] == "1" else { throw ConfigurationError.invalid("SGS_POSTGRES_TESTS") }
        let host = try required("SGS_POSTGRES_HOST")
        let portText = try required("SGS_POSTGRES_PORT")
        guard let port = Int(portText), (1...65535).contains(port) else { throw ConfigurationError.invalid("SGS_POSTGRES_PORT") }
        let database = try required("SGS_POSTGRES_DATABASE")
        let username = try required("SGS_POSTGRES_USER")
        guard let password = environment["SGS_POSTGRES_PASSWORD"] else { throw ConfigurationError.invalid("SGS_POSTGRES_PASSWORD") }
        let tlsMode: PostgresTLSMode
        switch try required("SGS_POSTGRES_TLS").lowercased() {
        case "disabled": tlsMode = .disabled
        case "required": tlsMode = .required
        default: throw ConfigurationError.invalid("SGS_POSTGRES_TLS")
        }
        return Self(connection: .init(host: host, port: port, database: database, username: username, tlsMode: tlsMode), password: password)
    }

    enum ConfigurationError: Error, CustomStringConvertible {
        case invalid(String)
        var description: String {
            switch self { case .invalid(let key): "PostgreSQL integration test configuration is missing or invalid: \(key)" }
        }
    }
}

struct PostgreSQLIntegrationConfigurationTests {
    private var valid: [String: String] {
        ["SGS_POSTGRES_TESTS": "1", "SGS_POSTGRES_HOST": "localhost", "SGS_POSTGRES_PORT": "5432", "SGS_POSTGRES_DATABASE": "test", "SGS_POSTGRES_USER": "reader", "SGS_POSTGRES_PASSWORD": "", "SGS_POSTGRES_TLS": "disabled"]
    }
    @Test func acceptsExplicitConfigurationIncludingEmptyPassword() throws {
        let config = try PostgreSQLTestConfiguration.parse(valid)
        #expect(config.password.isEmpty)
        #expect(config.connection.port == 5432)
    }
    @Test func missingOptInConfigurationFails() {
        for key in valid.keys {
            var environment = valid
            environment.removeValue(forKey: key)
            #expect(throws: PostgreSQLTestConfiguration.ConfigurationError.self) { try PostgreSQLTestConfiguration.parse(environment) }
        }
    }
    @Test func invalidTLSAndPortsFail() {
        for (key, values) in ["SGS_POSTGRES_TLS": ["", "prefer", "garbage"], "SGS_POSTGRES_PORT": ["", "abc", "0", "65536", "-1"]] {
            for value in values {
                var environment = valid
                environment[key] = value
                #expect(throws: PostgreSQLTestConfiguration.ConfigurationError.self) { try PostgreSQLTestConfiguration.parse(environment) }
            }
        }
    }
}

private final class ClosedLeaseQueryCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    var didFinish: Bool { lock.withLock { finished } }
    func finish() { lock.withLock { finished = true } }
}
