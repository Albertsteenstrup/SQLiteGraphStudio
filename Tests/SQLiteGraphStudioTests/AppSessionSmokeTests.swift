import Foundation
import Testing
@testable import StudioCore

@MainActor
struct AppSessionSmokeTests {
    @Test
    func sessionOpensDatabaseAndSurfacesEditFailures() async throws {
        let url = try TestSupport.createFixture(named: "session")
        let service = DatabaseService()
        let session = AppSession(databaseService: service)

        await session.openDatabase(url: url)
        #expect(session.databaseURL == url)
        #expect(!session.tables.isEmpty)

        let tab = try #require(session.openTable(named: "authors", autoLoad: false))
        await tab.reload()
        #expect(tab.chunk.totalRowCount == 8)

        tab.commitEdit(row: 0, columnName: "name", rawValue: "Smoke Test Author")
        try await waitFor {
            tab.row(at: 0)?.values[1] == .text("Smoke Test Author")
        }

        tab.commitEdit(row: 0, columnName: "email", rawValue: "author2@example.com")
        try await waitFor {
            (tab.inlineErrorMessage ?? "").contains("UNIQUE")
        }
    }

    @Test
    func sessionRestoresPersistedGraphLayoutForDatabase() async throws {
        let url = try TestSupport.createFixture(named: "persisted-layout")
        let defaultsSuiteName = "SQLiteGraphStudioTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        userDefaults.removePersistentDomain(forName: defaultsSuiteName)

        do {
            let firstSession = AppSession(databaseService: DatabaseService(), userDefaults: userDefaults)
            await firstSession.openDatabase(url: url)
            firstSession.graphLayout.pin(nodeID: "posts", at: CGPoint(x: 210, y: -40))
            firstSession.graphLayout.pin(nodeID: "authors", at: CGPoint(x: -120, y: 64))
            firstSession.persistCurrentGraphLayout()

            let secondSession = AppSession(databaseService: DatabaseService(), userDefaults: userDefaults)
            await secondSession.openDatabase(url: url)

            #expect(secondSession.graphLayout.position(for: "posts") == CGPoint(x: 210, y: -40))
            #expect(secondSession.graphLayout.position(for: "authors") == CGPoint(x: -120, y: 64))
            #expect(secondSession.graphLayout.hasRestoredSnapshot)
        }

        userDefaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    @Test
    func sessionRestoresPersistedStoryGraphLayoutForDatabase() async throws {
        let url = try TestSupport.createFixture(named: "persisted-story-layout")
        let defaultsSuiteName = "SQLiteGraphStudioTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        userDefaults.removePersistentDomain(forName: defaultsSuiteName)

        do {
            let firstSession = AppSession(databaseService: DatabaseService(), userDefaults: userDefaults)
            await firstSession.openDatabase(url: url)
            firstSession.showStoryCardsInGraph = true
            firstSession.showOnlyStoryCardsInGraph = true
            firstSession.pinStoryGraphPosition(
                "dedicated-story",
                at: CGPoint(x: 140, y: -88),
                mode: .dedicated(.fitAll)
            )
            firstSession.pinStoryGraphPosition(
                "anchored-story",
                at: CGPoint(x: -96, y: 52),
                mode: .anchoredToTables
            )
            firstSession.persistStoryGraphLayout()

            let secondSession = AppSession(databaseService: DatabaseService(), userDefaults: userDefaults)
            await secondSession.openDatabase(url: url)

            #expect(
                secondSession.pinnedStoryGraphPosition(for: "dedicated-story", mode: .dedicated(.fitAll))
                    == CGPoint(x: 140, y: -88)
            )
            #expect(
                secondSession.pinnedStoryGraphPosition(for: "anchored-story", mode: .anchoredToTables)
                    == CGPoint(x: -96, y: 52)
            )
        }

        userDefaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    @Test
    func sessionClearsPersistedStoryGraphLayoutForDatabase() async throws {
        let url = try TestSupport.createFixture(named: "clear-story-layout")
        let defaultsSuiteName = "SQLiteGraphStudioTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        userDefaults.removePersistentDomain(forName: defaultsSuiteName)

        do {
            let session = AppSession(databaseService: DatabaseService(), userDefaults: userDefaults)
            await session.openDatabase(url: url)
            session.showStoryCardsInGraph = true
            session.pinStoryGraphPosition("anchored-story", at: CGPoint(x: 42, y: -18), mode: .anchoredToTables)
            session.persistStoryGraphLayout()

            session.clearPersistedStoryGraphLayout()

            #expect(session.pinnedStoryGraphPosition(for: "anchored-story", mode: .anchoredToTables) == nil)
            #expect(userDefaults.data(forKey: "SQLiteGraphStudio.story-graph-layout.\(url.path)") == nil)
        }

        userDefaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    @Test
    func sessionReadsDescriptionsFromSidecar() async throws {
        let url = try TestSupport.createFixture(named: "sidecar-descriptions")
        let sidecar = SchemaSidecar(
            tables: [
                "authors": .init(
                    description: "Author accounts and bylines.",
                    columns: ["email": "Public contact email."]
                ),
            ]
        )
        let data = try JSONEncoder().encode(sidecar)
        try data.write(to: SchemaSidecarStore.sidecarURL(for: url), options: .atomic)

        let session = AppSession(databaseService: DatabaseService())
        await session.openDatabase(url: url)

        #expect(session.tableDescription(for: "authors") == "Author accounts and bylines.")
        #expect(session.columnDescription(for: "authors", column: "email") == "Public contact email.")
        #expect(session.hasAnyDescriptions)
    }

    @Test
    func sessionResolvesQueryResultColumnDescriptions() async throws {
        let url = try TestSupport.createFixture(named: "query-result-descriptions")
        let sidecar = SchemaSidecar(
            tables: [
                "authors": .init(
                    description: "Author accounts and bylines.",
                    columns: ["email": "Public contact email."]
                ),
                "posts": .init(
                    description: "Published and draft posts.",
                    columns: ["slug": "URL-safe public identifier."]
                ),
            ]
        )
        try SchemaSidecarStore.save(sidecar, for: url)

        let session = AppSession(databaseService: DatabaseService())
        await session.openDatabase(url: url)

        #expect(session.descriptionForQueryResultColumn("authors.email") == "Public contact email.")
        #expect(session.descriptionForQueryResultColumn("email") == "authors.email: Public contact email.")
        #expect(session.descriptionForQueryResultColumn("posts") == "Published and draft posts.")
        #expect(session.descriptionForQueryResultColumn("missing") == nil)
    }

    @Test
    func sessionReadsStoriesFromSidecar() async throws {
        let url = try TestSupport.createFixture(named: "sidecar-stories")
        let story = SchemaSidecar.Story(
            id: "author-onboarding",
            title: "Author Onboarding",
            createdAt: "2026-05-18T12:00:00Z",
            prompt: "What happens when an author signs up?",
            actor: "a new author",
            goal: "to create an account",
            benefit: "I can publish posts under my own identity",
            acceptanceCriteria: [
                .init(
                    id: "AC1",
                    given: "a valid signup request",
                    when: "the author account is created",
                    then: "the author can be found by email"
                ),
            ],
            playback: [
                .init(
                    text: "The author account is created first.",
                    spokenText: "First, the author gets an account record.",
                    tables: ["authors"],
                    focus: "authors",
                    expand: "authors",
                    relation: .init(table: "authors", column: "id")
                ),
            ]
        )
        let sidecar = SchemaSidecar(stories: [story])
        try SchemaSidecarStore.save(sidecar, for: url)

        let session = AppSession(databaseService: DatabaseService())
        await session.openDatabase(url: url)

        #expect(session.stories.first?.id == "author-onboarding")
        #expect(session.stories.first?.userStoryText == "As a new author, I want to create an account, so that I can publish posts under my own identity.")
        #expect(session.stories.first?.acceptanceCriteria.first?.displayText == "Given a valid signup request, when the author account is created, then the author can be found by email")
        #expect(session.stories.first?.playback.first?.spokenText == "First, the author gets an account record.")
        #expect(session.stories.first?.playback.first?.relation?.column == "id")
    }

    @Test
    func storyPlaybackAcceptsHumanTextAlias() async throws {
        let url = try TestSupport.createFixture(named: "sidecar-story-human-text")
        let sidecarJSON = """
        {
          "version": 1,
          "stories": [
            {
              "id": "human-text-alias",
              "title": "Human Text Alias",
              "created_at": "2026-05-18T12:00:00Z",
              "playback": [
                {
                  "text": "The visible graph beat stays technical.",
                  "human_text": "The hidden voiceover can sound more natural.",
                  "tables": ["authors"]
                }
              ]
            }
          ]
        }
        """
        try sidecarJSON.write(to: SchemaSidecarStore.sidecarURL(for: url), atomically: true, encoding: .utf8)

        let session = AppSession(databaseService: DatabaseService())
        await session.openDatabase(url: url)

        #expect(session.stories.first?.playback.first?.text == "The visible graph beat stays technical.")
        #expect(session.stories.first?.playback.first?.spokenText == "The hidden voiceover can sound more natural.")
    }

    @Test
    func storiesReadClusterLanguageAndLightweightRelations() async throws {
        let url = try TestSupport.createFixture(named: "sidecar-story-clusters")
        let sidecarJSON = """
        {
          "version": 1,
          "clusters": [
            {
              "id": "publishing",
              "label": "Publishing",
              "tables": ["authors", "posts"],
              "color": "#A8E6A3"
            }
          ],
          "stories": [
            {
              "id": "author-onboarding",
              "title": "Author Onboarding",
              "created_at": "2026-05-18T12:00:00Z",
              "clusters": ["publishing"],
              "related_stories": [
                { "story_id": "author-publishes-post", "kind": "precedes" },
                "author-edits-post"
              ],
              "playback": [
                {
                  "text": "The author account anchors publishing work.",
                  "tables": ["authors", "posts"],
                  "focus": "authors"
                }
              ]
            }
          ]
        }
        """
        try sidecarJSON.write(to: SchemaSidecarStore.sidecarURL(for: url), atomically: true, encoding: .utf8)

        let session = AppSession(databaseService: DatabaseService())
        await session.openDatabase(url: url)

        let story = try #require(session.stories.first)
        #expect(story.clusters == ["publishing"])
        #expect(story.relatedStories.map(\.storyID) == ["author-publishes-post", "author-edits-post"])
        #expect(story.relatedStories.map(\.kind) == ["precedes", "related"])
        #expect(story.coveredTableIDs == ["authors", "posts"])
        #expect(story.primaryTableIDs == ["authors"])

        let coverage = session.schemaSidecar.clusterCoverage(for: story)
        #expect(coverage.first?.clusterID == "publishing")
        #expect(coverage.first?.displayLabel == "Publishing")
        #expect(coverage.first?.tableIDs == ["authors", "posts"])
    }

    @Test
    func legacyStoryStepsDoNotDrivePlayback() async throws {
        let url = try TestSupport.createFixture(named: "legacy-story-steps")
        let legacyJSON = """
        {
          "version": 1,
          "stories": [
            {
              "id": "legacy-steps",
              "title": "Legacy Steps",
              "created_at": "2026-05-18T12:00:00Z",
              "steps": [
                {
                  "text": "This old playback shape should not run.",
                  "tables": ["authors"],
                  "focus": "authors"
                }
              ]
            }
          ]
        }
        """
        try legacyJSON.write(to: SchemaSidecarStore.sidecarURL(for: url), atomically: true, encoding: .utf8)

        let session = AppSession(databaseService: DatabaseService())
        await session.openDatabase(url: url)

        #expect(session.stories.first?.id == "legacy-steps")
        #expect(session.stories.first?.playback.isEmpty == true)
    }

    @Test
    func sessionDeletesStoriesFromSidecar() async throws {
        let url = try TestSupport.createFixture(named: "sidecar-story-delete-\(UUID().uuidString)")
        let story = SchemaSidecar.Story(
            id: "delete-me",
            title: "Delete Me",
            createdAt: "2026-05-18T12:00:00Z",
            playback: [
                .init(text: "A short story.", tables: ["authors"], focus: "authors")
            ]
        )
        try SchemaSidecarStore.save(SchemaSidecar(stories: [story]), for: url)

        let session = AppSession(databaseService: DatabaseService())
        await session.openDatabase(url: url)
        session.deleteStory(id: "delete-me")

        #expect(session.stories.isEmpty)
        #expect(try SchemaSidecarStore.load(for: url).stories.isEmpty)
        #expect(session.refreshToast?.message == "Updated: -1 story")
    }

    @Test
    func sessionShowsRefreshToastWhenSidecarChanges() async throws {
        let url = try TestSupport.createFixture(named: "sidecar-refresh-\(UUID().uuidString)")
        let sidecarURL = SchemaSidecarStore.sidecarURL(for: url)
        try? FileManager.default.removeItem(at: sidecarURL)

        let session = AppSession(databaseService: DatabaseService())
        await session.openDatabase(url: url)
        #expect(session.refreshToast == nil)

        let sidecar = SchemaSidecar(
            tables: [
                "authors": .init(
                    description: "Author rows.",
                    columns: ["email": "Public contact email."]
                ),
            ]
        )
        let data = try JSONEncoder().encode(sidecar)
        try data.write(to: sidecarURL, options: .atomic)

        session.reloadSchemaSidecarFromDisk()

        #expect(session.refreshToast?.message == "Updated: +2 notes")
        #expect(session.tableDescription(for: "authors") == "Author rows.")
        #expect(session.columnDescription(for: "authors", column: "email") == "Public contact email.")

        session.dismissRefreshToast()
        session.reloadSchemaSidecarFromDisk()
        #expect(session.refreshToast == nil)
    }

    @Test
    func refreshSchemaReloadsSidecarAndShowsRefreshToast() async throws {
        let url = try TestSupport.createFixture(named: "schema-refresh-sidecar-\(UUID().uuidString)")
        let sidecarURL = SchemaSidecarStore.sidecarURL(for: url)
        let initialSidecar = SchemaSidecar(
            tables: [
                "authors": .init(description: "Original author note.")
            ]
        )
        try JSONEncoder().encode(initialSidecar).write(to: sidecarURL, options: .atomic)

        let session = AppSession(databaseService: DatabaseService())
        await session.openDatabase(url: url)
        #expect(session.tableDescription(for: "authors") == "Original author note.")

        let updatedSidecar = SchemaSidecar(
            tables: [
                "authors": .init(description: "Updated author note.")
            ]
        )
        try JSONEncoder().encode(updatedSidecar).write(to: sidecarURL, options: .atomic)

        session.refreshSchema()

        try await waitFor {
            session.tableDescription(for: "authors") == "Updated author note."
                && session.refreshToast?.message == "Updated: notes changed"
        }
    }

    @Test
    func sessionOpensAndRunsTopRowsQueryFromGraphAction() async throws {
        let url = try TestSupport.createFixture(named: "top-rows-query")
        let service = DatabaseService()
        let session = AppSession(databaseService: service)

        await session.openDatabase(url: url)
        session.runTopRowsQuery(for: "authors")

        #expect(session.leftPane.kind == .query || session.rightPane.kind == .query)
        #expect(session.queryWorkspace.queries.count >= 2)
        #expect(session.queryWorkspace.activeQuery?.sqlText.contains("LIMIT 10") == true)
        #expect(session.queryWorkspace.activeQuery?.title == "authors Top 10")

        try await waitFor {
            (session.queryWorkspace.activeQuery?.result.rows.count ?? 0) > 0
        }
    }

    @Test
    func sessionPersistsRecentDatabases() async throws {
        let url = try TestSupport.createFixture(named: "recent-databases")
        let defaultsSuiteName = "SQLiteGraphStudioTests.recents.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        userDefaults.removePersistentDomain(forName: defaultsSuiteName)

        do {
            let firstSession = AppSession(databaseService: DatabaseService(), userDefaults: userDefaults)
            await firstSession.openDatabase(url: url)
            #expect(firstSession.recentDatabaseURLs.first == url.standardizedFileURL)

            let secondSession = AppSession(databaseService: DatabaseService(), userDefaults: userDefaults)
            #expect(secondSession.recentDatabaseURLs.first == url.standardizedFileURL)
        }

        userDefaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    private func waitFor(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        stepNanoseconds: UInt64 = 50_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: stepNanoseconds)
        }
        Issue.record("Timed out waiting for condition")
        throw CancellationError()
    }
}
