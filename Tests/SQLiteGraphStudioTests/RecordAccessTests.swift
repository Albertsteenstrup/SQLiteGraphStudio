import Foundation
import GRDB
import Testing
@testable import StudioCore

struct RecordAccessTests {
    @Test func completeKeysAndIdentitylessSnapshots() throws {
        let descriptor = table("items", columns: ["a", "b", "value"], primaryKey: ["a", "b"])
        let columns = descriptor.columns.map { QueryResultColumn(name: $0.name, typeLabel: $0.declaredType) }
        let record = try RecordAccess.snapshot(descriptor: descriptor, columns: columns, values: [.integer(1), .text("x"), .text("hello")])
        #expect(record.identity?.locator.count == 2)
        let partial = try RecordAccess.snapshot(descriptor: descriptor, columns: Array(columns.prefix(1)), values: [.integer(1)])
        #expect(partial.identity == nil)
        #expect(partial.values == [.integer(1)])
        let nullable = try RecordAccess.snapshot(descriptor: descriptor, columns: columns, values: [.null, .text("x"), .text("hello")])
        #expect(nullable.identity == nil)
        #expect(throws: (any Error).self) { try RecordAccess.snapshot(descriptor: descriptor, columns: columns, values: []) }
    }

    @Test func schemaAndTypedValuesDistinguishStableIdentities() {
        let left = RecordIdentity(table: RecordTableID(schemaName: "a", objectName: "b.c"), locator: [.init(columnName: "id", value: .integer(1))])
        let right = RecordIdentity(table: RecordTableID(schemaName: "a.b", objectName: "c"), locator: [.init(columnName: "id", value: .integer(1))])
        let text = RecordIdentity(table: left.table, locator: [.init(columnName: "id", value: .text("1"))])
        #expect(left.id != right.id)
        #expect(left.id != text.id)
        #expect(left.id == RecordIdentity(table: left.table, locator: left.locator).id)
    }

