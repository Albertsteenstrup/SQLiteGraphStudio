import Foundation
import Testing
@testable import StudioCore

struct RecordPostgreSQLIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_RECORD_POSTGRES_PORT"] != nil))
    func relatedCompositeAndUUIDPagesOnOwnedFixture() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["SGS_RECORD_POSTGRES_PORT"].flatMap(Int.init))
        let backend = PostgresDatabaseBackend(configuration: .init(host: "127.0.0.1", port: port, database: "record_fixture", username: "record_reader", tlsMode: .disabled), password: "")
        try await backend.open()
        do {
            let catalog = try await backend.loadCatalogSnapshot()
            let relationships = RecordAccess.relationships(catalog: catalog)
            let relationship = try #require(relationships.first { $0.sourceTable.objectName == "links" && $0.sourceColumns == ["tenant", "source"] })
            let target = try #require(relationship.targetDescriptor)
            #expect(target.schemaName == "alpha")
            let result = try await backend.executeReadOnlyQuery(sql: "SELECT * FROM alpha.people WHERE tenant=1 AND code=1")
            let row = try #require(result.rows.first)
            let record = try RecordAccess.snapshot(descriptor: target, columns: result.columns, values: row.values)
            let page = try await backend.fetchRelated(record: record, relationship: relationship, direction: .incoming, offset: 0, limit: 50)
            #expect(page.records.count == 50)
            #expect(page.hasMore)
            #expect(page.records.allSatisfy { $0.descriptor?.schemaName == "alpha" })
            let second = try await backend.fetchRelated(record: record, relationship: relationship, direction: .incoming, offset: 50, limit: 50)
            #expect(Set(page.records.map(\.id)).isDisjoint(with: second.records.map(\.id)))
            let mapping = RecordGraphMapping(id: "owned-pg-mapping", name: "Owned mapping", nodeTable: .init(schemaName: "alpha", objectName: "people"), nodeIDColumns: ["tenant", "code"], labelColumn: "name", edgeTable: .init(schemaName: "alpha", objectName: "links"), sourceColumns: ["tenant", "source"], targetColumns: ["tenant", "target"], nodeScope: [.init(column: "tenant", value: .integer(1))], edgeScope: [.init(column: "tenant", value: .integer(1))])
            let mappingDatabase = DatabaseService()
            try await mappingDatabase.open(postgres: .init(host: "127.0.0.1", port: port, database: "record_fixture", username: "record_reader", tlsMode: .disabled))
            do {
                let mapped = try await RecordGraphMappingAccess.load(mapping: mapping, root: record, direction: .outgoing, offset: 0, catalog: catalog, database: mappingDatabase)
                #expect(mapped.connections.count == 5)
                #expect(Set(mapped.connections.map(\.id)).count == 5)
                #expect(mapped.connections.allSatisfy { $0.target.label == "Ben" })
                #expect(mapped.nextOffset == 5)
                #expect(mapped.queryCount <= 7)
                let targetRecord = try #require(mapped.connections.first?.target)
                let incoming = try await RecordGraphMappingAccess.load(mapping: mapping, root: targetRecord, direction: .incoming, offset: 0, catalog: catalog, database: mappingDatabase)
                #expect(incoming.connections.count == 5)
                #expect(incoming.connections.allSatisfy { $0.source.label == "Ada" && $0.target.id == targetRecord.id })
                #expect(incoming.queryCount <= 7)
                await mappingDatabase.close()
            } catch {
                await mappingDatabase.close()
                throw error
            }
            let uuidRelationship = try #require(relationships.first { $0.sourceTable.objectName == "typed_refs" })
            let ref = try await backend.executeReadOnlyQuery(sql: "SELECT * FROM alpha.typed_refs WHERE key=1")
            let refRecord = try RecordAccess.snapshot(descriptor: uuidRelationship.sourceDescriptor, columns: ref.columns, values: try #require(ref.rows.first).values)
            let uuidPage = try await backend.fetchRelated(record: refRecord, relationship: uuidRelationship, direction: .outgoing, offset: 0, limit: 50)
            #expect(uuidPage.records.count == 1)
            #expect(uuidPage.records[0].values.contains(.exactNumeric("123456789012345678901234567890.12345678")))
            #expect(uuidPage.records[0].values.contains(.blob(Data([0,255]))))
            for name in ["array_refs", "binary_refs", "numeric_refs", "temporal_refs"] {
                let relation = try #require(relationships.first { $0.sourceTable.objectName == name })
                let sourceResult = try await backend.executeReadOnlyQuery(sql: "SELECT * FROM alpha." + name)
                var resolvedIDs: Set<String> = []
                for row in sourceResult.rows {
                    let source = try RecordAccess.snapshot(descriptor: relation.sourceDescriptor, columns: sourceResult.columns, values: row.values)
                    let related = try await backend.fetchRelated(record: source, relationship: relation, direction: .outgoing, offset: 0, limit: 50)
                    #expect(related.records.count == 1)
                    #expect(related.records.first?.identity != nil)
                    if let id = related.records.first?.id { resolvedIDs.insert(id) }
                }
                #expect(resolvedIDs.count == sourceResult.rows.count)
            }
            let expression = try #require(catalog.descriptors.first { $0.name == "alpha.expression_unique" })
            let expressions = try await backend.fetchRecords(descriptor: expression, predicates: [], offset: 0, limit: 50)
            #expect(expressions.records.count == 2)
            #expect(expressions.records.allSatisfy { $0.identity == nil })
            let readOnly = try await backend.executeReadOnlyQuery(sql: "SHOW transaction_read_only")
            #expect(readOnly.rows.first?.values.first?.displayText == "on")
            await backend.close()
        } catch {
            await backend.close()
            throw error
        }
    }
}
