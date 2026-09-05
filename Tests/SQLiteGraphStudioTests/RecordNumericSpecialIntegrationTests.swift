import Foundation
import Testing
@testable import StudioCore

struct RecordNumericSpecialIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_RECORD_POSTGRES_PORT"] != nil))
    func numericSpecialKeysRemainDistinctAndForeignKeysResolve() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["SGS_RECORD_POSTGRES_PORT"].flatMap(Int.init))
        let backend = PostgresDatabaseBackend(configuration: .init(host: "127.0.0.1", port: port, database: "record_fixture", username: "record_reader", tlsMode: .disabled), password: "")
        try await backend.open()
        do {
            let catalog = try await backend.loadCatalogSnapshot()
            let relation = try #require(RecordAccess.relationships(catalog: catalog).first { $0.sourceTable.objectName == "numeric_special_refs" })
            let references = try await backend.fetchRecords(descriptor: try #require(relation.sourceDescriptor), predicates: [])
            #expect(references.records.count == 4)
            let expected = ["0", "NaN", "Infinity", "-Infinity"]
            var identities: Set<String> = []
            for (index, record) in references.records.enumerated() {
                #expect(record.value(for: "ref") == .exactNumeric(expected[index]))
                let page = try await backend.fetchRelated(record: record, relationship: relation, direction: .outgoing)
                #expect(page.records.count == 1)
                #expect(page.records.first?.value(for: "key") == .exactNumeric(expected[index]))
                if let identity = page.records.first?.identity { identities.insert(identity.id) }
            }
            #expect(identities.count == 4)
            let arrays = try await backend.executeReadOnlyQuery(sql: "SELECT ARRAY['NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric, 0::numeric] AS values")
            #expect(arrays.rows.first?.values.first == .array(#"{"NaN","Infinity","-Infinity","0"}"#))
            let moneyRelation = try #require(RecordAccess.relationships(catalog: catalog).first { $0.sourceTable.objectName == "money_refs" })
            let moneyRefs = try await backend.fetchRecords(descriptor: try #require(moneyRelation.sourceDescriptor), predicates: [])
            let amounts = ["0.00", "-0.01", "123.45"]
            var moneyIdentities: Set<String> = []
            for (index, record) in moneyRefs.records.enumerated() {
                #expect(record.value(for: "ref") == .exactNumeric(amounts[index]))
                let page = try await backend.fetchRelated(record: record, relationship: moneyRelation, direction: .outgoing)
                #expect(page.records.first?.value(for: "key") == .exactNumeric(amounts[index]))
                if let identity = page.records.first?.identity { moneyIdentities.insert(identity.id) }
            }
            #expect(moneyIdentities.count == 3)
            let moneyArrayRelation = try #require(RecordAccess.relationships(catalog: catalog).first { $0.sourceTable.objectName == "money_array_refs" })
            let moneyArrayRefs = try await backend.fetchRecords(descriptor: try #require(moneyArrayRelation.sourceDescriptor), predicates: [])
            let arrayRecord = try #require(moneyArrayRefs.records.first)
            #expect(arrayRecord.value(for: "ref") == .array(#"{"-0.01","123.45"}"#))
            let arrayParent = try await backend.fetchRelated(record: arrayRecord, relationship: moneyArrayRelation, direction: .outgoing)
            #expect(arrayParent.records.first?.value(for: "key") == arrayRecord.value(for: "ref"))
            let exactScale = try await backend.executeReadOnlyQuery(sql: "SELECT 0::numeric(20,8), 1::numeric(20,8), 1.2::numeric(20,8), ARRAY[1::numeric(20,8)]")
            #expect(exactScale.rows.first?.values == [.exactNumeric("0.00000000"), .exactNumeric("1.00000000"), .exactNumeric("1.20000000"), .array(#"{"1.00000000"}"#)])
            await backend.close()
        } catch {
            await backend.close()
            throw error
        }
    }
}
