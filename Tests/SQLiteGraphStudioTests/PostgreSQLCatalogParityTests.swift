import Foundation
import Testing
@testable import StudioCore

struct PostgreSQLCatalogParityTests {
    @Test
    func triggerDefinitionsStayWithTheirSchemaQualifiedTables() throws {
        let salesSQL = #"CREATE TRIGGER "audit changes" AFTER UPDATE ON sales.events FOR EACH ROW EXECUTE FUNCTION sales.audit_event()"#
        let auditSQL = #"CREATE TRIGGER "audit changes" BEFORE INSERT ON audit.events FOR EACH ROW EXECUTE FUNCTION audit.normalize_event()"#
        let snapshot = PostgresCatalogMapper.makeSnapshot(
            objects: [object("sales"), object("audit")],
            columns: [],
            indexes: [],
            foreignKeys: [],
            triggers: [
                PostgresCatalogTrigger(schemaName: "sales", objectName: "events", name: "audit changes", sql: salesSQL),
                PostgresCatalogTrigger(schemaName: "audit", objectName: "events", name: "audit changes", sql: auditSQL)
            ]
        )

        let sales = try #require(snapshot.descriptors.first { $0.name == "sales.events" })
        let audit = try #require(snapshot.descriptors.first { $0.name == "audit.events" })
        #expect(sales.triggers == [SchemaTrigger(name: "audit changes", tableName: "sales.events", sql: salesSQL)])
        #expect(audit.triggers == [SchemaTrigger(name: "audit changes", tableName: "audit.events", sql: auditSQL)])
        #expect(snapshot.descriptors.allSatisfy { !$0.isEditable && $0.rowIdentityStrategy == .readOnly })
    }

    @Test
    func namedChecksPreserveDefinitionsAndColumnBindingsAcrossSchemas() throws {
        let checkSQL = #"CHECK (("start time" < "end time")) NOT VALID"#
        let snapshot = PostgresCatalogMapper.makeSnapshot(
            objects: [object("sales"), object("audit")],
            columns: [],
            indexes: [],
            foreignKeys: [],
            checkConstraints: [
                PostgresCatalogCheckConstraint(
                    id: "201", schemaName: "sales", objectName: "events", name: "valid range",
                    columns: ["start time", "end time"], sql: checkSQL
                ),
                PostgresCatalogCheckConstraint(
                    id: "202", schemaName: "audit", objectName: "events", name: "valid range",
                    columns: [], sql: "CHECK (true)"
                )
            ]
        )

        let sales = try #require(snapshot.descriptors.first { $0.name == "sales.events" })
        let audit = try #require(snapshot.descriptors.first { $0.name == "audit.events" })
        #expect(sales.constraints == [
            SchemaConstraint(
                id: "sales.events.check.201", kind: .check, name: "valid range",
                columns: ["start time", "end time"], detail: checkSQL
            )
        ])
        #expect(audit.constraints == [
            SchemaConstraint(
                id: "audit.events.check.202", kind: .check, name: "valid range",
                columns: [], detail: "CHECK (true)"
            )
        ])
    }

    @Test
    func additionalMetadataPreservesCompositeForeignKeysGeneratedColumnsAndMaterializedViews() throws {
        let snapshot = PostgresCatalogMapper.makeSnapshot(
            objects: [
                object("sales"), object("audit"),
                object("reporting", name: "events", relkind: "m")
            ],
            columns: [
                column("sales", name: "event_id", ordinal: 1),
                column("sales", name: "region", ordinal: 2),
                column("sales", name: "total", ordinal: 3, generatedKind: "s"),
                column("audit", name: "id", ordinal: 1),
                column("audit", name: "region", ordinal: 2)
            ],
            indexes: [
                PostgresCatalogIndex(
                    schemaName: "audit", objectName: "events", name: "events_pkey",
                    columns: ["id", "region"], isUnique: true, isPrimary: true, isPartial: false
                )
            ],
            foreignKeys: [
                PostgresCatalogForeignKey(
                    id: "301", constraintName: "events_audit_fk",
                    sourceSchemaName: "sales", sourceObjectName: "events", sourceColumns: ["event_id", "region"],
                    targetSchemaName: "audit", targetObjectName: "events", targetColumns: ["id", "region"]
                )
            ],
            triggers: [
                PostgresCatalogTrigger(
                    schemaName: "sales", objectName: "events", name: "audit_event",
                    sql: "CREATE TRIGGER audit_event AFTER INSERT ON sales.events FOR EACH ROW EXECUTE FUNCTION audit.capture_event()"
                )
            ],
            checkConstraints: [
                PostgresCatalogCheckConstraint(
                    id: "302", schemaName: "sales", objectName: "events", name: "total_nonnegative",
                    columns: ["total"], sql: "CHECK ((total >= 0))"
                )
            ]
        )

        let sales = try #require(snapshot.descriptors.first { $0.name == "sales.events" })
        #expect(sales.generatedColumns == [GeneratedColumnInfo(name: "total", declaredType: "integer", storedKind: "stored")])
        #expect(sales.columns.last?.isGenerated == true)
        #expect(sales.columns.allSatisfy { !$0.isEditable })
        #expect(sales.constraints.filter { $0.kind == .foreignKey }.first?.columns == ["event_id", "region"])
        #expect(sales.constraints.contains { $0.kind == .check && $0.name == "total_nonnegative" })
        #expect(snapshot.graph.edges.map(\.sourceColumn) == ["event_id", "region"])
        #expect(snapshot.graph.edges.map(\.targetColumn) == ["id", "region"])
        #expect(snapshot.graph.edges.allSatisfy { $0.sourceID == "sales.events" && $0.targetID == "audit.events" && $0.cardinality == .manyToOne })

        let materialized = try #require(snapshot.descriptors.first { $0.name == "reporting.events" })
        #expect(materialized.objectType == .materializedView)
        #expect(materialized.triggers.isEmpty)
        #expect(materialized.constraints.isEmpty)
        #expect(!materialized.isEditable)
    }

    @Test
    func postgresTableQueryQuotesSchemaObjectAndColumnIndependently() throws {
        let schemaName = #"report.ing "zone""#
        let objectName = #"order.items "current""#
        let columnName = #"net "total""#
        let descriptor = TableDescriptor(
            name: "\(schemaName).\(objectName)", objectType: .table,
            columns: [TableColumn(name: columnName, declaredType: "numeric", notNull: false, defaultValueSQL: nil, primaryKeyOrdinal: 0, hiddenValue: 0, isEditable: false)],
            primaryKeyColumns: [], rowIdentityStrategy: .readOnly, isWithoutRowID: false, isEditable: false,
            schemaName: schemaName, objectName: objectName
        )
        let plan = try PostgresTableQueryBuilder.makePlan(
            query: TableQueryState(), descriptor: descriptor
        )

        #expect(plan.countSQL == #"SELECT COUNT(*) FROM "report.ing ""zone"""."order.items ""current""""#)
        #expect(plan.selectSQL.contains(#"SELECT "net ""total""" FROM "report.ing ""zone"""."order.items ""current""""#))
    }

    private func object(_ schemaName: String, name: String = "events", relkind: String = "r") -> PostgresCatalogObject {
        PostgresCatalogObject(schemaName: schemaName, objectName: name, relkind: relkind, rowEstimate: nil)
    }

    private func column(_ schemaName: String, name: String, ordinal: Int, generatedKind: String = "") -> PostgresCatalogColumn {
        PostgresCatalogColumn(
            schemaName: schemaName, objectName: "events", name: name, declaredType: "integer",
            notNull: false, defaultValueSQL: nil, ordinal: ordinal, generatedKind: generatedKind
        )
    }
}

