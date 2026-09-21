import Foundation
import Testing
@testable import StudioCore

@MainActor struct SchemaPreviewTests {
    private func baseline() -> SchemaPreview.Baseline {
        func field(_ name: String, _ type: String = "INTEGER") -> SchemaReviewSnapshot.Column {
            .init(name: name, type: type, notNull: false, primaryKeyOrdinal: name == "id" ? 1 : 0, generated: 0, identity: "")
        }
        return .init(snapshot: .init(engine: "sqlite", tables: [
            .init(id: "teams", name: "teams", kind: "table", columns: [field("id")], metadata: [:]),
            .init(id: "users", name: "users", kind: "table", columns: [field("id"), field("team_id"), field("email", "TEXT"), field("legacy", "TEXT")], metadata: ["definition": "captured DDL"]),
            .init(id: "old_audit", name: "old_audit", kind: "table", columns: [field("id"), field("user_id")], metadata: [:])
        ], relations: [
            .init(id: "users_team", source: "users", target: "teams", sourceColumns: ["team_id"], targetColumns: ["id"], definition: "ON DELETE RESTRICT"),
            .init(id: "audit_user", source: "old_audit", target: "users", sourceColumns: ["user_id"], targetColumns: ["id"], definition: "ON DELETE RESTRICT")
        ]), label: "captured-commit")
    }
    private func plan(_ changes: [[String: Any]], base: SchemaPreview.Baseline? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["title": "Proposed approval", "baseFingerprint": SchemaPreview.fingerprint((base ?? baseline()).snapshot), "changes": changes])
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("schema-preview-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func compactPlanProjectsFieldsTablesAndRelationsWithoutChangingBaseline() throws {
        let base = baseline(), original = try SchemaPreview.fingerprint(base.snapshot)
        let review = try SchemaPreview.project(base, planData: plan([
            ["op": "addColumn", "table": "users", "column": ["name": "approved_at", "type": "TEXT"]],
            ["op": "removeColumn", "table": "users", "column": "legacy"],
            ["op": "alterColumn", "table": "users", "column": "email", "set": ["notNull": true, "defaultSQL": "''"]],
            ["op": "addTable", "table": "approval", "columns": [["name": "id", "type": "INTEGER", "primaryKeyOrdinal": 1], ["name": "user_id", "type": "INTEGER"]]],
            ["op": "addRelation", "id": "approval_user", "source": "approval", "target": "users", "sourceColumns": ["user_id"], "targetColumns": ["id"]],
            ["op": "alterRelation", "id": "users_team", "set": ["definition": "ON DELETE CASCADE"]],
            ["op": "removeTable", "table": "old_audit", "cascade": true]
        ]))
        #expect(try SchemaPreview.fingerprint(base.snapshot) == original)
        #expect(review.proposal?.baseFingerprint == original && review.headRef == "Proposed")
        let users = try #require(review.changes.first { $0.id == "users" })
        #expect(users.added.map(\.name) == ["approved_at"])
        #expect(users.removed.map(\.name) == ["legacy"])
        #expect(users.modified.map(\.name) == ["email"])
        #expect(users.relationChanged)
        #expect(review.changes.first { $0.id == "approval" }?.kind == .added)
        #expect(review.changes.first { $0.id == "old_audit" }?.kind == .removed)
        #expect(review.relationChanges.contains { $0.relation.id == "users_team" && $0.kind == .removed })
        #expect(review.relationChanges.contains { $0.relation.definition == "ON DELETE CASCADE" && $0.kind == .added })
        #expect(review.after.relations.first { $0.id == "approval_user" }?.definition.contains("Actions are not specified") == true)
    }

