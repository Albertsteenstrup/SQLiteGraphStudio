import Foundation
import PostgresNIO
import Testing
@testable import StudioCore

struct PostgreSQLSupportTests {
    @Test
    func postgresDocumentsDecodeWithoutCredentials() throws {
        let json = """
        {
          "name": "Catalog",
          "host": "db.example.test",
          "port": 5432,
          "database": "catalog",
          "username": "reader",
          "tlsMode": "required"
        }
        """

        let document = try JSONDecoder().decode(
            PostgresConnectionDocument.self,
            from: Data(json.utf8)
        )

        #expect(document.displayName == "Catalog")
        #expect(document.configuration.host == "db.example.test")
        #expect(document.configuration.username == "reader")
    }

    @Test
    func postgresDocumentsUseSafeDefaultsForOptionalEndpointSettings() throws {
        let json = """
        {
          "host": "db.example.test",
          "database": "catalog",
          "username": "reader"
        }
        """

        let document = try JSONDecoder().decode(
            PostgresConnectionDocument.self,
            from: Data(json.utf8)
        )

        #expect(document.port == 5432)
        #expect(document.tlsMode == .required)
    }

    @Test
    func postgresDocumentsEncodeOnlyEndpointProperties() throws {
        let document = PostgresConnectionDocument(
            name: "Catalog",
            host: "db.example.test",
            port: 5432,
            database: "catalog",
            username: "reader",
            tlsMode: .required
        )

        let data = try JSONEncoder().encode(document)
        let encoded = try #require(String(data: data, encoding: .utf8))

        #expect(encoded.contains("db.example.test"))
        #expect(encoded.contains("reader"))
        #expect(!encoded.localizedCaseInsensitiveContains("password"))
        #expect(!encoded.localizedCaseInsensitiveContains("credential"))
    }

    @Test
    func postgresTargetIdentityIsStableAndPasswordFree() {
        let first = DatabaseTarget.postgres(
            PostgresConnectionConfiguration(
                host: "127.0.0.1",
                port: 5432,
                database: "catalog",
                username: "reader",
                tlsMode: .disabled
            )
        )
        let second = DatabaseTarget.postgres(
            PostgresConnectionConfiguration(
                host: "127.0.0.1",
                port: 5432,
                database: "catalog",
                username: "reader",
                tlsMode: .disabled
            )
        )

        #expect(first.identity == second.identity)
        #expect(first.identity.contains("127.0.0.1"))
        #expect(!first.identity.localizedCaseInsensitiveContains("password"))
    }

    @Test
    func postgresCapabilitiesCloseEveryMutationGate() {
        let capabilities = DatabaseCapabilities.postgresReadOnly

        #expect(capabilities.isReadOnly)
        #expect(!capabilities.canEditRows)
        #expect(!capabilities.canInsertRows)
        #expect(!capabilities.canDeleteRows)
        #expect(!capabilities.canImportRows)
        #expect(!capabilities.canCreateTable)
        #expect(!capabilities.canAlterSchema)
        #expect(!capabilities.canDropColumns)
        #expect(!capabilities.canWriteSQL)
    }

    @Test
    func postgresIdentifiersAreSchemaQualifiedAndQuoted() {
        #expect(qualifiedIdentifier(schema: "sales", object: "order items") == "\"sales\".\"order items\"")
        #expect(qualifiedIdentifier(schema: "weird\"schema", object: "a\"b") == "\"weird\"\"schema\".\"a\"\"b\"")
    }

