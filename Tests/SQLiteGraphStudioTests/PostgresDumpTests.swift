import Foundation
import Darwin
import Testing
@testable import StudioCore

@MainActor @Suite(.serialized) struct PostgresDumpTests {
    @Test func fifoAndDirectoryArchivesAreRejectedWithoutBlocking() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("pipe")
        let link = directory.appendingPathComponent("fjordholm.dump")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fifo)
        #expect(throws: DatabaseUserError.self) { try DatabaseDocument.openArchive(link) }
        #expect(throws: DatabaseUserError.self) { try DatabaseDocument.openArchive(directory) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_POSTGRES_DUMP_TEST_FILE"] != nil,
                   "Set SGS_POSTGRES_DUMP_TEST_FILE to verify the restore sandbox"))
    func sandboxCannotConnectToAnOutsideUnixSocket() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/sgs-sandbox-\(UUID())")
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketURL = root.appendingPathComponent("outside.sock")
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(listener >= 0)
        defer { Darwin.close(listener) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { buffer in
                _ = socketURL.path.withCString { strlcpy(buffer, $0, 104) }
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0)
        try #require(listen(listener, 1) == 0)
        _ = fcntl(listener, F_SETFL, O_NONBLOCK)
        let runtime = try PostgresRuntime.discover()
        let process = PostgresToolProcess(executable: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: ["--max-time", "1", "--unix-socket", socketURL.path, "http://localhost/_ping"],
            directory: workspace, profile: PostgresDumpSession.sandboxProfile(directory: workspace, runtime: runtime))
        try process.start()
        _ = try? await process.wait(timeout: 3)
        let incoming = accept(listener, nil, nil)
        if incoming >= 0 { Darwin.close(incoming) }
        #expect(incoming == -1, "The restore sandbox connected to a socket outside its workspace")
    }

    @Test func copyingSymlinkArchiveDoesNotChangeSourcePermissions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.dump")
        let alias = directory.appendingPathComponent("alias.dump")
        let copy = directory.appendingPathComponent("copy.dump")
        let bytes = Data(("PGDMP" + String(repeating: "x", count: 32)).utf8)
        try bytes.write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.path)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let input = try DatabaseDocument.openArchive(alias)
        defer { try? input.close() }
        // Replace the selected path after validation: copying must still use
        // the already-validated regular file, never reopen this FIFO alias.
        try FileManager.default.removeItem(at: alias)
        let fifo = directory.appendingPathComponent("replacement-pipe")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fifo)
        try await PostgresDumpSession.copyArchive(from: input, to: copy)
        #expect(try Data(contentsOf: copy) == bytes)
        #expect(try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? Int == 0o640)
        #expect(try FileManager.default.attributesOfItem(atPath: copy.path)[.type] as? FileAttributeType == .typeRegular)
    }

    @Test func auditTokenSignalRejectsAReplacementProcessVersion() throws {
        var token = try #require(PostgresToolProcess.auditToken(getpid()))
        var replacement = token
        replacement.val.7 &+= 1
        #expect(proc_signal_with_audittoken(&replacement, SIGCONT) == ESRCH)
        // A harmless legitimate signal to this same running test process.
        #expect(proc_signal_with_audittoken(&token, SIGCONT) == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_POSTGRES_DUMP_TEST_FILE"] != nil,
                   "Set SGS_POSTGRES_DUMP_TEST_FILE to verify fail-closed process enumeration"))
    func failedEnumerationCannotAuthorizeWorkspaceDeletion() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/sgs-process-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = try PostgresRuntime.discover()
        let process = PostgresToolProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
            directory: directory, profile: PostgresDumpSession.sandboxProfile(directory: directory, runtime: runtime),
            listChildren: { _, _, _ in errno = EACCES; return 0 })
        try process.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!(await process.stop()), "An enumeration failure must not authorize deletion")
        #expect(!process.isRunning)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_POSTGRES_DUMP_TEST_FILE"] != nil,
                   "Set SGS_POSTGRES_DUMP_TEST_FILE to verify initialization cleanup ownership"),
          arguments: [false, true])
    func initializationCleanupRemovesOnlyConfirmedWorkspaces(failEnumeration: Bool) async throws {
        let runtime = try PostgresRuntime.discover()
        let session = try PostgresDumpSession(runtime: runtime)
        defer { try? FileManager.default.removeItem(at: session.directory) }
        // A real cancellable child stands in for the initialization phase,
        // before a PostgreSQL server exists. Only libproc failure is injected.
        let process = PostgresToolProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
            directory: session.directory,
            profile: PostgresDumpSession.sandboxProfile(directory: session.directory, runtime: runtime),
            listChildren: { parent, buffer, size in
                if failEnumeration { errno = EACCES; return 0 }
                return proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), buffer, size)
            })
        let initializing = Task { try await session.run(process) }
        let deadline = Date().addingTimeInterval(3)
        while !process.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(process.isRunning)
        initializing.cancel()
        _ = try? await initializing.value
        await session.close()
        #expect(!process.isRunning)
        #expect(FileManager.default.fileExists(atPath: session.directory.path) == failEnumeration,
                "Only confirmed initialization cleanup may delete the workspace")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_POSTGRES_DUMP_TEST_FILE"] != nil,
                   "Set SGS_POSTGRES_DUMP_TEST_FILE to verify first-observer cancellation"))
    func cancellationCannotHideAnAlreadyExitedSupervisor() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/sgs-process-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = try PostgresRuntime.discover()
        let process = PostgresToolProcess(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [],
            directory: directory, profile: PostgresDumpSession.sandboxProfile(directory: directory, runtime: runtime), superviseParent: true)
        try process.start()
        // Do not poll isRunning: cancellation must be the first exit observer.
        try await Task.sleep(for: .seconds(1))
        #expect(!(await process.stop()), "Unexpected supervisor exit invalidates cleanup completeness")
        #expect(!process.isRunning)
    }
    @Test func otherPickerAcceptsArchivesAndConnectionsButNotUnimplementedFormats() {
        let filter = DatabaseDocumentOpenPanelDelegate(extensions: DatabaseDocument.otherExtensions)
        for name in ["fjordholm.dump", "snapshot.BACKUP", "live.postgres", "live.pgstudio"] {
            #expect(filter.panel(NSNull(), shouldEnable: URL(fileURLWithPath: "/tmp/\(name)")))
        }
        for name in ["mysql.sql", "archive.zip", "data.csv", "local.sqlite"] {
            #expect(!filter.panel(NSNull(), shouldEnable: URL(fileURLWithPath: "/tmp/\(name)")))
        }
        #expect(filter.panel(NSNull(), shouldEnable: FileManager.default.temporaryDirectory))
    }

    @Test func dumpIdentitySurvivesCodingAndDoesNotUseTheTemporaryServer() throws {
        let url = URL(fileURLWithPath: "/tmp/fjordholm.dump")
        let target = DatabaseTarget.postgresDump(url)
        #expect(try JSONDecoder().decode(DatabaseTarget.self, from: JSONEncoder().encode(target)) == target)
        #expect(target.fileURL == url)
        #expect(target.isPostgres)
        #expect(target.stableStorageKey == DatabaseTarget.postgresDump(url).stableStorageKey)
        #expect(target.stableStorageKey != DatabaseTarget.postgresDump(URL(fileURLWithPath: "/tmp/other.dump")).stableStorageKey)
        #expect(target.displayName == "fjordholm.dump")
    }

    @Test func invalidDumpReportsAnArchiveErrorInsteadOfOpeningAsSQLite() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).dump")
        try Data("PGDMP".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = AppSession()
        await session.openDocument(url: url)
        #expect(!session.hasOpenDatabase)
        #expect(session.presentedError?.message.localizedCaseInsensitiveContains("archive") == true)
        session.closeDatabase()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_POSTGRES_DUMP_TEST_FILE"] != nil,
                   "Set SGS_POSTGRES_DUMP_TEST_FILE to verify subprocess escalation"))
    func forcedShutdownStopsTheWholeOwnedProcessGroup() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/sgs-process-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = try PostgresRuntime.discover()
        let process = PostgresToolProcess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' INT TERM; /bin/sleep 30 & wait"], directory: directory,
            profile: PostgresDumpSession.sandboxProfile(directory: directory, runtime: runtime))
        try process.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await process.stop())
        #expect(!process.isRunning)
        #expect(await process.stop())
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_POSTGRES_DUMP_TEST_FILE"] != nil,
                   "Set SGS_POSTGRES_DUMP_TEST_FILE to verify detached worker cleanup"))
    func forcedShutdownStopsChildrenInSeparateSessions() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/sgs-process-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = try PostgresRuntime.discover()
        let process = PostgresToolProcess(executable: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-MPOSIX", "-e", """
                $SIG{INT} = $SIG{TERM} = $SIG{QUIT} = 'IGNORE';
                $| = 1;
                if (fork() == 0) { POSIX::setsid(); print "worker=$$\\n"; sleep 30; exit 0; }
                sleep 30;
                """], directory: directory,
            profile: PostgresDumpSession.sandboxProfile(directory: directory, runtime: runtime))
        try process.start()
        let deadline = Date().addingTimeInterval(3)
        while !process.outputText().contains("worker="), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let line = try #require(process.outputText().split(separator: "\n").first(where: { $0.hasPrefix("worker=") }))
        let child = try #require(Int32(line.dropFirst("worker=".count)))
        var childToken = try #require(PostgresToolProcess.auditToken(child))
        defer { _ = proc_signal_with_audittoken(&childToken, SIGKILL) }
        #expect(getpgid(child) == child)
        #expect(await process.stop())
        #expect(Darwin.kill(child, 0) == -1 && errno == ESRCH, "A setsid worker survived shutdown")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_POSTGRES_DUMP_TEST_FILE"] != nil,
                   "Set SGS_POSTGRES_DUMP_TEST_FILE to verify row security and function-backed views"))
    func snapshotShowsRLSRowsAndSafeFunctionViews() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SGS_POSTGRES_DUMP_TEST_FILE"])
        let seed = try await PostgresDumpSession.prepare(url: URL(fileURLWithPath: path), progress: { _ in })
        let service = DatabaseService()
        do {
            let connection = ["--host", seed.directory.path, "--username=studio_owner"]
            @discardableResult func run(_ tool: String, _ arguments: [String]) async throws -> String {
                let process = PostgresToolProcess(executable: seed.runtime.tool(tool), arguments: arguments,
                    directory: seed.directory, profile: PostgresDumpSession.sandboxProfile(directory: seed.directory, runtime: seed.runtime))
                try process.start()
                return try await process.wait()
            }
            let privileges = try await run("psql", connection + ["--dbname=postgres", "--no-psqlrc", "--tuples-only", "--no-align",
                "--command", "SELECT rolsuper, rolcreaterole, rolcreatedb FROM pg_roles WHERE rolname='studio_restore'"])
            #expect(privileges.trimmingCharacters(in: .whitespacesAndNewlines) == "f|f|f")
            // Even restore-owner SQL cannot launch an orphan factory. The
            // production server sandbox rejects COPY PROGRAM's shell exec.
            await #expect(throws: (any Error).self) {
                try await run("psql", connection + ["--dbname=postgres", "--no-psqlrc", "--set=ON_ERROR_STOP=1",
                    "--command", "COPY (SELECT 1) TO PROGRAM '/usr/bin/true'"])
            }
            try await run("psql", connection + ["--dbname=postgres", "--no-psqlrc", "--command", "ALTER ROLE studio_restore LOGIN"])
            let restoreConnection = ["--host", seed.directory.path, "--username=studio_restore", "--dbname=studio_snapshot", "--no-psqlrc", "--set=ON_ERROR_STOP=1"]
            await #expect(throws: (any Error).self) {
                try await run("psql", restoreConnection + ["--command", "COPY (SELECT 1) TO PROGRAM '/usr/bin/true'"])
            }
            await #expect(throws: (any Error).self) {
                try await run("psql", restoreConnection + ["--command", "CREATE FUNCTION forbidden_native() RETURNS void AS 'pgcrypto', 'pg_random_bytes' LANGUAGE c"])
            }
            try await run("psql", connection + ["--dbname=postgres", "--no-psqlrc", "--set=ON_ERROR_STOP=1", "--command", "CREATE DATABASE regression"])
            try await run("psql", connection + ["--dbname=regression", "--no-psqlrc", "--set=ON_ERROR_STOP=1", "--command", """
                CREATE TABLE items(id integer PRIMARY KEY, name text);
                INSERT INTO items VALUES (1, 'one'), (2, 'two');
                ALTER TABLE items ENABLE ROW LEVEL SECURITY;
                ALTER TABLE items FORCE ROW LEVEL SECURITY;
                CREATE FUNCTION item_count() RETURNS bigint LANGUAGE sql STABLE AS 'SELECT count(*) FROM public.items';
                CREATE VIEW counts AS SELECT item_count() AS total;
                CREATE FUNCTION unsafe_write() RETURNS integer LANGUAGE plpgsql VOLATILE AS
                  'BEGIN INSERT INTO public.items VALUES (3, ''three''); RETURN 3; END';
                CREATE VIEW unsafe_view AS SELECT unsafe_write() AS value;
                -- A restored CHECK can alter its owned database's defaults.
                -- Privileged post-restore setup must not resolve this fake
                -- catalog table through the archive-controlled search_path.
                CREATE TABLE public.pg_namespace(nspname name);
                CREATE FUNCTION public.change_database_path() RETURNS boolean LANGUAGE plpgsql AS
                  'BEGIN EXECUTE ''ALTER DATABASE '' || pg_catalog.quote_ident(pg_catalog.current_database()) ||
                    '' SET search_path=public,pg_catalog''; RETURN true; END';
                CREATE TABLE public.path_probe(id integer CHECK(public.change_database_path()));
                INSERT INTO public.path_probe VALUES (1);
                """])
            let archive = seed.directory.appendingPathComponent("regression.dump")
            try await run("pg_dump", connection + ["--dbname=regression", "--format=custom", "--file", archive.path])
            try await service.open(dump: archive)
            let items = try await service.executeReadOnlyQuery(sql: "SELECT count(*) FROM public.items")
            #expect(items.rows.first?.values.first?.displayText == "2")
            let counts = try await service.executeReadOnlyQuery(sql: "SELECT total FROM public.counts")
            #expect(counts.rows.first?.values.first?.displayText == "2")
            await #expect(throws: (any Error).self) {
                try await service.executeReadOnlyQuery(sql: "SELECT * FROM public.unsafe_view")
            }
            await service.close()
            await seed.close()
        } catch {
            await service.close()
            await seed.close()
            throw error
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_POSTGRES_DUMP_TEST_FILE"] != nil,
                   "Set SGS_POSTGRES_DUMP_TEST_FILE to test restore cancellation"))
    func cancellingRestoreCannotReopenTheWorkspace() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SGS_POSTGRES_DUMP_TEST_FILE"])
        let session = AppSession()
        let opening = Task { await session.openDocument(url: URL(fileURLWithPath: path)) }
        let deadline = Date().addingTimeInterval(15)
        while session.documentOpenProgress != "Restoring schema and rows…", Date() < deadline, !opening.isCancelled {
            if session.presentedError != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.documentOpenProgress == "Restoring schema and rows…")
        session.cancelDocumentOpen()
        // Quit immediately after Cancel; termination must join cleanup itself.
        await session.closeAndWait()
        await opening.value
        #expect(!session.hasOpenDatabase)
        #expect(session.documentOpenProgress == nil)
        #expect(session.presentedError == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_POSTGRES_DUMP_TEST_FILE"] != nil,
                   "Set SGS_POSTGRES_DUMP_TEST_FILE to verify owned workspace cleanup"))
    func closingDumpRemovesItsSocketAndPrivateCopy() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SGS_POSTGRES_DUMP_TEST_FILE"])
        let dump = try await PostgresDumpSession.prepare(url: URL(fileURLWithPath: path), progress: { _ in })
        #expect(FileManager.default.fileExists(atPath: dump.socketPath))
        #expect(FileManager.default.fileExists(atPath: dump.directory.appendingPathComponent("source.dump").path))
        await dump.close()
        #expect(!FileManager.default.fileExists(atPath: dump.directory.path))
        await dump.close()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_POSTGRES_DUMP_TEST_FILE"] != nil,
                   "Set SGS_POSTGRES_DUMP_TEST_FILE to verify Quit during a document switch"),
          arguments: [false, true])
    func quitDuringDocumentSwitchJoinsRetiringDump(useConnectionDocument: Bool) async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SGS_POSTGRES_DUMP_TEST_FILE"])
        let service = DatabaseService()
        let session = AppSession(databaseService: service)
        await session.openDocument(url: URL(fileURLWithPath: path))
        let dump = try #require(await service.dumpSession)
        let pidFile = try String(contentsOf: dump.directory.appendingPathComponent("data/postmaster.pid"), encoding: .utf8)
        let postmaster = try #require(pid_t(pidFile.split(separator: "\n")[0]))
        var token = try #require(PostgresToolProcess.auditToken(postmaster))
        try #require(proc_signal_with_audittoken(&token, SIGSTOP) == 0)
        defer { _ = proc_signal_with_audittoken(&token, SIGCONT) }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent(useConnectionDocument ? "next.postgres" : "next.sqlite")
        if useConnectionDocument {
            // The generation guard must cancel before attempting this endpoint.
            let document = PostgresConnectionDocument(host: "127.0.0.1", port: 1, database: "unused", username: "unused", tlsMode: .disabled)
            try JSONEncoder().encode(document).write(to: target)
        } else {
            try Data().write(to: target)
        }
        let switching = Task { await session.openDocument(url: target) }
        let deadline = Date().addingTimeInterval(3)
        while await service.currentTarget != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await service.currentTarget == nil)
        var quitFinished = false
        let quitting = Task { await session.closeAndWait(); quitFinished = true }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!quitFinished, "Quit returned while the old dump server was deliberately paused")
        #expect(proc_signal_with_audittoken(&token, SIGCONT) == 0)
        await quitting.value
        #expect(!FileManager.default.fileExists(atPath: dump.directory.path))
        await switching.value
        await session.closeAndWait()
        #expect(!session.hasOpenDatabase)
        #expect(await service.currentTarget == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SGS_POSTGRES_DUMP_TEST_FILE"] != nil,
                   "Set SGS_POSTGRES_DUMP_TEST_FILE to an owned PostgreSQL custom archive"))
    func opensRealDumpWithoutCredentialsAndClosesLocalServer() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SGS_POSTGRES_DUMP_TEST_FILE"])
        let url = URL(fileURLWithPath: path)
        let original = try Data(contentsOf: url)
        let service = DatabaseService()
        let session = AppSession(databaseService: service)
        await session.openDocument(url: url)
        #expect(session.presentedError == nil)
        #expect(session.isPostgreSQL)
        #expect(session.databaseURL == url.standardizedFileURL)
        #expect(session.databaseCapabilities.isReadOnly)
        #expect(!session.tables.isEmpty)
        if session.hasOpenDatabase {
            let snapshot = try await service.loadCatalogSnapshot()
            let count = try await service.executeReadOnlyQuery(sql: """
                SELECT count(*) FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                WHERE c.relkind IN ('r', 'p', 'v', 'm') AND n.nspname NOT IN ('pg_catalog', 'information_schema')
                  AND n.nspname !~ '^pg_toast' AND n.nspname !~ '^pg_temp_'
                """)
            #expect(count.rows.first?.values.first?.displayText == String(snapshot.descriptors.count))
            #expect(snapshot.graph.nodes.count == snapshot.descriptors.count)
            print("Dump catalog: \(snapshot.descriptors.count) objects, \(snapshot.graph.edges.count) relationships")
            for descriptor in snapshot.descriptors.filter({ $0.summary.objectType == .view }).prefix(20) {
                _ = try await service.fetchChunk(query: TableQueryState(limit: 1), descriptor: descriptor)
            }
            let result = try await service.executeReadOnlyQuery(sql: "SELECT current_setting('transaction_read_only') AS read_only")
            #expect(result.rows.first?.values.first?.displayText == "on")
            await #expect(throws: (any Error).self) {
                try await service.executeReadOnlyQuery(sql: "CREATE TABLE forbidden_write(id integer)")
            }
        }
        await session.closeAndWait()
        #expect(try Data(contentsOf: url) == original)
    }
}
