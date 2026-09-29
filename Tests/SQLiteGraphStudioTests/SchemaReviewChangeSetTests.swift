import CoreGraphics
import Foundation
import Testing
@testable import StudioCore

/// How a review reads: fields in key-first order, edited relations as one change, and
/// changes grouped into connected sets that the graph shows one at a time.
@MainActor struct SchemaReviewChangeSetTests {
    private static func column(_ name: String, _ type: String = "TEXT", notNull: Bool = false, pk: Int = 0) -> SchemaReviewSnapshot.Column {
        .init(name: name, type: type, notNull: notNull, defaultSQL: nil, primaryKeyOrdinal: pk, generated: 0, identity: "")
    }

    private static func table(_ id: String, _ columns: [SchemaReviewSnapshot.Column]) -> SchemaReviewSnapshot.Table {
        .init(id: id, schema: nil, name: id, kind: "table", columns: [column("id", "INTEGER", pk: 1)] + columns, metadata: [:])
    }

    private static func relation(_ id: String, _ source: String, _ column: String, _ target: String,
                                 definition: String? = nil) -> SchemaReviewSnapshot.Relation {
        .init(id: id, source: source, target: target, sourceColumns: [column], targetColumns: ["id"],
              definition: definition ?? "FOREIGN KEY (\(column)) REFERENCES \(target)(id)")
    }

    @Test func fieldsReadKeysFirstThenChanges() throws {
        let before = Self.table("users", [Self.column("a"), Self.column("team_id", "INTEGER"), Self.column("b"), Self.column("d")])
        let after = Self.table("users", [Self.column("a"), Self.column("team_id", "INTEGER"), Self.column("b", notNull: true),
                                         Self.column("d"), Self.column("c")])
        let change = SchemaTableChange(id: "users", before: before, after: after, relationChanged: false)
        #expect(change.reviewColumns(foreignKeys: ["team_id"]).map(\.name) == ["id", "team_id", "b", "c", "a", "d"])

        // A changed foreign key leads the keys.
        let keysBefore = Self.table("links", [Self.column("f1", "INTEGER"), Self.column("f2", "INTEGER")])
        let keysAfter = Self.table("links", [Self.column("f1", "INTEGER"), Self.column("f2", "BIGINT")])
        let keys = SchemaTableChange(id: "links", before: keysBefore, after: keysAfter, relationChanged: false)
        #expect(keys.reviewColumns(foreignKeys: ["f1", "f2"]).map(\.name) == ["id", "f2", "f1"])

        // Even on a crowded card, every foreign key stays before a changed non-key field.
        let hubColumns = (1...6).map { Self.column("ref_\($0)", "INTEGER") }
        let hubBefore = Self.table("hub", hubColumns + [Self.column("note")])
        let hubAfter = Self.table("hub", hubColumns + [Self.column("note"), Self.column("added_at"), Self.column("added_by")])
        let hub = SchemaTableChange(id: "hub", before: hubBefore, after: hubAfter, relationChanged: false)
        let ordered = hub.reviewColumns(foreignKeys: Set(hubColumns.map(\.name))).map(\.name)
        #expect(ordered == ["id"] + hubColumns.map(\.name) + ["added_at", "added_by", "note"])
        #expect(hub.reviewTable(foreignKeys: Set(hubColumns.map(\.name))).columns.map(\.name) == ordered)
    }

    @Test func anEditedRelationIsOneChangeAndAMovedOneIsTwo() throws {
        let tables = [Self.table("users", [Self.column("team_id", "INTEGER"), Self.column("project_id", "INTEGER")]),
                      Self.table("teams", []), Self.table("projects", []), Self.table("orgs", [])]
        let review = SchemaReviewDocument(title: "Relations", baseRef: "a", headRef: "b",
            before: SchemaReviewSnapshot(engine: "sqlite", tables: tables, relations: [
                Self.relation("fk_team", "users", "team_id", "teams", definition: "FOREIGN KEY (team_id) REFERENCES teams(id) ON DELETE RESTRICT"),
                Self.relation("fk_project", "users", "project_id", "projects"),
            ]),
            after: SchemaReviewSnapshot(engine: "sqlite", tables: tables, relations: [
                Self.relation("fk_team", "users", "team_id", "teams", definition: "FOREIGN KEY (team_id) REFERENCES teams(id) ON DELETE CASCADE"),
                Self.relation("fk_project", "users", "project_id", "orgs"),
            ]))
        try review.validate()
        let changes = Dictionary(uniqueKeysWithValues: review.relationChanges.map { ($0.graphID, $0) })
        #expect(Set(changes.keys) == ["fk_team", "before:fk_project", "after:fk_project"])
        let edited = try #require(changes["fk_team"])
        #expect(edited.kind == .modified)
        #expect(edited.relation.definition.hasSuffix("CASCADE"))
        #expect(edited.previous?.definition.hasSuffix("RESTRICT") == true)
        #expect(changes["before:fk_project"]?.kind == .removed && changes["after:fk_project"]?.kind == .added)
        #expect(changes["after:fk_project"]?.previous == nil)
        let touched = Set(review.changes.filter(\.relationChanged).map(\.id))
        #expect(touched == ["users", "teams", "projects", "orgs"])
        #expect(review.foreignKeyColumns["users"] == ["team_id", "project_id"])
    }