    @Test func renameMaintainsIncomingAndOutgoingRelationEndpoints() throws {
        let review = try SchemaPreview.project(baseline(), planData: plan([
            ["op": "renameTable", "table": "users", "to": "members"],
            ["op": "renameColumn", "table": "members", "column": "id", "to": "member_id"]
        ]))
        #expect(review.changes.first { $0.id == "users" }?.kind == .removed)
        #expect(review.changes.first { $0.id == "members" }?.kind == .added)
        #expect(review.after.relations.first { $0.id == "users_team" }?.source == "members")
        let incoming = try #require(review.after.relations.first { $0.id == "audit_user" })
        #expect(incoming.target == "members" && incoming.targetColumns == ["member_id"])
        try review.validate()
    }

    @Test func partialColumnEditsPreserveOmittedValuesAndNullClearsDefault() throws {
        let review = try SchemaPreview.project(baseline(), planData: plan([
            ["op": "alterColumn", "table": "users", "column": "email", "set": ["defaultSQL": "'pending'", "notNull": true]],
            ["op": "alterColumn", "table": "users", "column": "email", "set": ["type": "VARCHAR(120)"]],
            ["op": "alterColumn", "table": "users", "column": "email", "set": ["defaultSQL": NSNull()]]
        ]))
        let email = try #require(review.after.tables.first { $0.id == "users" }?.columns.first { $0.name == "email" })
        #expect(email.defaultSQL == nil && email.notNull && email.type == "VARCHAR(120)")
    }

    @Test(arguments: ["unknownField", "unknownProperty", "unknownOperation", "duplicate", "dependency", "brokenRelation", "badBoolean", "badInteger", "emptyPatch"])
    func invalidPlansFailExplicitly(scenario: String) throws {
        let changes: [[String: Any]]
        switch scenario {
        case "unknownField": changes = [["op": "removeColumn", "table": "users", "column": "missing"]]
        case "unknownProperty": changes = [["op": "addColumn", "table": "users", "column": ["name": "x", "type": "TEXT", "nullable": true]]]
        case "unknownOperation": changes = [["op": "executeSQL", "sql": "DROP TABLE users"]]
        case "duplicate": changes = [["op": "addTable", "table": "users", "columns": [["name": "id", "type": "TEXT"]]]]
        case "dependency": changes = [["op": "removeColumn", "table": "users", "column": "id"]]
        case "brokenRelation": changes = [["op": "alterRelation", "id": "users_team", "set": ["target": "missing"]]]
        case "badBoolean": changes = [["op": "alterColumn", "table": "users", "column": "id", "set": ["notNull": 1]]]
        case "badInteger": changes = [["op": "alterColumn", "table": "users", "column": "id", "set": ["primaryKeyOrdinal": 1.5]]]
        default: changes = [["op": "alterColumn", "table": "users", "column": "id", "set": [:]]]
        }
        #expect(throws: SchemaReviewError.self) { try SchemaPreview.project(baseline(), planData: plan(changes)) }
    }

    @Test func explicitCascadeAndRelationRemovalAreVisible() throws {
        let review = try SchemaPreview.project(baseline(), planData: plan([
            ["op": "removeRelation", "id": "users_team"],
            ["op": "removeColumn", "table": "users", "column": "id", "cascade": true]
        ]))
        #expect(review.after.relations.isEmpty)
        #expect(review.relationChanges.allSatisfy { $0.kind == .removed })
    }

