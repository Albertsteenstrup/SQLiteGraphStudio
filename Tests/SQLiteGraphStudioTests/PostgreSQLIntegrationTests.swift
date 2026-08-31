import Foundation
import Testing
@testable import StudioCore

struct PostgreSQLIntegrationTests {
    @Test
    func optedInConnectionIsReadOnlyAndCanReadCatalog() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SGS_POSTGRES_TESTS"] == "1",
              let host = nonEmpty(environment["SGS_POSTGRES_HOST"]),
              let portText = nonEmpty(environment["SGS_POSTGRES_PORT"]),
              let port = Int(portText),
              let database = nonEmpty(environment["SGS_POSTGRES_DATABASE"]),
              let username = nonEmpty(environment["SGS_POSTGRES_USER"]),
              let password = environment["SGS_POSTGRES_PASSWORD"],
              let tlsText = nonEmpty(environment["SGS_POSTGRES_TLS"])
        else {
            return
        }

        let tlsMode: PostgresTLSMode
        switch tlsText.lowercased() {
        case "disabled":
            tlsMode = .disabled
        case "required":
            tlsMode = .required
        default:
            return
        }

        let configuration = PostgresConnectionConfiguration(
            host: host,
            port: port,
            database: database,
            username: username,
            tlsMode: tlsMode
        )
        let backend = PostgresDatabaseBackend(configuration: configuration, password: password)

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

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