    @Test func changeSetsJoinChangedTablesThroughAnyRelation() throws {
        let review = Self.setsReview()
        // users and teams are joined by an unchanged relation; audits and logs by a new one.
        // notes and archive are both changed but only meet through an unchanged table.
        #expect(review.changeSets == [["audits", "logs"], ["teams", "users"], ["archive"], ["notes"]])
    }

    @Test func aReviewFramesItsFirstSetWithoutSelectingAndStepsThroughTheRest() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("change-sets-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sets.sgreview")
        let review = Self.setsReview()
        try review.write(to: url)
        // A suite named by a file path keeps test preferences out of ~/Library/Preferences.
        let defaultsFile = folder.appendingPathComponent("defaults.plist").path
        let defaults = try #require(UserDefaults(suiteName: defaultsFile))
        defer { defaults.removePersistentDomain(forName: defaultsFile) }
        let session = AppSession(userDefaults: defaults)
        await session.openDocument(url: url)
        #expect(session.presentedError == nil)
        #expect(session.schemaReviewChangeSets == review.changeSets)
        #expect(session.currentReviewChangeSetIndex == nil)
        #expect(session.selectedGraphNodeIDs.isEmpty)

        // Cards list their keys and every changed field.
        #expect(session.schemaReviewCardColumns["users"] == ["id", "team_id", "email"])
        #expect(session.schemaReviewCardColumns["logs"]?.isSuperset(of: ["id", "audit_id"]) == true)

        session.stepReviewChangeSet(by: 1)
        #expect(session.currentReviewChangeSetIndex == 0)
        #expect(session.selectedGraphNodeIDs == ["audits", "logs"])
        session.stepReviewChangeSet(by: 1)
        #expect(session.currentReviewChangeSetIndex == 1)
        #expect(session.selectedGraphNodeIDs == ["teams", "users"])
        let reveal = try #require(session.graphRevealRequest)
        #expect(reveal.fits && reveal.tableIDs == ["teams", "users"])

        session.revealReviewChangeSet(at: 3)
        session.stepReviewChangeSet(by: 1)
        #expect(session.currentReviewChangeSetIndex == 3, "Next stops at the last set, as the app's button does")

        session.clearGraphSelection()
        #expect(session.currentReviewChangeSetIndex == nil)
        session.stepReviewChangeSet(by: -1)
        #expect(session.currentReviewChangeSetIndex == 3, "Previous from every change starts at the last set")

        session.requestGraphTap(at: CGPoint(x: 12, y: 34))
        #expect(session.graphTapRequest?.point == CGPoint(x: 12, y: 34))
        session.closeDatabase()
        #expect(session.schemaReviewChangeSets.isEmpty && session.schemaReviewCardColumns.isEmpty)
        #expect(session.graphTapRequest == nil)
    }

    private static func setsReview() -> SchemaReviewDocument {
        let teams = table("teams", [column("name")])
        let hubBridge = table("bridge", [column("notes_id", "INTEGER"), column("archive_id", "INTEGER")])
        let before = SchemaReviewSnapshot(engine: "sqlite", tables: [
            teams, hubBridge,
            table("users", [column("team_id", "INTEGER"), column("email")]),
            table("audits", [column("action")]),
            table("notes", [column("body")]),
            table("archive", [column("label")]),
        ], relations: [
            relation("fk_users_team", "users", "team_id", "teams"),
            relation("fk_bridge_notes", "bridge", "notes_id", "notes"),
            relation("fk_bridge_archive", "bridge", "archive_id", "archive"),
        ])
        let after = SchemaReviewSnapshot(engine: "sqlite", tables: [
            table("teams", [column("name", notNull: true)]), hubBridge,
            table("users", [column("team_id", "INTEGER"), column("email", notNull: true)]),
            table("audits", [column("action"), column("at")]),
            table("logs", [column("audit_id", "INTEGER")]),
            table("notes", [column("body", notNull: true)]),
            table("archive", [column("label", notNull: true)]),
        ], relations: [
            relation("fk_users_team", "users", "team_id", "teams"),
            relation("fk_bridge_notes", "bridge", "notes_id", "notes"),
            relation("fk_bridge_archive", "bridge", "archive_id", "archive"),
            relation("fk_logs_audit", "logs", "audit_id", "audits"),
        ])
        return SchemaReviewDocument(title: "Sets", baseRef: "a", headRef: "b", before: before, after: after)
    }
}