    @Test func fingerprintIgnoresCatalogOrderingButRejectsChangedBaseline() throws {
        let base = baseline()
        var shuffled = base.snapshot; shuffled.tables.reverse(); shuffled.relations.reverse()
        #expect(try SchemaPreview.fingerprint(base.snapshot) == SchemaPreview.fingerprint(shuffled))
        shuffled.tables[0].columns[0].type = "TEXT"
        #expect(throws: SchemaReviewError.self) {
            try SchemaPreview.project(.init(snapshot: shuffled, label: base.label), planData: plan([]))
        }
    }

    @Test func inspectionReadsOnlyRequestedContextAndRejectsProposalAsBaseline() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let base = baseline()
        let index = try #require(JSONSerialization.jsonObject(with: SchemaPreview.inspect(base, limit: 1)) as? [String: Any])
        #expect(index["truncated"] as? Bool == true && index["totalMatches"] as? Int == 3)
        let detail = try #require(JSONSerialization.jsonObject(with: SchemaPreview.inspect(base, tables: ["users"])) as? [String: Any])
        #expect((detail["tables"] as? [[String: Any]])?.count == 1)
        #expect((detail["relations"] as? [[String: Any]])?.count == 2)
        let fieldOnly = try #require(JSONSerialization.jsonObject(with: SchemaPreview.inspect(base, tables: ["users"], columns: ["email"])) as? [String: Any])
        #expect((fieldOnly["tables"] as? [[String: Any]])?.first?["columns"] as? [[String: String]] == [["name": "email", "type": "TEXT"]])
        #expect((fieldOnly["relations"] as? [[String: Any]])?.isEmpty == true)
        let actual = SchemaReviewDocument(title: "Actual", baseRef: "old", headRef: "new", before: base.snapshot, after: base.snapshot)
        let actualURL = root.appendingPathComponent("actual.sgreview"); try actual.write(to: actualURL)
        #expect(try SchemaPreview.loadBaseline(actualURL).label == "new")
        #expect(try SchemaPreview.loadBaseline(actualURL, side: "before").label == "old")
        let preview = try SchemaPreview.project(base, planData: plan([]))
        let previewURL = root.appendingPathComponent("draft.sgpreview"); try preview.write(to: previewURL)
        #expect(try SchemaReviewDocument.load(previewURL).proposal != nil)
        #expect(throws: SchemaReviewError.self) { try SchemaPreview.loadBaseline(previewURL) }
    }

    @Test func postgresIDsKeepSchemaAndAcceptMinimalFields() throws {
        let base = SchemaPreview.Baseline(snapshot: .init(engine: "postgresql", tables: [], relations: []), label: "empty")
        let review = try SchemaPreview.project(base, planData: plan([
            ["op": "addTable", "table": "public.orders", "columns": [["name": "id", "type": "bigint", "primaryKeyOrdinal": 1]]]
        ], base: base))
        #expect(review.after.tables[0].schema == "public" && review.after.tables[0].name == "orders")
        #expect(review.after.tables[0].columns[0].defaultSQL == nil)
    }

    @Test func atomicRefreshPreservesContextRetainsLastGoodPreviewAndRecovers() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("draft.sgpreview")
        let first = try SchemaPreview.project(baseline(), planData: plan([
            ["op": "addColumn", "table": "users", "column": ["name": "approval", "type": "TEXT"]]
        ]))
        try first.write(to: url)
        let suite = "SchemaPreviewTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = AppSession(userDefaults: defaults)
        await session.openDocument(url: url)
        #expect(session.presentedError == nil && session.schemaReview?.proposal != nil)
        session.selectGraphNode("users"); session.graphZoom = 0.57
        let position = session.graphLayout.position(for: "users")
        let second = try SchemaPreview.project(baseline(), planData: plan([
            ["op": "addTable", "table": "new_table", "columns": [["name": "id", "type": "INTEGER"]]]
        ]))
        try second.write(to: url)
        session.refreshSchemaPreviewIfChanged()
        #expect(session.selectedGraphNodeID == "users" && session.graphZoom == 0.57)
        #expect(session.graphLayout.position(for: "users") == position)
        #expect(session.graph.contains(nodeID: "new_table"))
        #expect(session.databaseTarget == nil && session.openTabs.isEmpty)
        try Data("{".utf8).write(to: url, options: .atomic)
        session.refreshSchemaPreviewIfChanged()
        #expect(session.schemaPreviewReloadError != nil && session.graph.contains(nodeID: "new_table"))
        try first.write(to: url)
        session.refreshSchemaPreviewIfChanged()
        #expect(session.schemaPreviewReloadError == nil && !session.graph.contains(nodeID: "new_table"))
        session.closeDatabase()
        try second.write(to: url); session.refreshSchemaPreviewIfChanged()
        #expect(!session.hasOpenDatabase)
    }
}
