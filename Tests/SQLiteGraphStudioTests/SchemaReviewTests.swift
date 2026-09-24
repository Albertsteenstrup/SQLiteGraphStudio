import Foundation
import GRDB
import Testing
@testable import StudioCore

@MainActor struct SchemaReviewTests {
    private func fixture(_ sql: String, at url: URL) throws {
        let database = try DatabaseQueue(path: url.path)
        try database.write { try $0.execute(sql: sql) }
        try database.close()
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("schema-review-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func capturesRealSQLiteChangesWithoutMutatingFilesOrReadingRows() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let beforeURL = root.appendingPathComponent("before.sqlite"), afterURL = root.appendingPathComponent("after.sqlite")
        try fixture("""
            CREATE TABLE teams(id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE users(id INTEGER PRIMARY KEY, team_id INTEGER REFERENCES teams(id) ON DELETE RESTRICT, legacy TEXT, email TEXT);
            CREATE TABLE old_audit(id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id));
            INSERT INTO users VALUES (1, NULL, 'PRIVATE ROW VALUE', 'secret@example.invalid');
            """, at: beforeURL)
        try fixture("""
            CREATE TABLE teams(id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE users(id INTEGER PRIMARY KEY, team_id INTEGER REFERENCES teams(id) ON DELETE CASCADE, email TEXT NOT NULL DEFAULT '', active INTEGER DEFAULT 1);
            CREATE TABLE sessions(id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id));
            """, at: afterURL)
        let original = try Data(contentsOf: beforeURL)
        let before = try await SchemaReviewCapture.snapshot(document: beforeURL)
        let after = try await SchemaReviewCapture.snapshot(document: afterURL)
        let review = SchemaReviewDocument(title: "Test", baseRef: "base", headRef: "head", before: before, after: after)
        try review.validate()
        #expect(try Data(contentsOf: beforeURL) == original)
        let users = try #require(review.changes.first { $0.id == "users" })
        #expect(users.kind == .modified)
        #expect(users.added.map(\.name) == ["active"])
        #expect(users.removed.map(\.name) == ["legacy"])
        #expect(users.modified.map(\.name) == ["email"])
        #expect(users.relationChanged)
        #expect(users.unionTable.columns.map(\.name).last == "legacy")
        #expect(review.changes.first { $0.id == "old_audit" }?.kind == .removed)
        #expect(review.changes.first { $0.id == "sessions" }?.kind == .added)
        let fkChanges = review.relationChanges.filter { $0.relation.source == "users" }
        #expect(Set(fkChanges.map(\.kind)) == [.removed, .added])
        #expect(fkChanges.contains { $0.relation.definition.contains("CASCADE") })
        let url = root.appendingPathComponent("review.sgreview")
        try review.write(to: url)
        let saved = try String(contentsOf: url, encoding: .utf8)
        #expect(!saved.contains("PRIVATE ROW VALUE") && !saved.contains("secret@example.invalid"))
        #expect(try SchemaReviewDocument.load(url).changes.count == 4)
        let again = try await SchemaReviewCapture.snapshot(document: beforeURL)
        #expect(again == before)
    }

    @Test func compositeImplicitTargetsAndDuplicateActionsArePreserved() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("composite.sqlite")
        try fixture("""
            CREATE TABLE parent(a TEXT, b TEXT, PRIMARY KEY(a,b));
            CREATE TABLE child(a TEXT, b TEXT,
                FOREIGN KEY(a,b) REFERENCES parent ON DELETE CASCADE,
                FOREIGN KEY(a,b) REFERENCES parent ON DELETE RESTRICT);
            """, at: url)
        let snapshot = try await SchemaReviewCapture.snapshot(document: url)
        #expect(snapshot.relations.count == 2)
        #expect(snapshot.relations.allSatisfy { $0.sourceColumns == ["a", "b"] && $0.targetColumns == ["a", "b"] })
        #expect(Set(snapshot.relations.map(\.id)).count == 2)
        #expect(snapshot.relations.contains { $0.definition.contains("CASCADE") })
        #expect(snapshot.relations.contains { $0.definition.contains("RESTRICT") })
    }

