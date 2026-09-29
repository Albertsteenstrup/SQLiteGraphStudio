import Foundation
@testable import StudioCore
import StudioMCP
import Testing

/// The MCP helper does not link StudioCore, so its inline review view repeats the
/// app's change rules. These tests fail if the two ever classify a review differently.
struct SchemaReviewInlineParityTests {
    @Test func assistantExplanationsOnlyLinkObjectsInTheReview() throws {
        let review = Self.review()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("narrative-\(UUID().uuidString).sgreview")
        defer { try? FileManager.default.removeItem(at: url) }
        try review.write(to: url)
        let set = try #require(review.changeSets.firstIndex { $0.contains("users") })
        let paragraph: [[String: Any]] = [
            ["text": "The "], ["text": "users", "table": "users"], ["text": " table now requires "],
            ["text": "email", "table": "users", "field": "email"],
            ["text": ". A new "], ["text": "session relation", "relation": "fk_sessions_user"],
            ["text": " connects sessions to users."],
        ]
        let explanation: [[String: Any]] = [["set": set, "paragraphs": [paragraph]]]
        let initial = SchemaReviewInlineView.explanationContext(path: url.path, workingDirectory: "/")
        let initialView = try #require(initial["structuredContent"] as? [String: Any])
        let revision = try #require(initialView["revision"] as? String)
        let context = try #require(initialView["sets"] as? [[String: Any]])
        let facts = try #require(context.first { $0["set"] as? Int == set })
        #expect(((facts["tables"] as? [[String: Any]]) ?? []).contains { table in
            table["id"] as? String == "users" && ((table["fields"] as? [[String: Any]]) ?? []).contains { $0["name"] as? String == "email" }
        })
        #expect(((facts["relations"] as? [[String: Any]]) ?? []).contains { $0["id"] as? String == "fk_sessions_user" })
        let valid = SchemaReviewInlineView.result(path: url.path, workingDirectory: "/",
                                                   expectedRevision: revision, explanations: explanation)
        #expect(valid["isError"] as? Bool == false)
        let overview = try #require(valid["structuredContent"] as? [String: Any])
        #expect((overview["explanations"] as? [[String: Any]])?.count == 1)

        var invalidParagraph = paragraph
        invalidParagraph[3]["field"] = "not_a_field"
        let invalid = SchemaReviewInlineView.result(path: url.path, workingDirectory: "/",
            expectedRevision: revision, explanations: [["set": set, "paragraphs": [invalidParagraph]]])
        #expect(invalid["isError"] as? Bool == true)
        #expect(((invalid["structuredContent"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String == "INVALID_ARGUMENT")
    }

    @Test func inlineViewClassifiesTablesFieldsAndRelationsExactlyLikeTheApp() throws {
        let review = Self.review()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parity-\(UUID().uuidString).sgreview")
        defer { try? FileManager.default.removeItem(at: url) }
        try review.write(to: url)

        let result = SchemaReviewInlineView.detail(path: url.path, workingDirectory: "/")
        #expect(result["isError"] as? Bool == false)
        let view = try #require(result["structuredContent"] as? [String: Any])
        let tables = try #require(view["tables"] as? [[String: Any]])
        let shown = Dictionary(uniqueKeysWithValues: tables.map { ($0["id"] as! String, $0) })

        let changed = review.changes.filter { $0.kind != .unchanged }
        #expect(Set(tables.filter { $0["context"] as? Bool == false }.compactMap { $0["id"] as? String }) == Set(changed.map(\.id)))
        for change in changed {
            let table = try #require(shown[change.id], "\(change.id) is missing from the inline view")
            #expect(table["kind"] as? String == change.kind.rawValue, "\(change.id)")
            #expect(table["badge"] as? String == change.badge, "\(change.id)")
            let columns = table["columns"] as? [[String: Any]] ?? []
            let foreignKeys = review.foreignKeyColumns[change.id] ?? []
            #expect(columns.compactMap { $0["name"] as? String } == change.reviewColumns(foreignKeys: foreignKeys).map(\.name), "\(change.id)")
            for column in columns {
                let name = column["name"] as! String
                #expect(column["kind"] as? String == change.columnKind(name).rawValue, "\(change.id).\(name)")
                #expect(column["foreignKey"] as? Bool == foreignKeys.contains(name), "\(change.id).\(name)")
            }
        }
        let overview = try #require(SchemaReviewInlineView.result(path: url.path, workingDirectory: "/")["structuredContent"] as? [String: Any])
        let summary = try #require(overview["summary"] as? [String: Any])
        #expect(summary["unchangedTables"] as? Int == review.changes.filter { $0.kind == .unchanged }.count)
        // The renderer numbers sets in the app's order; the overview names them in the same order.
        let labels = (overview["changeSets"] as? [[String: Any]] ?? []).compactMap { $0["tables"] as? Int }
        #expect(labels == review.changeSets.map(\.count))

        let relations = try #require(view["relations"] as? [[String: Any]])
        let shownIDs = Set(shown.keys)
        let inline = Set(relations.map { "\($0["id"] as! String)|\($0["kind"] as! String)" })
        let app = Set(review.relationChanges
            .filter { shownIDs.contains($0.relation.source) && shownIDs.contains($0.relation.target) }
            .map { "\($0.graphID)|\($0.kind.rawValue)" })
        #expect(inline == app)
        #expect(relations.contains { $0["id"] as? String == "fk_owner_team" && $0["kind"] as? String == "modified" },
                "A relation that keeps its tables is one edited relation")
        #expect(view["changeSets"] as? [[String]] == review.changeSets)
    }

    @Test func fullModelContainsOnlyTheAfterSchemaWithoutCappingContext() throws {
        let review = Self.review()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("full-model-\(UUID().uuidString).sgreview")
        defer { try? FileManager.default.removeItem(at: url) }
        try review.write(to: url)

        let result = SchemaReviewInlineView.detail(path: url.path, workingDirectory: "/", fullModel: true)
        #expect(result["isError"] as? Bool == false)
        let view = try #require(result["structuredContent"] as? [String: Any])
        #expect(view["format"] as? String == "sqlite-graph-studio/schema-review-full-model")
        let tables = try #require(view["tables"] as? [[String: Any]])
        let ids = Set(tables.compactMap { $0["id"] as? String })
        #expect(ids == Set(review.after.tables.map(\.id)))
        #expect(!ids.contains("tokens") && ids.contains("sessions"))
        #expect(tables.allSatisfy { $0["fullModel"] as? Bool == true })
        let relations = try #require(view["relations"] as? [[String: Any]])
        #expect(Set(relations.compactMap { $0["id"] as? String }) == Set(review.after.relations.map(\.id)))
        #expect(!relations.contains { $0["id"] as? String == "fk_left_right" })
    }

    @Test func inlineViewReadsWhatTheSchemaReviewCommandWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parity-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let beforeURL = directory.appendingPathComponent("before.sqlite")
        let afterURL = directory.appendingPathComponent("after.sqlite")
        try Self.sqlite("CREATE TABLE users(id INTEGER PRIMARY KEY, email TEXT); CREATE TABLE tokens(id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id));", at: beforeURL)
        try Self.sqlite("CREATE TABLE users(id INTEGER PRIMARY KEY, email TEXT NOT NULL, active INTEGER); CREATE TABLE sessions(id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id));", at: afterURL)
        let review = SchemaReviewDocument(title: "Captured", baseRef: "a", headRef: "b",
                                          before: try await SchemaReviewCapture.snapshot(document: beforeURL),
                                          after: try await SchemaReviewCapture.snapshot(document: afterURL))
        let url = directory.appendingPathComponent("change.sgreview")
        try review.write(to: url)

        let result = SchemaReviewInlineView.detail(path: url.path, workingDirectory: "/")
        #expect(result["isError"] as? Bool == false)
        let tables = (result["structuredContent"] as? [String: Any])?["tables"] as? [[String: Any]] ?? []
        let kinds = Dictionary(uniqueKeysWithValues: tables.map { ($0["id"] as! String, $0["kind"] as! String) })
        #expect(kinds == Dictionary(uniqueKeysWithValues: review.changes.filter { $0.kind != .unchanged }.map { ($0.id, $0.kind.rawValue) }))
    }

    @Test func inlineProposalValidationMatchesTheApp() throws {
        var review = Self.review()
        review.proposal = .init(baseFingerprint: try SchemaPreview.fingerprint(review.before),
                                planFingerprint: String(repeating: "a", count: 64))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parity-\(UUID().uuidString).sgpreview")
        defer { try? FileManager.default.removeItem(at: url) }
        try review.write(to: url)
        #expect(SchemaReviewInlineView.result(path: url.path, workingDirectory: "/")["isError"] as? Bool == false)

        var tampered = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var before = try #require(tampered["before"] as? [String: Any])
        var tables = try #require(before["tables"] as? [[String: Any]])
        tables[0]["metadata"] = ["index:altered": "CREATE INDEX altered ON teams(name)"]
        before["tables"] = tables
        tampered["before"] = before
        try JSONSerialization.data(withJSONObject: tampered).write(to: url, options: .atomic)
        #expect(throws: Error.self) { try SchemaReviewDocument.load(url) }
        let invalid = SchemaReviewInlineView.result(path: url.path, workingDirectory: "/")
        #expect(invalid["isError"] as? Bool == true)
        #expect(((invalid["structuredContent"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String == "INVALID_ARTIFACT")
    }

    // MARK: Fixtures

    private static func column(_ name: String, _ type: String = "TEXT", notNull: Bool = false, defaultSQL: String? = nil, pk: Int = 0) -> SchemaReviewSnapshot.Column {
        .init(name: name, type: type, notNull: notNull, defaultSQL: defaultSQL, primaryKeyOrdinal: pk, generated: 0, identity: "")
    }

    private static func table(_ id: String, _ columns: [SchemaReviewSnapshot.Column], metadata: [String: String] = [:]) -> SchemaReviewSnapshot.Table {
        .init(id: id, schema: "public", name: id, kind: "table", columns: [column("id", "INTEGER", pk: 1)] + columns, metadata: metadata)
    }

    private static func relation(_ id: String, _ source: String, _ column: String, _ target: String, definition: String? = nil) -> SchemaReviewSnapshot.Relation {
        .init(id: id, source: source, target: target, sourceColumns: [column], targetColumns: ["id"],
              definition: definition ?? "FOREIGN KEY (\(column)) REFERENCES \(target)(id)")
    }

    /// Every rule at once: added, removed and modified tables and fields, a metadata-only
    /// change, a table changed only through a redefined relation, and untouched tables.
    private static func review() -> SchemaReviewDocument {
        let teams = table("teams", [column("name")])
        let quiet = table("quiet", [column("value")])
        let isolated = table("isolated", [column("label"), column("quiet_id", "INTEGER")])
        let owners = table("owners", [column("team_id", "INTEGER")])
        // Unchanged tables whose only change is a dropped relation between them.
        let left = table("left_side", [column("right_id", "INTEGER")])
        let right = table("right_side", [column("label")])
        let before = SchemaReviewSnapshot(engine: "sqlite", tables: [
            teams, quiet, isolated, owners, left, right,
            table("users", [column("team_id", "INTEGER"), column("email"), column("nickname")], metadata: ["index:users_email": "CREATE INDEX users_email ON users(email)"]),
            table("audits", [column("action")], metadata: ["trigger:audit": "CREATE TRIGGER audit AFTER INSERT ..."]),
            table("tokens", [column("user_id", "INTEGER")]),
        ], relations: [
            relation("fk_users_team", "users", "team_id", "teams"),
            relation("fk_tokens_user", "tokens", "user_id", "users"),
            relation("fk_owner_team", "owners", "team_id", "teams"),
            relation("fk_isolated_quiet", "isolated", "quiet_id", "quiet"),
            relation("fk_left_right", "left_side", "right_id", "right_side"),
        ])
        let after = SchemaReviewSnapshot(engine: "sqlite", tables: [
            teams, quiet, isolated, owners, left, right,
            table("users", [column("team_id", "INTEGER"), column("email", notNull: true, defaultSQL: "''"), column("active", "INTEGER")],
                  metadata: ["index:users_email": "CREATE UNIQUE INDEX users_email ON users(email)"]),
            table("audits", [column("action")], metadata: ["trigger:audit": "CREATE TRIGGER audit AFTER UPDATE ..."]),
            table("sessions", [column("user_id", "INTEGER")]),
        ], relations: [
            relation("fk_users_team", "users", "team_id", "teams"),
            relation("fk_sessions_user", "sessions", "user_id", "users"),
            relation("fk_owner_team", "owners", "team_id", "teams", definition: "FOREIGN KEY (team_id) REFERENCES teams(id) ON DELETE CASCADE"),
            relation("fk_isolated_quiet", "isolated", "quiet_id", "quiet"),
        ])
        return SchemaReviewDocument(title: "Parity", baseRef: "base", headRef: "head", before: before, after: after)
    }

    private static func sqlite(_ sql: String, at url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, sql]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
