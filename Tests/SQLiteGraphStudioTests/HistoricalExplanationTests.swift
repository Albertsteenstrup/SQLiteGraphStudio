import Foundation
import Testing
@testable import StudioCore

@MainActor struct HistoricalExplanationTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("historical-explanation-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func artifact() -> HistoricalExplanationArtifact {
        let column = SchemaReviewSnapshot.Column(name: "id", type: "INTEGER", notNull: true,
            defaultSQL: nil, primaryKeyOrdinal: 1, generated: 0, identity: "")
        let table = SchemaReviewSnapshot.Table(id: "items", schema: nil, name: "items", kind: "table",
            columns: [column], metadata: [:])
        let schema = SchemaReviewSnapshot(engine: "sqlite", tables: [table], relations: [])
        let row = HistoricalExplanationArtifact.CapturedRow(ordinal: 4, values: [
            .init(type: "integer", value: "42")
        ])
        let point = HistoricalExplanationArtifact.Point(id: "point-1", caption: "Items have a primary key.",
            narration: "Items have a primary key.", minimumVisibleMilliseconds: 900,
            extraHoldMilliseconds: 200, advance: "automatic", actions: [
                .object(["type": .string("focus_table"), "table_id": .string("items")])
            ], evidence: [.init(kind: "table", objectID: "items", tableID: "items")])
        return HistoricalExplanationArtifact(title: "Items overview", engine: "sqlite",
            sourceIdentityHash: String(repeating: "a", count: 64),
            sourceRevisionHash: String(repeating: "b", count: 64), schema: schema,
            points: [point], tablePages: [.init(tableID: "items", columns: [.init(name: "id", type: "INTEGER")],
                rows: [row], displayedOffset: 4, omittedRows: 0)])
    }

    @Test func explanationPersistsOnlyBoundedPortableEvidenceAndNeverOverwrites() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("capture.sgexplanation")
        let value = artifact()

        try HistoricalExplanationStore.write(value, to: url)
        let saved = try Data(contentsOf: url)
        let text = String(decoding: saved, as: UTF8.self)
        #expect(!text.contains("postgres://"))
        #expect(!text.contains("password"))
        #expect(!text.contains("databaseURL"))

        let loaded = try HistoricalExplanationStore.load(url)
        #expect(loaded.points.first?.caption == value.points.first?.caption)
        #expect(loaded.points.first?.narration == value.points.first?.narration)
        #expect(loaded.tablePages.first?.tableID == value.tablePages.first?.tableID)
        #expect(loaded.tablePages.first?.rows.first?.values.first?.value == "42")
        #expect(loaded.sourceIdentityHash == value.sourceIdentityHash)
        #expect(throws: HistoricalExplanationError.self) { try HistoricalExplanationStore.write(value, to: url) }
        #expect(try Data(contentsOf: url) == saved)
    }

    @Test func historicalArtifactOpensOfflineWithCapturedGraphAndRows() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("capture.sgexplanation")
        try HistoricalExplanationStore.write(artifact(), to: url)

        let suite = "HistoricalExplanationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = AppSession(userDefaults: defaults)
        await session.openDocument(url: url)

        #expect(session.presentedError == nil)
        #expect(session.historicalExplanationArtifact?.tablePages.first?.rows.first?.values.first?.value == "42")
        #expect(session.historicalExplanationURL == url.standardizedFileURL)
        #expect(session.databaseURL == nil)
        #expect(session.databaseTarget == nil)
        #expect(session.databaseCapabilities == .none)
        #expect(session.graph.contains(nodeID: "items"))
        #expect(session.openTable(named: "items") == nil)
    }

    @Test func historicalReplaySelectsOnlyCapturedPanesReferencedByEachPointOffline() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("capture.sgexplanation")
        var saved = artifact()
        saved.points = [
            .init(id: "table-step", caption: "The saved item row.", narration: nil,
                  minimumVisibleMilliseconds: 500, extraHoldMilliseconds: 0, advance: "manual",
                  actions: [
                    .object(["type": .string("open_table"), "table_id": .string("items")]),
                    .object(["type": .string("set_layout"), "right_pane": .string("tables")]),
                  ], evidence: [
                    .init(kind: "table", objectID: "items", tableID: "items", rowOffset: 4),
                    .init(kind: "query_result", objectID: "query-a", resultID: "query-a", rowOffset: 11),
                  ]),
            .init(id: "query-step", caption: "A saved query page.", narration: nil,
                  minimumVisibleMilliseconds: 500, extraHoldMilliseconds: 0, advance: "manual",
                  actions: [.object(["type": .string("set_layout"), "left_pane": .string("query"),
                                     "right_pane": .string("schema")])],
                  evidence: [.init(kind: "query_result", objectID: "query-b", resultID: "query-b")]),
        ]
        let idColumn = HistoricalExplanationArtifact.CapturedColumn(name: "id", type: "INTEGER")
        saved.queryResults = [
            .init(resultID: "query-a", columns: [idColumn], rows: [
                .init(ordinal: 10, values: [.init(type: "integer", value: "10")]),
                .init(ordinal: 11, values: [.init(type: "integer", value: "11")]),
            ], displayedOffset: 10, omittedRows: 0, sourceWasTruncated: false),
            .init(resultID: "query-b", columns: [idColumn], rows: [
                .init(ordinal: 0, values: [.init(type: "integer", value: "99")]),
            ], displayedOffset: 0, omittedRows: 0, sourceWasTruncated: false),
        ]
        try HistoricalExplanationStore.write(saved, to: url)

        let suite = "HistoricalReplaySelectionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = AppSession(userDefaults: defaults)
        await session.openDocument(url: url)
        #expect(session.databaseURL == nil)
        #expect(session.databaseTarget == nil)

        session.selectHistoricalExplanationPoint(externalPointID: "table-step")
        let tableFrame = try #require(session.historicalReplayView)
        #expect(tableFrame.caption == "The saved item row.")
        #expect(tableFrame.rightPane == "tables")
        #expect(tableFrame.tablePages.map(\.tableID) == ["items"])
        #expect(tableFrame.queryResults.map(\.resultID) == ["query-a"])
        #expect(tableFrame.queryResults.first?.rows.map(\.ordinal) == [10, 11])

        session.selectHistoricalExplanationPoint(externalPointID: "query-step")
        let queryFrame = try #require(session.historicalReplayView)
        #expect(queryFrame.leftPane == "query")
        #expect(queryFrame.rightPane == "schema")
        #expect(queryFrame.tablePages.isEmpty)
        #expect(queryFrame.queryResults.map(\.resultID) == ["query-b"])

        session.selectHistoricalExplanationPoint(externalPointID: "missing-point")
        #expect(session.historicalReplayView?.pointID == nil)
        session.selectHistoricalExplanationPoint(externalPointID: nil)
        #expect(session.historicalReplayView?.pointID == nil)
        #expect(session.databaseURL == nil)
        #expect(session.databaseTarget == nil)
    }

    @Test func historicalExplanationTabRestoresFromItsOfflineArtifactPath() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("capture.sgexplanation")
        try HistoricalExplanationStore.write(artifact(), to: url)

        let suite = "HistoricalExplanationRestoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = WorkspaceTabController(initialSession: AppSession(userDefaults: defaults))
        let openedTab = await original.openDocument(url, activate: true)
        let tab = try #require(openedTab)
        let savedState = original.makeRestorationSnapshot()
        let savedExplanation = try #require(savedState.tabs.first(where: { $0.id == tab.id }))
        #expect(savedExplanation.kind == .explanation)
        #expect(savedExplanation.sourceDocumentPath == url.standardizedFileURL.path)

        let restored = WorkspaceTabController(initialSession: AppSession(userDefaults: defaults))
        await restored.restoreWorkspace(from: savedState)
        let reopened = try #require(restored.activeTab)
        #expect(reopened.kind == .explanation)
        #expect(reopened.session.historicalExplanationArtifact?.title == "Items overview")
        #expect(reopened.session.historicalExplanationURL == url.standardizedFileURL)
        #expect(reopened.session.databaseURL == nil)
        #expect(reopened.session.databaseTarget == nil)
        #expect(reopened.session.graph.contains(nodeID: "items"))

        await restored.closeAllAndWait()
        await original.closeAllAndWait()
    }

    @Test func refreshDraftCannotCarryOldNarrationAndRejectsUnboundedRows() throws {
        let original = artifact()
        let draft = HistoricalExplanationRefreshDraft(title: "Items refresh draft",
            parentArtifactHash: String(repeating: "c", count: 64), engine: "sqlite",
            sourceIdentityHash: String(repeating: "d", count: 64), sourceRevisionHash: String(repeating: "e", count: 64),
            priorSchemaFingerprint: String(repeating: "f", count: 64), freshSchemaFingerprint: String(repeating: "1", count: 64),
            freshSchema: original.schema, tablePages: original.tablePages)
        try draft.validate()
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("refresh.sgrefresh")
        try HistoricalExplanationStore.write(draft, to: url)
        let savedDraft = try Data(contentsOf: url)
        let savedDraftText = String(decoding: savedDraft, as: UTF8.self)
        #expect(!savedDraftText.contains("narration"))
        #expect(!savedDraftText.contains("caption"))
        #expect(try HistoricalExplanationStore.loadRefreshDraft(url).tablePages.first?.tableID == "items")

        var invalid = draft
        invalid.tablePages[0].rows = Array(repeating: original.tablePages[0].rows[0], count: 1_001)
        #expect(throws: HistoricalExplanationError.self) { try invalid.validate() }
    }
}
