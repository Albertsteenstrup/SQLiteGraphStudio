import Foundation
import Testing
@testable import StudioCore

/// Searching a chosen project folder must find everything Graph Studio can
/// open, and must not wander into dependency trees or ignored output.
struct ProjectScannerTests {

    // MARK: - Fixture building

    private final class Fixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("project-scan-tests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func write(_ relativePath: String, _ contents: String = "") throws -> URL {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        @discardableResult
        func writeSQLiteDatabase(_ relativePath: String) throws -> URL {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            var data = Data("SQLite format 3\u{0}".utf8)
            data.append(Data(repeating: 0, count: 512))
            try data.write(to: url)
            return url
        }

        func directory(_ relativePath: String) throws {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(relativePath),
                                                    withIntermediateDirectories: true)
        }
    }

    // MARK: - Discovery

    @Test func aMigrationFolderIsFoundAnywhereInTheTree() throws {
        let fixture = try Fixture()
        try fixture.write("backend/postgres/migrations/0001_init.sql", "create table a (id int primary key);")
        try fixture.write("backend/postgres/migrations/0002_more.sql", "create table b (id int primary key);")
        try fixture.write("backend/postgres/migrations/0010_later.sql", "create table c (id int primary key);")

        let result = try ProjectScanner.scan(root: fixture.root)
        let candidate = try #require(result.candidates.first { $0.kind == .migrationSet })
        #expect(candidate.relativePath == "backend/postgres/migrations")
        let set = try #require(candidate.migrationSet)
        #expect(set.files.map(\.version) == ["0001", "0002", "0010"])
        #expect(candidate.detail.contains("3 migrations"))
    }

    @Test func aSingleVersionedFileIsNotAMigrationSet() throws {
        let fixture = try Fixture()
        try fixture.write("db/0001_only.sql", "create table a (id int);")
        let result = try ProjectScanner.scan(root: fixture.root)
        #expect(result.candidates.isEmpty)
    }

    @Test func rollbackFilesAreExcludedAndUpFilesKept() throws {
        let fixture = try Fixture()
        try fixture.write("migrations/000001_init.up.sql", "create table a (id int primary key);")
        try fixture.write("migrations/000001_init.down.sql", "drop table a;")
        try fixture.write("migrations/000002_next.up.sql", "create table b (id int primary key);")
        try fixture.write("migrations/000002_next.down.sql", "drop table b;")

        let candidate = try #require(try ProjectScanner.scan(root: fixture.root).candidates.first)
        let set = try #require(candidate.migrationSet)
        #expect(set.files.map(\.fileName) == ["000001_init.up.sql", "000002_next.up.sql"])
    }

    @Test func versionsSortNumericallyNotAlphabetically() throws {
        let fixture = try Fixture()
        for version in ["2", "10", "1"] {
            try fixture.write("db/migrate/\(version)_step.sql", "create table t\(version) (id int);")
        }
        let candidate = try #require(try ProjectScanner.scan(root: fixture.root).candidates.first)
        #expect(try #require(candidate.migrationSet).files.map(\.version) == ["1", "2", "10"])
    }

    @Test func flywayStyleVersionsAreRecognised() throws {
        let fixture = try Fixture()
        try fixture.write("sql/V1__baseline.sql", "create table a (id int);")
        try fixture.write("sql/V1_1__patch.sql", "create table b (id int);")
        try fixture.write("sql/V2__next.sql", "create table c (id int);")
        let candidate = try #require(try ProjectScanner.scan(root: fixture.root).candidates.first)
        #expect(try #require(candidate.migrationSet).files.map(\.version) == ["1", "1.1", "2"])
    }

    @Test func databasesBackupsAndConnectionDocumentsAreFound() throws {
        let fixture = try Fixture()
        try fixture.writeSQLiteDatabase("data/app.sqlite")
        try fixture.write("data/notes.db", "this is not a database")
        let backup = fixture.root.appendingPathComponent("data/nightly.dump")
        try Data("PGDMP-and-more".utf8).write(to: backup)
        try fixture.write("ops/reader.postgres", """
        {"host":"db.example.test","port":5432,"database":"catalog","username":"reader"}
        """)
        try fixture.write("ops/broken.postgres", "not json")

        let result = try ProjectScanner.scan(root: fixture.root)
        let kinds = Dictionary(grouping: result.candidates, by: \.kind)
        #expect(kinds[.sqliteDatabase]?.map(\.title) == ["app.sqlite"])
        #expect(kinds[.postgresBackup]?.map(\.title) == ["nightly.dump"])
        #expect(kinds[.postgresConnection]?.count == 1)
        // A .db file without the SQLite header, and a .postgres file that is not
        // a connection document, are not offered.
        #expect(!result.candidates.contains { $0.title == "notes.db" })
        #expect(!result.candidates.contains { $0.title == "broken.postgres" })
    }

    @Test func aStandaloneSchemaScriptIsOfferedAsASingleFileModel() throws {
        let fixture = try Fixture()
        try fixture.write("backend/sqlite/schema.sql", "CREATE TABLE country (code TEXT PRIMARY KEY);")
        let candidate = try #require(try ProjectScanner.scan(root: fixture.root).candidates.first)
        #expect(candidate.kind == .schemaScript)
        #expect(try #require(candidate.migrationSet).files.count == 1)
    }

    @Test func migrationSetsSortAheadOfOtherMatches() throws {
        let fixture = try Fixture()
        try fixture.writeSQLiteDatabase("app.sqlite")
        try fixture.write("migrations/0001_a.sql", "create table a (id int);")
        try fixture.write("migrations/0002_b.sql", "create table b (id int);")
        let result = try ProjectScanner.scan(root: fixture.root)
        #expect(result.candidates.map(\.kind) == [.migrationSet, .sqliteDatabase])
    }

    // MARK: - Pruning

    @Test func dependencyAndBuildFoldersAreNeverSearched() throws {
        let fixture = try Fixture()
        try fixture.writeSQLiteDatabase("keep.sqlite")
        for hidden in ["node_modules", ".venv", "venv", "__pycache__", "dist", "build", ".git", "vendor", "target"] {
            try fixture.writeSQLiteDatabase("\(hidden)/buried.sqlite")
        }
        let result = try ProjectScanner.scan(root: fixture.root)
        #expect(result.candidates.map(\.title) == ["keep.sqlite"])
        #expect(result.skippedDirectoryCount >= 9)
    }

    @Test func aVirtualEnvironmentIsRecognisedByItsMarkerFile() throws {
        let fixture = try Fixture()
        try fixture.write("tools/env/pyvenv.cfg", "home = /usr/bin")
        try fixture.writeSQLiteDatabase("tools/env/lib/buried.sqlite")
        try fixture.writeSQLiteDatabase("tools/real.sqlite")
        let result = try ProjectScanner.scan(root: fixture.root)
        #expect(result.candidates.map(\.title) == ["real.sqlite"])
    }

    @Test func gitIgnoredPathsAreSkipped() throws {
        let fixture = try Fixture()
        try fixture.write(".gitignore", """
        # comment
        /generated/
        *.tmp.sqlite
        scratch/
        !scratch/keep/
        """)
        try fixture.writeSQLiteDatabase("kept.sqlite")
        try fixture.writeSQLiteDatabase("throwaway.tmp.sqlite")
        try fixture.writeSQLiteDatabase("generated/out.sqlite")
        try fixture.writeSQLiteDatabase("scratch/temp.sqlite")

        let result = try ProjectScanner.scan(root: fixture.root)
        #expect(result.candidates.map(\.title) == ["kept.sqlite"])
    }

    @Test func gitIgnoreCanBeTurnedOff() throws {
        let fixture = try Fixture()
        try fixture.write(".gitignore", "data/\n")
        try fixture.writeSQLiteDatabase("data/app.sqlite")
        let honoring = try ProjectScanner.scan(root: fixture.root)
        #expect(honoring.candidates.isEmpty)
        let ignoring = try ProjectScanner.scan(root: fixture.root,
                                               limits: ProjectScanLimits(honorsGitIgnore: false))
        #expect(ignoring.candidates.map(\.title) == ["app.sqlite"])
    }

    @Test func aNestedGitIgnoreOverridesTheOuterOne() throws {
        let fixture = try Fixture()
        try fixture.write(".gitignore", "*.sqlite\n")
        try fixture.write("keep/.gitignore", "!*.sqlite\n")
        try fixture.writeSQLiteDatabase("dropped.sqlite")
        try fixture.writeSQLiteDatabase("keep/wanted.sqlite")
        let result = try ProjectScanner.scan(root: fixture.root)
        #expect(result.candidates.map(\.title) == ["wanted.sqlite"])
    }

    @Test func symbolicLinksAreNotFollowed() throws {
        let fixture = try Fixture()
        try fixture.directory("real")
        try fixture.writeSQLiteDatabase("real/app.sqlite")
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("loop"),
            withDestinationURL: fixture.root
        )
        let result = try ProjectScanner.scan(root: fixture.root)
        #expect(result.candidates.map(\.relativePath) == ["real/app.sqlite"])
    }

    @Test func depthIsBounded() throws {
        let fixture = try Fixture()
        let deep = (0..<8).map { "level\($0)" }.joined(separator: "/")
        try fixture.writeSQLiteDatabase("\(deep)/deep.sqlite")
        let shallow = try ProjectScanner.scan(root: fixture.root, limits: ProjectScanLimits(maximumDepth: 3))
        #expect(shallow.candidates.isEmpty)
        let full = try ProjectScanner.scan(root: fixture.root, limits: ProjectScanLimits(maximumDepth: 12))
        #expect(full.candidates.count == 1)
    }

    @Test func aCancelledScanStops() async throws {
        let fixture = try Fixture()
        // Enough work that cancellation cannot lose a race with completion.
        for index in 0..<250 { try fixture.writeSQLiteDatabase("folder\(index)/app.sqlite") }
        let root = fixture.root
        let task = Task.detached { try ProjectScanner.scan(root: root) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// The walk runs on a detached task, which inherits neither cancellation nor
    /// the waiter's — so Cancel has to reach the walk itself rather than only
    /// hiding the progress panel.
    @MainActor @Test func cancellingFromTheSessionPresentsNothingAfterwards() async throws {
        let fixture = try Fixture()
        for index in 0..<400 { try fixture.writeSQLiteDatabase("folder\(index)/app.sqlite") }
        let session = AppSession(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)

        session.scanProject(at: fixture.root)
        #expect(session.projectScan != nil)
        session.cancelProjectScan()
        #expect(session.projectScan == nil)

        // A cancelled scan must never land a picker or an error afterwards.
        try await Task.sleep(for: .milliseconds(500))
        #expect(session.projectCandidates == nil)
        #expect(session.presentedError == nil)
        #expect(session.hasOpenDatabase == false)
    }

    // MARK: - Pattern matching

    /// A `.gitignore` comes from whatever folder the user points at. Wildcard
    /// runs used to compile to a backtracking regular expression, where a
    /// fifteen-character line took minutes against one filename.
    @Test func wildcardHeavyPatternsMatchQuickly() throws {
        let fixture = try Fixture()
        try fixture.write(".gitignore", String(repeating: "*a", count: 12) + "*z\n")
        try fixture.writeSQLiteDatabase(String(repeating: "a", count: 80) + ".sqlite")
        try fixture.writeSQLiteDatabase("plain.sqlite")

        let clock = ContinuousClock()
        let start = clock.now
        let result = try ProjectScanner.scan(root: fixture.root)
        #expect(clock.now - start < .seconds(5))
        #expect(result.candidates.map(\.title).contains("plain.sqlite"))
    }

    @Test func globSyntaxIsHonoured() throws {
        let fixture = try Fixture()
        let rules = ["build?/", "logs/**/tmp/", "[abc]-scratch/", "!keep-me.sqlite"].joined(separator: "\n")
        try fixture.write(".gitignore", rules)
        try fixture.writeSQLiteDatabase("build1/hidden.sqlite")
        // `?` is exactly one character, so a two-character suffix is not matched.
        try fixture.writeSQLiteDatabase("buildxy/kept-one.sqlite")
        try fixture.writeSQLiteDatabase("logs/one/two/tmp/hidden.sqlite")
        try fixture.writeSQLiteDatabase("logs/one/kept-two.sqlite")
        try fixture.writeSQLiteDatabase("b-scratch/hidden.sqlite")
        try fixture.writeSQLiteDatabase("d-scratch/kept-three.sqlite")

        let titles = Set(try ProjectScanner.scan(root: fixture.root).candidates.map(\.title))
        #expect(titles == ["kept-one.sqlite", "kept-two.sqlite", "kept-three.sqlite"])
    }

    /// Ignore files belong to their own branch. Accumulating them across the
    /// whole walk made a per-package monorepo cost far more than the walk.
    @Test func aSiblingGitIgnoreDoesNotReachAnotherBranch() throws {
        let fixture = try Fixture()
        try fixture.write("left/.gitignore", "*.sqlite\n")
        try fixture.writeSQLiteDatabase("left/hidden.sqlite")
        try fixture.writeSQLiteDatabase("right/kept.sqlite")
        let titles = try ProjectScanner.scan(root: fixture.root).candidates.map(\.title)
        #expect(titles == ["kept.sqlite"])
    }

    // MARK: - Resolving a chosen target

    @Test func resolvingAMigrationDirectoryReadsItAgain() throws {
        let fixture = try Fixture()
        try fixture.write("migrations/0001_a.sql", "create table a (id int primary key);")
        try fixture.write("migrations/0002_b.sql", "create table b (id int primary key);")
        let set = try ProjectScanner.migrationSet(at: fixture.root.appendingPathComponent("migrations"))
        #expect(set.files.count == 2)
        #expect(set.dialect == .postgreSQL)
    }

    @Test func resolvingASingleScriptMakesAOneFileSet() throws {
        let fixture = try Fixture()
        let url = try fixture.write("schema.sql", "CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT);")
        let set = try ProjectScanner.migrationSet(at: url)
        #expect(set.files.map(\.fileName) == ["schema.sql"])
        #expect(set.dialect == .sqlite)
    }

    @Test func resolvingAFolderWithoutVersionedFilesFails() throws {
        let fixture = try Fixture()
        try fixture.write("notes/readme.sql", "select 1;")
        #expect(throws: DatabaseUserError.self) {
            try ProjectScanner.migrationSet(at: fixture.root.appendingPathComponent("notes"))
        }
    }

    // MARK: - Version parsing

    @Test func migrationVersionParsingCoversTheCommonNamingSchemes() {
        #expect(ProjectScanner.migrationVersion(fileName: "0042_add_orders.sql")?.version == "0042")
        #expect(ProjectScanner.migrationVersion(fileName: "001-add-orders.sql")?.version == "001")
        #expect(ProjectScanner.migrationVersion(fileName: "20240115093000_add.sql")?.version == "20240115093000")
        #expect(ProjectScanner.migrationVersion(fileName: "7.sql")?.version == "7")
        #expect(ProjectScanner.migrationVersion(fileName: "V2_1__patch.sql")?.version == "2.1")
        #expect(ProjectScanner.migrationVersion(fileName: "0003_x.up.sql")?.version == "0003")
        #expect(ProjectScanner.migrationVersion(fileName: "0003_x.down.sql") == nil)
        #expect(ProjectScanner.migrationVersion(fileName: "schema.sql") == nil)
        #expect(ProjectScanner.migrationVersion(fileName: "0001_init.txt") == nil)
        // A leading number that is part of a word is not a version.
        #expect(ProjectScanner.migrationVersion(fileName: "2fa_setup.sql") == nil)
    }

    @Test func naturalSortKeysOrderNumbersByValue() {
        let sorted = ["10", "2", "1"].map(ProjectScanner.naturalSortKey).sorted()
        #expect(sorted == ["1", "2", "10"].map(ProjectScanner.naturalSortKey))
    }

    @Test func migrationLabelsReadAsVersionAndDescription() {
        let file = MigrationFile(url: URL(fileURLWithPath: "/tmp/0042_add_orders.sql"),
                                 version: "0042", sortKey: "0042", fileName: "0042_add_orders.sql")
        #expect(file.displayLabel == "0042 · add orders")
    }
}
