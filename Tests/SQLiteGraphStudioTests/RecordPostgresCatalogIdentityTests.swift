import Testing
@testable import StudioCore

struct RecordPostgresCatalogIdentityTests {
    @Test func displayKeysDisambiguateQuotedComponentsWithoutChangingSimpleNames() {
        #expect(RecordTableID(schemaName: "a.b", objectName: "c").displayName == "\"a.b\".c")
        #expect(RecordTableID(schemaName: "a", objectName: "b.c").displayName == "a.\"b.c\"")
        #expect(PostgresCatalogMapper.catalogDisplayKey("public", "people") == "public.people")
        #expect(PostgresCatalogMapper.catalogDisplayKey("a.b", "c") == "\"a.b\".c")
        #expect(PostgresCatalogMapper.catalogDisplayKey("a", "b.c") == "a.\"b.c\"")
        #expect(PostgresCatalogMapper.catalogDisplayKey("a\"b", "c") == "\"a\"\"b\".c")
    }

    @Test func dottedNamesAndPostgresCaseStayDistinctThroughoutCatalog() throws {
        let names = [("a.b", "c"), ("a", "b.c"), ("public", "people"), ("public", "People")]
        let catalog = PostgresCatalogMapper.makeSnapshot(
            objects: names.map { .init(schemaName: $0.0, objectName: $0.1, relkind: "r", rowEstimate: nil) },
            columns: names.map { .init(schemaName: $0.0, objectName: $0.1, name: "id", declaredType: "integer", notNull: true, defaultValueSQL: nil, ordinal: 1) },
            indexes: names.map { .init(schemaName: $0.0, objectName: $0.1, name: "pk", columns: ["id"], isUnique: true, isPrimary: true, isPartial: false) },
            foreignKeys: [.init(id: "fk", constraintName: "fk", sourceSchemaName: "a.b", sourceObjectName: "c", sourceColumns: ["id"], targetSchemaName: "a", targetObjectName: "b.c", targetColumns: ["id"])])
        #expect(catalog.descriptors.count == 4)
        #expect(Set(catalog.descriptors.map(\.name)).count == 4)
        #expect(catalog.descriptors.allSatisfy { $0.primaryKeyColumns == ["id"] && $0.columns.count == 1 })
        let relation = try #require(RecordAccess.relationships(catalog: catalog).first)
        #expect(relation.sourceTable == .init(schemaName: "a.b", objectName: "c"))
        #expect(relation.targetTable == .init(schemaName: "a", objectName: "b.c"))
        #expect(relation.sourceDescriptor?.name != relation.targetDescriptor?.name)
    }
}