    @Test func compositeOmittedReferencesAndBoundedRelatedPages() async throws {
        let url = TestSupport.temporaryDatabaseURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE parent(a TEXT, b INTEGER, PRIMARY KEY(a,b)) WITHOUT ROWID;
                CREATE TABLE child(id INTEGER PRIMARY KEY, a TEXT, b INTEGER,
                    FOREIGN KEY(a,b) REFERENCES parent,
                    FOREIGN KEY(a,b) REFERENCES parent(a,b));
                INSERT INTO parent VALUES ('x'' OR 1=1 --',7),('other',7);
                """)
            for id in 0..<55 {
                try db.execute(sql: "INSERT INTO child VALUES (?,?,?)", arguments: [id, "x' OR 1=1 --", 7])
            }
        }
        let service = DatabaseService()
        try await service.open(url: url)
        let catalog = try await service.loadCatalogSnapshot()
        let parentDescriptor = try #require(catalog.descriptors.first { $0.name == "parent" })
        let fetched = try await service.fetchRecords(descriptor: parentDescriptor, predicates: [.init(columnName: "a", value: .text("x' OR 1=1 --")), .init(columnName: "b", value: .integer(7))], offset: 0, limit: 50)
        #expect(fetched.records.count == 1)
        #expect(fetched.records.first?.identity?.locator.count == 2)
        let relationships = RecordAccess.relationships(catalog: catalog)
        #expect(relationships.count == 2)
        #expect(relationships.allSatisfy { $0.targetColumns == ["a", "b"] })
        let parent = try #require(catalog.descriptors.first { $0.name == "parent" })
        let snapshot = try RecordAccess.snapshot(descriptor: parent, columns: parent.columns.map { .init(name: $0.name, typeLabel: $0.declaredType) }, values: [.text("x' OR 1=1 --"), .integer(7)])
        let first = try await service.fetchRelated(record: snapshot, relationship: relationships[0], direction: .incoming, offset: 0, limit: 500)
        #expect(first.records.count == 50)
        #expect(first.hasMore)
        #expect(first.nextOffset == 50)
        let next = try await service.fetchRelated(record: snapshot, relationship: relationships[0], direction: .incoming, offset: 50, limit: 50)
        #expect(next.records.count == 5)
        #expect(!next.hasMore)
        #expect(Set(first.records.map(\.id)).isDisjoint(with: next.records.map(\.id)))
        let child = try #require(catalog.descriptors.first { $0.name == "child" })
        let childColumns = child.columns.map { QueryResultColumn(name: $0.name, typeLabel: $0.declaredType) }
        let null = try RecordAccess.snapshot(descriptor: child, columns: childColumns, values: [.integer(100), .null, .integer(7)])
        let nullPage = try await service.fetchRelated(record: null, relationship: relationships[0], direction: .outgoing, offset: 0, limit: 50)
        #expect(nullPage.status == .nullReference)
        let missing = try RecordAccess.snapshot(descriptor: child, columns: childColumns, values: [.integer(100), .text("missing"), .integer(7)])
        let missingPage = try await service.fetchRelated(record: missing, relationship: relationships[0], direction: .outgoing, offset: 0, limit: 50)
        #expect(missingPage.status == .missingReference)
        await service.close()
    }

    @Test func onlyCompleteNonpartialUniqueKeysAreIdentities() throws {
        let columns = ["email", "other"].map { TableColumn(name: $0, declaredType: "TEXT", notNull: false, defaultValueSQL: nil, primaryKeyOrdinal: 0, hiddenValue: 0) }
        func descriptor(_ indexes: [SchemaIndex]) -> TableDescriptor {
            TableDescriptor(name: "viewish", objectType: .table, columns: columns, primaryKeyColumns: [], rowIdentityStrategy: .readOnly, isWithoutRowID: true, isEditable: false, indexes: indexes)
        }
        let queryColumns = columns.map { QueryResultColumn(name: $0.name, typeLabel: $0.declaredType) }
        let unique = SchemaIndex(name: "email_key", columns: ["email"], isUnique: true, origin: "u", isPartial: false, sql: nil)
        #expect(try RecordAccess.snapshot(descriptor: descriptor([unique]), columns: queryColumns, values: [.text("x"), .text("y")]).identity != nil)
        #expect(try RecordAccess.snapshot(descriptor: descriptor([unique]), columns: queryColumns, values: [.null, .text("y")]).identity == nil)
        let partial = SchemaIndex(name: "partial", columns: ["email"], isUnique: true, origin: "c", isPartial: true, sql: nil)
        #expect(try RecordAccess.snapshot(descriptor: descriptor([partial]), columns: queryColumns, values: [.text("x"), .text("y")]).identity == nil)
        let expression = SchemaIndex(name: "expression", columns: ["email", ""], isUnique: true, origin: "c", isPartial: false, sql: nil)
        #expect(try RecordAccess.snapshot(descriptor: descriptor([expression]), columns: queryColumns, values: [.text("x"), .text("y")]).identity == nil)
    }

    @Test func shadowedRowidCannotBecomeIdentityFromLegacyTableRow() throws {
        let columns = ["_rowid_", "rowid", "oid"].map { TableColumn(name: $0, declaredType: "TEXT", notNull: false, defaultValueSQL: nil, primaryKeyOrdinal: 0, hiddenValue: 0) }
        let descriptor = TableDescriptor(name: "shadow", objectType: .table, columns: columns, primaryKeyColumns: [], rowIdentityStrategy: .rowID, isWithoutRowID: false, isEditable: true)
        let snapshot = try RecordAccess.snapshot(descriptor: descriptor, columns: columns.map { .init(name: $0.name, typeLabel: $0.declaredType) }, values: [.text("a"), .text("b"), .text("c")], rowIdentity: .rowID(7))
        #expect(snapshot.identity == nil)
    }

    @Test func missingColumnsAndUnavailableTargetsAreDistinct() throws {
        let source = table("child", columns: ["id", "parent_id"], primaryKey: ["id"])
        let target = table("parent", columns: ["id"], primaryKey: ["id"])
        let relationship = RecordRelationship(id: "fk", sourceTable: .init(descriptor: source), targetTable: .init(descriptor: target), sourceColumns: ["parent_id"], targetColumns: ["id"], sourceDescriptor: source, targetDescriptor: target)
        let snapshot = try RecordAccess.snapshot(descriptor: source, columns: [.init(name: "id", typeLabel: "INTEGER")], values: [.integer(1)])
        #expect(throws: RecordAccessError.missingColumns(["parent_id"])) {
            try RecordAccess.relatedPlan(record: snapshot, relationship: relationship, direction: .outgoing, offset: 0, limit: 50, postgres: false)
        }
    }

    @Test func postgresRelatedPlanBindsTypedValuesAndQuotesIdentifiers() throws {
        let types = ["uuid", "numeric(20,4)", "uuid[]", "bytea"]
        let names = ["u", "n", "arr", "bin"]
        let columns = zip(names, types).map { TableColumn(name: $0.0, declaredType: $0.1, notNull: true, defaultValueSQL: nil, primaryKeyOrdinal: 0, hiddenValue: 0) }
        let source = TableDescriptor(name: "a.same", objectType: .table, columns: columns, primaryKeyColumns: names, rowIdentityStrategy: .readOnly, isWithoutRowID: false, isEditable: false, schemaName: "a", objectName: "same")
        let target = TableDescriptor(name: "b.same", objectType: .table, columns: columns, primaryKeyColumns: names, rowIdentityStrategy: .readOnly, isWithoutRowID: false, isEditable: false, schemaName: "b", objectName: "weird\"table")
        let values: [SQLiteValue] = [.uuid("550e8400-e29b-41d4-a716-446655440000"), .exactNumeric("1234567890123456.1234"), .array("{550e8400-e29b-41d4-a716-446655440000}"), .blob(Data([0, 255]))]
        let snapshot = try RecordAccess.snapshot(descriptor: source, columns: columns.map { .init(name: $0.name, typeLabel: $0.declaredType) }, values: values)
        let relation = RecordRelationship(id: "fk", sourceTable: .init(descriptor: source), targetTable: .init(descriptor: target), sourceColumns: names, targetColumns: names, sourceDescriptor: source, targetDescriptor: target)
        let plan = try #require(try RecordAccess.relatedPlan(record: snapshot, relationship: relation, direction: .outgoing, offset: 0, limit: 50, postgres: true))
        #expect(plan.parameters == values)
        #expect(plan.sql.contains("\"b\".\"weird\"\"table\""))
        #expect(plan.sql.contains("$1::text::uuid"))
        #expect(plan.sql.contains("$2::text::numeric(20,4)"))
        #expect(plan.sql.contains("$3::text::uuid[]"))
        #expect(plan.sql.contains("$4::text::bytea"))
        #expect(!plan.sql.contains("550e8400"))
        #expect(!plan.sql.contains("COUNT"))
        #expect(plan.sql.contains("LIMIT 51 OFFSET 0"))
    }

    @Test func expressionIndexDoesNotProvePartialIdentity() async throws {
        let url = TestSupport.temporaryDatabaseURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(sql: "CREATE TABLE expression_key(a TEXT,b TEXT); CREATE UNIQUE INDEX composite_expr ON expression_key(a,lower(b)); INSERT INTO expression_key VALUES ('same','a'),('same','b')")
        }
        let service = DatabaseService()
        try await service.open(url: url)
        let descriptor = try await service.fetchDescriptor(named: "expression_key")
        let snapshot = try RecordAccess.snapshot(descriptor: descriptor, columns: descriptor.columns.map { .init(name: $0.name, typeLabel: $0.declaredType) }, values: [.text("same"), .text("a")])
        #expect(snapshot.identity == nil)
        await service.close()
    }

    @Test func readableLabelPrefersNonKeyText() throws {
        let descriptor = table("items", columns: ["id", "title"], primaryKey: ["id"])
        let record = try RecordAccess.snapshot(descriptor: descriptor, columns: descriptor.columns.map { .init(name: $0.name, typeLabel: $0.declaredType) }, values: [.integer(123), .text("Readable record")])
        #expect(record.label == "Readable record")
        #expect(record.identity?.locator.first?.value == .integer(123))
    }

    @Test func sqliteFetchUsesUnshadowedRowidAliasAndIdentitylessView() async throws {
        let url = TestSupport.temporaryDatabaseURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(sql: "CREATE TABLE shadowed(_rowid_ TEXT, value TEXT); INSERT INTO shadowed VALUES ('same','a'),('same','b'); CREATE VIEW identityless AS SELECT value FROM shadowed")
        }
        let service = DatabaseService()
        try await service.open(url: url)
        let catalog = try await service.loadCatalogSnapshot()
        let descriptor = try #require(catalog.descriptors.first { $0.name == "shadowed" })
        let page = try await service.fetchRecords(descriptor: descriptor, predicates: [], offset: 0, limit: 50)
        #expect(page.records.count == 2)
        #expect(page.records.allSatisfy { $0.identity?.locator.first?.columnName == "rowid" })
        #expect(page.records[0].id != page.records[1].id)
        let view = try #require(catalog.descriptors.first { $0.name == "identityless" })
        let viewPage = try await service.fetchRecords(descriptor: view, predicates: [], offset: 0, limit: 50)
        #expect(viewPage.records.count == 2)
        #expect(viewPage.records.allSatisfy { $0.identity == nil })
        await service.close()
    }

    @Test func unavailablePostgresTargetsKeepStructuredRelationshipMetadata() throws {
        let foreignKey = PostgresCatalogForeignKey(id: "1", constraintName: "fk", sourceSchemaName: "a", sourceObjectName: "same", sourceColumns: ["ref"], targetSchemaName: "b", targetObjectName: "same", targetColumns: ["key"])
        let catalog = PostgresCatalogMapper.makeSnapshot(objects: [.init(schemaName: "a", objectName: "same", relkind: "r", rowEstimate: nil)], columns: [.init(schemaName: "a", objectName: "same", name: "ref", declaredType: "integer", notNull: false, defaultValueSQL: nil, ordinal: 1)], indexes: [], foreignKeys: [foreignKey])
        let relation = try #require(RecordAccess.relationships(catalog: catalog).first)
        #expect(relation.sourceTable.schemaName == "a")
        #expect(relation.targetTable.schemaName == "b")
        #expect(relation.targetDescriptor == nil)
        let record = try RecordAccess.snapshot(descriptor: relation.sourceDescriptor, columns: [.init(name: "ref", typeLabel: "integer")], values: [.integer(1)])
        #expect(throws: RecordAccessError.unavailableTable) {
            try RecordAccess.relatedPlan(record: record, relationship: relation, direction: .outgoing, offset: 0, limit: 50, postgres: true)
        }
    }

    @Test func delimiterCharactersDoNotMergeDifferentRelationships() {
        let descriptors = ["a->b", "c", "a", "b->c"].map { table($0, columns: ["id"], primaryKey: ["id"]) }
        let edges = [
            GraphEdge(id: "a->b->c#0:0", sourceID: "a->b", targetID: "c", sourceColumn: "id", targetColumn: "id"),
            GraphEdge(id: "a->b->c#0:0", sourceID: "a", targetID: "b->c", sourceColumn: "id", targetColumn: "id")
        ]
        let relationships = RecordAccess.relationships(catalog: CatalogSnapshot(descriptors: descriptors, graph: .init(nodes: [], edges: edges)))
        #expect(relationships.count == 2)
        #expect(Set(relationships.map(\.id)).count == 2)
    }

    private func table(_ name: String, columns: [String], primaryKey: [String]) -> TableDescriptor {
        TableDescriptor(name: name, objectType: .table, columns: columns.map { name in
            TableColumn(name: name, declaredType: "TEXT", notNull: true, defaultValueSQL: nil, primaryKeyOrdinal: primaryKey.firstIndex(of: name).map { $0 + 1 } ?? 0, hiddenValue: 0)
        }, primaryKeyColumns: primaryKey, rowIdentityStrategy: .primaryKey, isWithoutRowID: true, isEditable: true)
    }
}
