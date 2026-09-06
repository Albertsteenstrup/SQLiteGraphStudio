import Foundation
import Testing
@testable import StudioCore

struct RecordTypeModifierTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_RECORD_POSTGRES_PORT"] != nil))
    func outgoingIntegerForeignKeyDoesNotNarrowAnAbsentKey() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["SGS_RECORD_POSTGRES_PORT"].flatMap(Int.init))
        let backend = PostgresDatabaseBackend(configuration: .init(host: "127.0.0.1", port: port, database: "record_fixture", username: "record_reader", tlsMode: .disabled), password: "")
        try await backend.open()
        do {
            let catalog = try await backend.loadCatalogSnapshot()
            let relation = try #require(RecordAccess.relationships(catalog: catalog).first { $0.sourceTable.objectName == "mixed_outgoing_child" })
            let sources = try await backend.fetchRecords(descriptor: try #require(relation.sourceDescriptor), predicates: [])
            #expect(sources.records.count == 2)
            for source in sources.records {
                let targets = try await backend.fetchRelated(record: source, relationship: relation, direction: .outgoing)
                if source.value(for: "key") == .integer(70000) {
                    #expect(targets.records.isEmpty)
                    #expect(targets.status == .missingReference)
                } else { #expect(targets.records.count == 1) }
            }
            await backend.close()
        } catch { await backend.close(); throw error }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_RECORD_POSTGRES_PORT"] != nil))
    func bitScalarAndArrayForeignKeysRetainTheirComparisonType() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["SGS_RECORD_POSTGRES_PORT"].flatMap(Int.init))
        let backend = PostgresDatabaseBackend(configuration: .init(host: "127.0.0.1", port: port, database: "record_fixture", username: "record_reader", tlsMode: .disabled), password: "")
        try await backend.open()
        do {
            let catalog = try await backend.loadCatalogSnapshot()
            let relations = RecordAccess.relationships(catalog: catalog).filter { $0.sourceTable.objectName == "bit_record_refs" }
            #expect(relations.count == 2)
            for relation in relations {
                let sourceDescriptor = try #require(relation.sourceDescriptor)
                let sources = try await backend.fetchRecords(descriptor: sourceDescriptor, predicates: [])
                let source = try #require(sources.records.first)
                let targets = try await backend.fetchRelated(record: source, relationship: relation, direction: .outgoing)
                #expect(targets.records.count == 1)
                let target = try #require(targets.records.first)
                let children = try await backend.fetchRelated(record: target, relationship: relation, direction: .incoming)
                #expect(children.records.count == 1)
                let absent: SQLiteValue = relation.targetColumns == ["key"] ? .text("101011") : .text("{101011}")
                let missing = try await backend.fetchRecords(descriptor: try #require(relation.targetDescriptor), predicates: [.init(columnName: relation.targetColumns[0], value: absent)])
                #expect(missing.records.isEmpty)
            }
            await backend.close()
        } catch { await backend.close(); throw error }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_RECORD_POSTGRES_PORT"] != nil))
    func incomingForeignKeysRetainTheParentBaseType() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["SGS_RECORD_POSTGRES_PORT"].flatMap(Int.init))
        let backend = PostgresDatabaseBackend(configuration: .init(host: "127.0.0.1", port: port, database: "record_fixture", username: "record_reader", tlsMode: .disabled), password: "")
        try await backend.open()
        do {
            let catalog = try await backend.loadCatalogSnapshot()
            for (table, absent) in [("mixed_numeric_child", "1.3"), ("mixed_integer_child", "70000")] {
                let relation = try #require(RecordAccess.relationships(catalog: catalog).first { $0.sourceTable.objectName == table })
                let parents = try await backend.fetchRecords(descriptor: try #require(relation.targetDescriptor), predicates: [])
                #expect(parents.records.count == 2)
                for parent in parents.records {
                    let children = try await backend.fetchRelated(record: parent, relationship: relation, direction: .incoming)
                    let expected = parent.value(for: "key")?.displayText == absent ? 0 : 1
                    #expect(children.records.count == expected)
                    #expect(children.status == .loaded)
                    for child in children.records {
                        let back = try await backend.fetchRelated(record: child, relationship: relation, direction: .outgoing)
                        #expect(back.records.first?.id == parent.id)
                    }
                }
            }
            await backend.close()
        } catch { await backend.close(); throw error }
    }

    @Test func fixedBitLookupRetainsLengthAndQuotedTypeNamesStayIntact() throws {
        for (type, expected) in [("bit(8)", "pg_catalog.bit"), ("bit(8)[]", "pg_catalog.bit[]"), ("\"types\".\"Name(2)\"", "\"types\".\"Name(2)\"")] {
            let column = TableColumn(name: "key", declaredType: type, notNull: true, defaultValueSQL: nil, primaryKeyOrdinal: 1, hiddenValue: 0)
            let table = TableDescriptor(name: "public.bits", objectType: .table, columns: [column], primaryKeyColumns: ["key"], rowIdentityStrategy: .readOnly, isWithoutRowID: false, isEditable: false, schemaName: "public", objectName: "bits")
            let plan = try RecordAccess.plan(descriptor: table, predicates: [.init(columnName: "key", value: .text("10101010"))], offset: 0, limit: 1, postgres: true)
            #expect(plan.sql.contains("$1::text::" + expected + " ORDER"))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_RECORD_POSTGRES_PORT"] != nil))
    func lookupDoesNotTruncateOrRoundForeignKeyValues() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["SGS_RECORD_POSTGRES_PORT"].flatMap(Int.init))
        let backend = PostgresDatabaseBackend(configuration: .init(host: "127.0.0.1", port: port, database: "record_fixture", username: "record_reader", tlsMode: .disabled), password: "")
        try await backend.open()
        do {
            let catalog = try await backend.loadCatalogSnapshot()
            let relations = RecordAccess.relationships(catalog: catalog).filter { $0.sourceTable.objectName == "modifier_child" }
            #expect(relations.count == 4)
            let descriptor = try #require(relations.first?.sourceDescriptor)
            let rows = try await backend.fetchRecords(descriptor: descriptor, predicates: [])
            let invalid = try #require(rows.records.first { $0.value(for: "key") == .integer(1) })
            let valid = try #require(rows.records.first { $0.value(for: "key") == .integer(2) })
            for relation in relations {
                let missing = try await backend.fetchRelated(record: invalid, relationship: relation, direction: .outgoing)
                #expect(missing.status == .missingReference, "Unvalidated legacy FK must remain missing: \(relation.sourceColumns)")
                #expect(missing.records.isEmpty)
                let found = try await backend.fetchRelated(record: valid, relationship: relation, direction: .outgoing)
                #expect(found.records.count == 1)
            }
            await backend.close()
        } catch { await backend.close(); throw error }
    }
}