    @Test func offlineReviewRetainsRemovedTablesAndCannotQueryOrEdit() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("source.sqlite")
        try fixture("CREATE TABLE removed(id INTEGER PRIMARY KEY, gone TEXT)", at: db)
        let before = try await SchemaReviewCapture.snapshot(document: db)
        let after = SchemaReviewSnapshot(engine: "sqlite", tables: [], relations: [])
        let review = SchemaReviewDocument(title: "Deleted table", baseRef: "old", headRef: "new", before: before, after: after)
        let url = root.appendingPathComponent("removed.sgreview"); try review.write(to: url)
        let suite = "SchemaReviewTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = AppSession(userDefaults: defaults)
        await session.openDocument(url: url)
        #expect(session.presentedError == nil)
        #expect(session.hasOpenDatabase && session.databaseTarget == nil)
        #expect(session.databaseCapabilities == .none)
        #expect(session.graph.contains(nodeID: "removed"))
        #expect(session.descriptor(named: "removed")?.columns.count == 2)
        #expect(session.openTable(named: "removed") == nil)
        #expect(session.openTabs.isEmpty)
        #expect(!(await session.applyGraphFilter(.init(minimumRows: 1))))
        #expect(await session.applyGraphFilter(.init(minimumFields: 2)))
        session.closeDatabase()
        #expect(!session.hasOpenDatabase && session.schemaReviewChanges.isEmpty && session.schemaReviewEdgeChanges.isEmpty)
    }

    @Test func malformedSnapshotsFailInsteadOfCrashingOrCreatingAFalseEmptyDiff() throws {
        let column = SchemaReviewSnapshot.Column(name: "id", type: "INTEGER", notNull: true, primaryKeyOrdinal: 1, generated: 0, identity: "")
        let table = SchemaReviewSnapshot.Table(id: "a", name: "a", kind: "table", columns: [column], metadata: [:])
        let duplicate = SchemaReviewSnapshot(engine: "sqlite", tables: [table, table], relations: [])
        #expect(throws: SchemaReviewError.self) { try duplicate.validate() }
        let broken = SchemaReviewSnapshot(engine: "sqlite", tables: [table], relations: [.init(id: "fk", source: "a", target: "missing", sourceColumns: ["id"], targetColumns: ["id"], definition: "")])
        #expect(throws: SchemaReviewError.self) { try broken.validate() }
        let before = SchemaReviewSnapshot(engine: "sqlite", tables: [], relations: [])
        let after = SchemaReviewSnapshot(engine: "postgresql", tables: [], relations: [])
        #expect(throws: SchemaReviewError.self) { try SchemaReviewDocument(title: "", baseRef: "", headRef: "", before: before, after: after).validate() }
        let relation = SchemaReviewSnapshot.Relation(id: "fk", source: "a", target: "a", sourceColumns: ["id"], targetColumns: ["id"], definition: "old")
        var edited = relation; edited.definition = "new"
        var collision = relation; collision.id = "before:fk"
        let colliding = SchemaReviewDocument(title: "", baseRef: "", headRef: "",
            before: .init(engine: "sqlite", tables: [table], relations: [relation]),
            after: .init(engine: "sqlite", tables: [table], relations: [edited, collision]))
        #expect(throws: SchemaReviewError.self) { try colliding.validate() }
    }

    @Test func postgresConstraintOIDsDoNotCreateFalseChanges() throws {
        func catalog(oid: String) -> CatalogSnapshot {
            let column = TableColumn(name: "id", declaredType: "BIGINT", notNull: true, defaultValueSQL: nil, primaryKeyOrdinal: 1, hiddenValue: 0)
            let source = EditableTableDescriptor(name: "public.child", objectType: .table, columns: [column], primaryKeyColumns: ["id"], rowIdentityStrategy: .readOnly, isWithoutRowID: false, isEditable: false,
                constraints: [.init(id: "public.child.fk.\(oid)", kind: .foreignKey, name: "child_parent_fkey", columns: ["id"], detail: "FK")], schemaName: "public", objectName: "child")
            let target = EditableTableDescriptor(name: "public.parent", objectType: .table, columns: [column], primaryKeyColumns: ["id"], rowIdentityStrategy: .readOnly, isWithoutRowID: false, isEditable: false, schemaName: "public", objectName: "parent")
            return CatalogSnapshot(descriptors: [source, target], graph: .empty, recordRelationshipMetadata: [
                RecordRelationship(id: "native:fk:\(oid)", sourceTable: .init(descriptor: source), targetTable: .init(descriptor: target), sourceColumns: ["id"], targetColumns: ["id"], sourceDescriptor: source, targetDescriptor: target)
            ])
        }
        let before = SchemaReviewCapture.makeSnapshot(catalog(oid: "123"), engine: "postgresql")
        let after = SchemaReviewCapture.makeSnapshot(catalog(oid: "9999"), engine: "postgresql")
        #expect(before == after)
        try before.validate()
        #expect(SchemaReviewDocument(title: "", baseRef: "", headRef: "", before: before, after: after).changes.allSatisfy { $0.kind == .unchanged })
    }

    @Test func authorNamesTheAgentAndSessionAndOlderReviewsStillOpen() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let empty = SchemaReviewSnapshot(engine: "sqlite", tables: [], relations: [])
        let author = try #require(SchemaReviewDocument.Author(tool: " Claude Code ", session: "Table diff visualization clarity"))
        #expect(author.tool == "claude" && author.agent == .claude)
        #expect(author.summary == "Claude · Table diff visualization clarity")
        #expect(SchemaReviewDocument.Author(tool: "vscode-copilot", session: "  ")?.summary == "Copilot")
        #expect(SchemaReviewDocument.Author(tool: "OpenAI Codex", session: nil)?.agent == .codex)
        #expect(SchemaReviewDocument.Author(tool: "opencode", session: nil)?.toolName == "OpenCode")
        // Another tool keeps its own name, and a missing tool means no author at all.
        #expect(SchemaReviewDocument.Author(tool: "Aider", session: "x")?.summary == "Aider · x")
        #expect(SchemaReviewDocument.Author(tool: "  ", session: "x") == nil)

        let url = root.appendingPathComponent("authored.sgreview")
        try SchemaReviewDocument(title: "t", baseRef: "a", headRef: "b", before: empty, after: empty, author: author).write(to: url)
        #expect(try SchemaReviewDocument.load(url).author == author)

        // Documents written before authors existed carry no key and still load.
        var legacy = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        legacy.removeValue(forKey: "author")
        try JSONSerialization.data(withJSONObject: legacy).write(to: url)
        #expect(try SchemaReviewDocument.load(url).author == nil)

        var named = SchemaReviewDocument(title: "t", baseRef: "a", headRef: "b", before: empty, after: empty, author: author)
        // Emoji are built with joiners, which are format characters but harmless.
        named.author?.session = "👩‍💻 pairing"
        try named.validate()
        for unsafe in ["line\nbreak", "tab\there", "\u{202E}desrever", "a\u{2028}b"] {
            named.author?.session = unsafe
            #expect(throws: SchemaReviewError.self) { try named.validate() }
        }
    }

    @Test func reviewCommandAuthorFlagsNeedATool() throws {
        #expect(try SchemaReviewCommand.author([:]) == nil)
        let author = try #require(try SchemaReviewCommand.author(["--agent": ["codex"], "--session": ["Migration check"]]))
        #expect(author.summary == "Codex · Migration check")
        // The last value wins, as for every other repeated option.
        #expect(try SchemaReviewCommand.author(["--agent": ["claude", "opencode"]])?.agent == .opencode)
        #expect(throws: SchemaReviewError.self) { try SchemaReviewCommand.author(["--session": ["orphan"]]) }
        #expect(throws: SchemaReviewError.self) { try SchemaReviewCommand.author(["--agent": ["  "]]) }
    }

    @Test func missingSourceIsNotCreatedByCapture() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("missing.sqlite")
        await #expect(throws: SchemaReviewError.self) { _ = try await SchemaReviewCapture.snapshot(document: url) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