    @Test
    func postgresSQLPolicyAllowsReadsAndRejectsMutationBypasses() throws {
        let allowed = [
            "SELECT 1",
            "  -- leading comment\n VALUES (1)",
            "SHOW transaction_read_only",
            "WITH rows AS (SELECT 1) SELECT * FROM rows",
            "/* comment; */ SELECT 'DELETE; DROP' AS statement; -- trailing comment",
            "SELECT \"DELETE\" FROM \"users\"",
            "SELECT $$DELETE; DROP TABLE users$$ AS body"
        ]
        for sql in allowed {
            #expect(try ReadOnlySQLPolicy.validate(sql) == nil)
        }

        let rejected = [
            "INSERT INTO users VALUES (1)",
            "WITH changed AS (DELETE FROM users RETURNING id) SELECT * FROM changed",
            "SELECT 1; DELETE FROM users",
            "/* DELETE */ SELECT 1; DROP TABLE users",
            "CREATE TEMP TABLE graph_studio_probe(id integer)",
            "EXPLAIN ANALYZE SELECT 1",
            "SET statement_timeout = 1",
            "DO $$ BEGIN PERFORM 1; END $$",
            "SELECT 1;;",
            "SELECT 1; /* trailing */ DELETE FROM users",
            "SELECT pg_advisory_lock(1)",
            "SELECT pg_notify('channel', 'payload')",
            "SELECT /* unterminated"
        ]
        for sql in rejected {
            #expect(throws: DatabaseUserError.self) {
                try ReadOnlySQLPolicy.validate(sql)
            }
        }
    }

    @Test
    func postgresTableQueryUsesBoundValuesAndQualifiedIdentifiers() throws {
        let descriptor = TableDescriptor(
            name: "public.items",
            schemaName: "public",
            objectName: "items",
            objectType: .table,
            columns: [
                TableColumn(name: "id", declaredType: "integer", notNull: true, defaultValueSQL: nil, primaryKeyOrdinal: 1, hiddenValue: 0),
                TableColumn(name: "label", declaredType: "text", notNull: false, defaultValueSQL: nil, primaryKeyOrdinal: 0, hiddenValue: 0)
            ],
            primaryKeyColumns: ["id"],
            rowIdentityStrategy: .readOnly,
            isWithoutRowID: false,
            isEditable: false,
            rowCount: 12
        )

        let plan = try PostgresTableQueryBuilder.makePlan(
            query: TableQueryState(
                searchText: "O'Reilly",
                columnFilters: [ColumnFilter(columnName: "label", value: "draft")],
                sort: SortState(columnName: "label", direction: .descending),
                offset: 20,
                limit: 10
            ),
            descriptor: descriptor
        )

        #expect(plan.selectSQL.contains("\"public\".\"items\""))
        #expect(plan.selectSQL.contains("$1"))
        #expect(plan.selectSQL.contains("$2"))
        #expect(plan.selectSQL.contains("$3"))
        #expect(!plan.selectSQL.contains("O'Reilly"))
        #expect(plan.parameters == [
            PostgresQueryParameter.text("%O'Reilly%"),
            PostgresQueryParameter.text("%draft%"),
            PostgresQueryParameter.integer(10),
            PostgresQueryParameter.integer(20)
        ])
    }

    @Test
    func postgresCatalogMapperPreservesObjectsConstraintsAndCompositeRelations() {
        let objects = [
            PostgresCatalogObject(schemaName: "public", objectName: "customers", relkind: "r", rowEstimate: 2.4),
            PostgresCatalogObject(schemaName: "public", objectName: "orders", relkind: "r", rowEstimate: 42.4),
            PostgresCatalogObject(schemaName: "public", objectName: "order_archive", relkind: "p", rowEstimate: nil),
            PostgresCatalogObject(schemaName: "reporting", objectName: "order_view", relkind: "v", rowEstimate: nil),
            PostgresCatalogObject(schemaName: "reporting", objectName: "order_materialized", relkind: "m", rowEstimate: 10)
        ]
        let columns = [
            PostgresCatalogColumn(
                schemaName: "public",
                objectName: "customers",
                name: "id",
                declaredType: "bigint",
                notNull: true,
                defaultValueSQL: "generated by default as identity",
                ordinal: 1,
                identityKind: "d"
            ),
            PostgresCatalogColumn(
                schemaName: "public",
                objectName: "customers",
                name: "region",
                declaredType: "text",
                notNull: true,
                defaultValueSQL: nil,
                ordinal: 2
            ),
            PostgresCatalogColumn(
                schemaName: "public",
                objectName: "orders",
                name: "customer_id",
                declaredType: "bigint",
                notNull: true,
                defaultValueSQL: nil,
                ordinal: 1
            ),
            PostgresCatalogColumn(
                schemaName: "public",
                objectName: "orders",
                name: "region",
                declaredType: "text",
                notNull: false,
                defaultValueSQL: nil,
                ordinal: 2
            ),
            PostgresCatalogColumn(
                schemaName: "public",
                objectName: "orders",
                name: "total",
                declaredType: "numeric(12,2)",
                notNull: false,
                defaultValueSQL: "0",
                ordinal: 3,
                generatedKind: "s"
            )
        ]
        let indexes = [
            PostgresCatalogIndex(
                schemaName: "public",
                objectName: "customers",
                name: "customers_pkey",
                columns: ["id", "region"],
                isUnique: true,
                isPrimary: true,
                isPartial: false
            ),
            PostgresCatalogIndex(
                schemaName: "public",
                objectName: "orders",
                name: "orders_customer_region_idx",
                columns: ["customer_id", "region"],
                isUnique: false,
                isPrimary: false,
                isPartial: false
            )
        ]
        let foreignKeys = [
            PostgresCatalogForeignKey(
                id: "100",
                constraintName: "orders_customer_fk",
                sourceSchemaName: "public",
                sourceObjectName: "orders",
                sourceColumns: ["customer_id", "region"],
                targetSchemaName: "public",
                targetObjectName: "customers",
                targetColumns: ["id", "region"]
            )
        ]

        let snapshot = PostgresCatalogMapper.makeSnapshot(
            objects: objects,
            columns: columns,
            indexes: indexes,
            foreignKeys: foreignKeys
        )

        let orders = snapshot.descriptors.first { $0.name == "public.orders" }
        #expect(orders?.qualifiedSQLIdentifier == "\"public\".\"orders\"")
        #expect(orders?.rowCount == 42)
        #expect(orders?.isEditable == false)
        #expect(orders?.columns.map(\.name) == ["customer_id", "region", "total"])
        #expect(orders?.generatedColumns.map(\.name) == ["total"])
        #expect(orders?.constraints.contains { $0.kind == .foreignKey && $0.columns.count == 2 } == true)
        #expect(
            snapshot.descriptors.first { $0.name == "public.customers" }?.identityColumns.map(\.name) == ["id"]
        )
        #expect(snapshot.descriptors.first { $0.name == "public.order_archive" }?.objectType == .partitionedTable)
        #expect(snapshot.descriptors.first { $0.name == "reporting.order_view" }?.objectType == .view)
        #expect(snapshot.descriptors.first { $0.name == "reporting.order_materialized" }?.objectType == .materializedView)
        #expect(snapshot.graph.edges.count == 2)
        #expect(snapshot.graph.edges.allSatisfy { $0.cardinality == .manyToOne })
        #expect(snapshot.graph.edges.map(\.sourceColumn) == ["customer_id", "region"])
        #expect(snapshot.graph.edges.map(\.targetColumn) == ["id", "region"])
    }

    @Test
    func postgresValueMapperKeepsNativeAndLosslessPostgresRepresentations() {
        let uuid = UUID(uuidString: "7C9E6679-7425-40DE-944B-E07FC1F90AE7")!
        let numeric = PostgresData(numeric: PostgresNumeric(string: "1234567890.1200")!)
        let json = PostgresData(json: Data(#"{"name":"Ada"}"#.utf8))
        let jsonb = PostgresData(jsonb: Data(#"{"active":true}"#.utf8))
        let array = PostgresData(
            array: [PostgresData(string: "first"), PostgresData(string: "second")],
            elementType: .text
        )
        let binary = PostgresData(bytes: [0x00, 0xFF, 0x10])

        #expect(PostgresValueMapper.map(.null) == .null)
        #expect(PostgresValueMapper.map(PostgresData(bool: true)) == .boolean(true))
        #expect(PostgresValueMapper.map(PostgresData(int64: 42)) == .integer(42))
        #expect(PostgresValueMapper.map(numeric) == .exactNumeric("1234567890.1200"))
        #expect(PostgresValueMapper.map(PostgresData(uuid: uuid)) == .uuid(uuid.uuidString))
        #expect(PostgresValueMapper.map(json) == .json(#"{"name":"Ada"}"#))
        #expect(PostgresValueMapper.map(jsonb) == .json(#"{"active":true}"#))
        #expect(PostgresValueMapper.map(array) == .array(#"{"first","second"}"#))
        #expect(PostgresValueMapper.map(binary) == .blob(Data([0x00, 0xFF, 0x10])))
    }

    @Test
    func postgresBackendFailsClosedForEveryMutationAPI() async {
        let backend = PostgresDatabaseBackend(
            configuration: PostgresConnectionConfiguration(
                host: "127.0.0.1",
                database: "catalog",
                username: "reader",
                tlsMode: .disabled
            ),
            password: "never-logged"
        )
        let descriptor = TableDescriptor(
            name: "public.items",
            schemaName: "public",
            objectName: "items",
            objectType: .table,
            columns: [],
            primaryKeyColumns: [],
            rowIdentityStrategy: .readOnly,
            isWithoutRowID: false,
            isEditable: false
        )
        let change = CellEditChange(
            descriptor: descriptor,
            rowIdentity: .primaryKey([]),
            columnName: "value",
            rawValue: "changed"
        )

        await #expect(throws: DatabaseUserError.self) {
            try await backend.commitEdit(change)
        }
        await #expect(throws: DatabaseUserError.self) {
            try await backend.insertDefaultRow(into: descriptor)
        }
        await #expect(throws: DatabaseUserError.self) {
            try await backend.insertClonedRow(
                from: TableRow(identity: .primaryKey([]), values: []),
                into: descriptor
            )
        }
        await #expect(throws: DatabaseUserError.self) {
            try await backend.deleteRow(.primaryKey([]), from: descriptor)
        }
        await #expect(throws: DatabaseUserError.self) {
            try await backend.dropColumn(columnName: "value", from: descriptor)
        }
        await #expect(throws: DatabaseUserError.self) {
            try await backend.createTable(TableCreateDraft(tableName: "blocked"))
        }
        await #expect(throws: DatabaseUserError.self) {
            try await backend.renameTable(from: "items", to: "renamed")
        }
        await #expect(throws: DatabaseUserError.self) {
            try await backend.addColumn(TableColumnDraft(name: "blocked"), to: descriptor)
        }
        await #expect(throws: DatabaseUserError.self) {
            try await backend.renameColumn(from: "value", to: "blocked", in: descriptor)
        }
        await #expect(throws: DatabaseUserError.self) {
            try await backend.importRows(into: descriptor, text: "value\nblocked", format: .csv)
        }
    }
}

@MainActor
struct PostgreSQLSessionSupportTests {
    @Test
    func postgresQueryWorkspaceUsesTargetScopedDefaultAndPersistence() throws {
        let suiteName = "SQLiteGraphStudioTests.postgres-query.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let configuration = PostgresConnectionConfiguration(
            host: "db.example.test",
            database: "catalog",
            username: "reader",
            tlsMode: .required
        )
        let target = DatabaseTarget.postgres(configuration)

        let first = QueryWorkspaceModel(databaseService: DatabaseService(), userDefaults: userDefaults)
        first.loadSavedQueries(for: target)
        #expect(first.activeQuery?.sqlText.contains("information_schema.tables") == true)
        first.updateActiveTitle("Saved PostgreSQL query")
        first.setActiveQuerySaved(true)

        let second = QueryWorkspaceModel(databaseService: DatabaseService(), userDefaults: userDefaults)
        second.loadSavedQueries(for: target)
        #expect(second.activeQuery?.title == "Saved PostgreSQL query")
    }
}
