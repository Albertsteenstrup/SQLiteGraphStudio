import Foundation
import GRDB
import Testing
@testable import StudioCore

struct RecordGraphMappingTests {
    @Test func scopedCompositeMappingPreservesParallelEdgesAndReportsUnresolvedEndpoints() async throws {
        let (database, catalog, mapping) = try await fixture()
        let descriptor = try #require(catalog.descriptors.first { $0.name == "vertices" })
        let loaded = try await database.fetchRecords(descriptor: descriptor, predicates: [.init(columnName: "tenant", value: .integer(1)), .init(columnName: "token", value: .text("A"))])
        let root = try #require(loaded.records.first)
        let page = try await RecordGraphMappingAccess.load(mapping: mapping, root: root, direction: .outgoing, offset: 0, catalog: catalog, database: database)
        #expect(page.connections.count == 2)
        #expect(page.connections[0].id != page.connections[1].id)
        #expect(page.connections.allSatisfy { $0.target.label == "Beta" && $0.source.identity == root.identity })
        #expect(page.messages.count == 3)
        #expect(page.hasMore)
        #expect(page.nextOffset == 5)
        #expect(page.queryCount == 5)
        let second = try await RecordGraphMappingAccess.load(mapping: mapping, root: root, direction: .outgoing, offset: 5, catalog: catalog, database: database)
        #expect(second.connections.count == 1)
        #expect(second.connections[0].source.id == second.connections[0].target.id)
        #expect(second.queryCount == 2)
        #expect(!second.hasMore)
        var undirected = mapping
        undirected.isDirected = false
        let incoming = try await RecordGraphMappingAccess.load(mapping: undirected, root: root, direction: .incoming, offset: 0, catalog: catalog, database: database)
        #expect(incoming.connections.count == 2)
        #expect(incoming.connections.allSatisfy { !$0.isDirected && $0.target.id == root.id })
        await database.close()
    }

    @Test func scopesAreBoundAndRootMustBeInNodeScope() async throws {
        let (database, catalog, mapping) = try await fixture()
        let descriptor = try #require(catalog.descriptors.first { $0.name == "vertices" })
        let rootPage = try await database.fetchRecords(descriptor: descriptor, predicates: [.init(columnName: "tenant", value: .integer(2)), .init(columnName: "token", value: .text("A"))])
        let excluded = try await RecordGraphMappingAccess.load(mapping: mapping, root: try #require(rootPage.records.first), direction: .outgoing, offset: 0, catalog: catalog, database: database)
        #expect(excluded.connections.isEmpty)
        #expect(excluded.queryCount == 1)
        #expect(!excluded.messages.isEmpty)
        let scopedRoot = try await database.fetchRecords(descriptor: descriptor, predicates: [.init(columnName: "tenant", value: .integer(1)), .init(columnName: "token", value: .text("A"))])
        var quoted = mapping
        quoted.edgeScope.append(.init(column: "kind", value: .text("review' OR 1=1 --")))
        let selected = try await RecordGraphMappingAccess.load(mapping: quoted, root: try #require(scopedRoot.records.first), direction: .outgoing, offset: 0, catalog: catalog, database: database)
        #expect(selected.connections.count == 1)
        #expect(selected.connections.first?.label == "review' OR 1=1 --")
        #expect(selected.queryCount <= 7)
        await database.close()
    }

    @Test func validationRejectsPartialKeysUnknownScopeAndUnstableEdgeTables() async throws {
        let (database, catalog, mapping) = try await fixture()
        _ = try RecordGraphMappingAccess.validate(mapping: mapping, catalog: catalog)
        var partial = mapping
        partial.nodeIDColumns = ["token"]
        partial.sourceColumns = ["from_token"]
        partial.targetColumns = ["to_token"]
        #expect(throws: (any Error).self) { try RecordGraphMappingAccess.validate(mapping: partial, catalog: catalog) }
        var unknown = mapping
        unknown.nodeScope = [.init(column: "absent", value: .integer(1))]
        #expect(throws: (any Error).self) { try RecordGraphMappingAccess.validate(mapping: unknown, catalog: catalog) }
        var unstable = mapping
        unstable.edgeTable = .init(schemaName: nil, objectName: "edge_view")
        #expect(throws: (any Error).self) { try RecordGraphMappingAccess.validate(mapping: unstable, catalog: catalog) }
        await database.close()
    }

    @Test func mappingsAndTypedFiltersRoundTripAndOlderSidecarsDecode() throws {
        let mapping = makeMapping()
        let sidecar = SchemaSidecar(recordGraphMappings: [mapping])
        let encoded = try JSONEncoder().encode(sidecar)
        #expect(try JSONDecoder().decode(SchemaSidecar.self, from: encoded).recordGraphMappings == [mapping])
        #expect(try JSONDecoder().decode(SchemaSidecar.self, from: Data("{}".utf8)).recordGraphMappings.isEmpty)
        let values: [RecordMappingValue] = [.null, .integer(Int64.max), .double(1.25), .boolean(true), .text("x'"), .uuid("12345678-1234-1234-1234-123456789abc"), .exactNumeric("12345678901234567890.12"), .array("{1,2}"), .blob(Data([0, 255]))]
        let encodedValues = try JSONEncoder().encode(values)
        #expect(try JSONDecoder().decode([RecordMappingValue].self, from: encodedValues) == values)
    }

    private func makeMapping() -> RecordGraphMapping {
        RecordGraphMapping(id: "links", name: "Related records", nodeTable: .init(schemaName: nil, objectName: "vertices"), nodeIDColumns: ["tenant", "token"], labelColumn: "caption", edgeTable: .init(schemaName: nil, objectName: "arcs"), sourceColumns: ["tenant", "from_token"], targetColumns: ["tenant", "to_token"], typeColumn: "kind", isDirected: true, nodeScope: [.init(column: "tenant", value: .integer(1)), .init(column: "active", value: .boolean(true))], edgeScope: [.init(column: "allowed", value: .boolean(true))])
    }

    private func fixture() async throws -> (DatabaseService, CatalogSnapshot, RecordGraphMapping) {
        let url = TestSupport.temporaryDatabaseURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE vertices(tenant INTEGER,token TEXT,caption TEXT,active BOOLEAN,PRIMARY KEY(tenant,token)) WITHOUT ROWID;
                CREATE TABLE arcs(key INTEGER PRIMARY KEY,tenant INTEGER,from_token TEXT,to_token TEXT,allowed BOOLEAN,kind TEXT);
                CREATE VIEW edge_view AS SELECT * FROM arcs;
                INSERT INTO vertices VALUES (1,'A','Alpha',1),(1,'B','Beta',1),(1,'C','Hidden',0),(2,'A','Other tenant',1),(2,'B','Other target',1);
                INSERT INTO arcs VALUES (1,1,'A','B',1,'review'' OR 1=1 --'),(2,1,'A','B',1,'second'),(3,1,'A',NULL,1,'null'),(4,1,'A','missing',1,'missing'),(5,1,'A','C',1,'hidden'),(6,1,'A','A',1,'self'),(7,1,'A','B',0,'excluded'),(8,2,'A','B',1,'other scope'),(9,1,'B','A',1,'reverse');
                """)
        }
        let database = DatabaseService()
        try await database.open(url: url)
        return (database, try await database.loadCatalogSnapshot(), makeMapping())
    }
}
