import Foundation
import Testing
@testable import StudioCore

struct PostgreSQLReadPolicyIntegrationTests {
    @Test(.enabled(if: PostgreSQLTestConfiguration.isEnabled, "Set SGS_POSTGRES_TESTS=1 to verify the PostgreSQL read policy"))
    func quotedFunctionsCannotChangeSessionStateAndLiteralReadsRemainValid() async throws {
        let config = try PostgreSQLTestConfiguration.parse(ProcessInfo.processInfo.environment)
        let backend = PostgresDatabaseBackend(configuration: config.connection, password: config.password)
        try await backend.open()
        do {
            for sql in [
                #"SELECT pg_catalog."pg_advisory_lock"(1937182461)"#,
                #"SELECT "set_config"('application_name', 'policy-bypass', false)"#,
                #"SELECT E'\'' AS first, pg_catalog.pg_advisory_lock(1937182461), E'\'' AS last"#,
                "SELECT \"pg_advisory_lock\" -- comment\r\n(1937182461)",
                #"SELECT E''"# + "\n" + #"'\'' AS first, pg_catalog.pg_advisory_lock(1937182461), E''"# + "\n" + #"'\'' AS last"#,
                #"SELECT U&"pg_advisory_\006cock"(1937182461)"#
            ] {
                do {
                    _ = try await backend.executeReadOnlyQuery(sql: sql)
                    Issue.record("A side-effect statement passed the PostgreSQL read policy")
                } catch let error as DatabaseUserError {
                    #expect(error.kind == .readOnly)
                }
            }
            let settings = try await backend.executeReadOnlyQuery(sql: "SELECT current_setting('transaction_read_only'), current_setting('standard_conforming_strings')")
            #expect(settings.rows.first?.values.map(\.displayText) == ["on", "on"])
            let literals = try await backend.executeReadOnlyQuery(sql: #"SELECT E'it\'s DELETE; pg_notify(1)' AS "pg_advisory_lock", 'C:\' AS ordinary"#)
            #expect(literals.rows.first?.values.map(\.displayText) == ["it's DELETE; pg_notify(1)", "C:\\"])
            let continued = try await backend.executeReadOnlyQuery(sql: #"SELECT E''"# + "\n" + #"'it\'s DELETE; pg_notify(1)' AS value"#)
            #expect(continued.rows.first?.values.first?.displayText == "it's DELETE; pg_notify(1)")
            await backend.close()
        } catch {
            await backend.close()
            throw error
        }
    }
}