@MainActor
struct PostgreSQLTopRowsParityTests {
    @Test
    func topRowsQueryUsesTheStructuredPostgresIdentifier() throws {
        let descriptor = TableDescriptor(
            name: #"report.ing.order "items""#, objectType: .materializedView, columns: [],
            primaryKeyColumns: [], rowIdentityStrategy: .readOnly, isWithoutRowID: false, isEditable: false,
            schemaName: "report.ing", objectName: #"order "items""#
        )
        let (workspace, defaults, suiteName) = try makeWorkspace()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        workspace.createTopRowsQuery(for: descriptor)

        #expect(workspace.activeQuery?.sqlText == #"""
        SELECT *
        FROM "report.ing"."order ""items"""
        LIMIT 10;
        """#)
        #expect(workspace.activeQuery?.title == #"report.ing.order "items" Top 10"#)
    }

    @Test
    func topRowsQueryKeepsLiteralDotsInSQLiteTableNames() throws {
        let descriptor = TableDescriptor(
            name: #"audit.events "all""#, objectType: .table, columns: [],
            primaryKeyColumns: [], rowIdentityStrategy: .rowID, isWithoutRowID: false, isEditable: true
        )
        let (workspace, defaults, suiteName) = try makeWorkspace()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        workspace.createTopRowsQuery(for: descriptor)

        #expect(workspace.activeQuery?.sqlText == #"""
        SELECT *
        FROM "audit.events ""all"""
        LIMIT 10;
        """#)
    }

    private func makeWorkspace() throws -> (QueryWorkspaceModel, UserDefaults, String) {
        let suiteName = "SQLiteGraphStudioTests.top-rows-parity.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (QueryWorkspaceModel(databaseService: DatabaseService(), userDefaults: defaults), defaults, suiteName)
    }
}
