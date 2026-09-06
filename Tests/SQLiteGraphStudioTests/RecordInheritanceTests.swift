import Foundation
import Testing
@testable import StudioCore

struct RecordInheritanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_RECORD_POSTGRES_PORT"] != nil))
    func traditionalInheritanceCannotInventIdentityOrForeignKeyEdges() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["SGS_RECORD_POSTGRES_PORT"].flatMap(Int.init))
        let backend = PostgresDatabaseBackend(configuration: .init(host: "127.0.0.1", port: port, database: "record_fixture", username: "record_reader", tlsMode: .disabled), password: "")
        try await backend.open()
        do {
            let catalog = try await backend.loadCatalogSnapshot()
            let parent = try #require(catalog.descriptors.first { $0.name == "alpha.inherited_parent" })
            let result = try await backend.executeReadOnlyQuery(sql: "SELECT * FROM alpha.inherited_parent")
            #expect(result.rows.count == 3)
            #expect(RecordQueryOrigin.descriptor(executedSQL: "SELECT * FROM alpha.inherited_parent", result: result, catalog: catalog) == nil)
            let ownResult = try await backend.executeReadOnlyQuery(sql: "SELECT * FROM ONLY alpha.inherited_parent")
            #expect(RecordQueryOrigin.descriptor(executedSQL: "SELECT * FROM ONLY alpha.inherited_parent", result: ownResult, catalog: catalog)?.id == parent.id)
            let chunk = try await backend.fetchChunk(query: .init(), descriptor: parent)
            #expect(chunk.rows.count == 1)
            let page = try await backend.fetchRecords(descriptor: parent, predicates: [])
            #expect(page.records.count == 1)
            let record = try #require(page.records.first { $0.label == "Parent" })
            let relation = try #require(RecordAccess.relationships(catalog: catalog).first { $0.sourceTable.objectName == "inherited_refs" })
            let incoming = try await backend.fetchRelated(record: record, relationship: relation, direction: .incoming)
            #expect(incoming.records.count == 1)
            let back = try await backend.fetchRelated(record: try #require(incoming.records.first), relationship: relation, direction: .outgoing)
            #expect(back.records.count == 1)
            #expect(back.records.first?.id == record.id)
            let missing = try await backend.fetchRecords(descriptor: parent, predicates: [.init(columnName: "key", value: .integer(2))])
            #expect(missing.records.isEmpty)

            // Declarative partitioning has tree-wide keys and must stay inclusive.
            let partitioned = try #require(catalog.descriptors.first { $0.name == "alpha.partitioned_record_parent" })
            let partitionPage = try await backend.fetchRecords(descriptor: partitioned, predicates: [])
            #expect(partitionPage.records.count == 1)
            let partitionRecord = try #require(partitionPage.records.first)
            let partitionRelation = try #require(RecordAccess.relationships(catalog: catalog).first { $0.sourceTable.objectName == "partitioned_record_refs" && $0.targetTable.objectName == "partitioned_record_parent" })
            let partitionIncoming = try await backend.fetchRelated(record: partitionRecord, relationship: partitionRelation, direction: .incoming)
            #expect(partitionIncoming.records.count == 1)
            let partitionBack = try await backend.fetchRelated(record: try #require(partitionIncoming.records.first), relationship: partitionRelation, direction: .outgoing)
            #expect(partitionBack.records.first?.id == partitionRecord.id)
            await backend.close()
        } catch { await backend.close(); throw error }
    }
}
