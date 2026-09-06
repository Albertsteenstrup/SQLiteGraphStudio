import Foundation

struct PostgresRuntime: Sendable {
    let bin: URL
    func tool(_ name: String) -> URL { bin.appendingPathComponent(name) }

    static func discover() throws -> Self {
        var candidates: [URL] = []
        if let explicit = ProcessInfo.processInfo.environment["SGS_POSTGRES_RUNTIME"] {
            candidates.append(URL(fileURLWithPath: explicit).appendingPathComponent("bin"))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("PostgreSQL/bin"))
        }
        for major in [18, 17] {
            for prefix in ["/opt/homebrew/opt", "/usr/local/opt"] {
                candidates.append(URL(fileURLWithPath: "\(prefix)/postgresql@\(major)/bin"))
            }
            candidates.append(URL(fileURLWithPath: "/Applications/Postgres.app/Contents/Versions/\(major)/bin"))
        }
        let required = ["postgres", "initdb", "pg_restore", "psql"]
        guard let bin = candidates.first(where: { candidate in
            required.allSatisfy { FileManager.default.isExecutableFile(atPath: candidate.appendingPathComponent($0).path) }
        }) else {
            throw DatabaseUserError(kind: .notFound, message: "The PostgreSQL runtime for opening backups is unavailable.",
                recoverySuggestion: "Use a Graph Studio build with the PostgreSQL runtime, or install PostgreSQL 17 or later locally. Live connection documents do not require a local runtime.")
        }
        return Self(bin: bin.resolvingSymlinksInPath())
    }
}

/// Owns exactly one disposable copy. No restore command can target an existing
/// user database: all commands use this object's private socket and fixed names.
final class PostgresDumpSession: @unchecked Sendable {
    let directory: URL
    let runtime: PostgresRuntime
    let socketPath: String
    let configuration = PostgresConnectionConfiguration(host: "localhost", database: "studio_snapshot", username: "studio_reader", tlsMode: .disabled)
    private let profile: String
    private var server: PostgresToolProcess?
    private var toolCleanupConfirmed = true

    init(runtime: PostgresRuntime) throws {
        self.runtime = runtime
        // libpq's Unix socket limit is 104 bytes; macOS's per-user temp paths can exceed it.
        directory = URL(fileURLWithPath: "/private/tmp/sgs-pg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        socketPath = directory.appendingPathComponent(".s.PGSQL.5432").path
        profile = Self.sandboxProfile(directory: directory, runtime: runtime)
    }

    static func prepare(url: URL, progress: @escaping @Sendable (String) async -> Void) async throws -> PostgresDumpSession {
        let source = try DatabaseDocument.openArchive(url)
        defer { try? source.close() }
        let session = try PostgresDumpSession(runtime: PostgresRuntime.discover())
        do {
            await progress("Checking PostgreSQL backup…")
            // Tools see only this copy; the selected file is never passed to a writable process.
            let archive = session.directory.appendingPathComponent("source.dump")
            try await copyArchive(from: source, to: archive)
            try Task.checkCancellation()
            let toc = session.directory.appendingPathComponent("archive.list")
            _ = try await session.run("pg_restore", ["--list", "--file", toc.path, archive.path])
            // Only a fixed, vetted extension can be prepared with elevated
            // privileges. No archive-provided SQL runs as the cluster administrator.
            let tocSize = try toc.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard tocSize <= 16_777_216 else {
                throw DatabaseUserError(kind: .invalidInput, message: "This PostgreSQL archive's object list is too large.")
            }
            let tocText = try String(contentsOf: toc, encoding: .utf8)
            let needsVector = tocText.range(of: #"(?m)^\d+; \d+ \d+ EXTENSION - vector[ \t]*$"#, options: .regularExpression) != nil
            await progress("Starting a private PostgreSQL workspace…")
            _ = try await session.run("initdb", ["-D", session.dataDirectory.path, "--username=studio_owner", "--auth-local=trust", "--auth-host=reject", "--locale=C", "--encoding=UTF8", "--no-instructions"])
            let server = session.process("postgres", ["-D", session.dataDirectory.path, "-k", session.directory.path,
                "-c", "listen_addresses=", "-c", "unix_socket_permissions=0700", "-c", "port=5432",
                "-c", "shared_buffers=32MB", "-c", "max_connections=12", "-c", "jit=off",
                "-c", "dynamic_shared_memory_type=mmap", "-c", "autovacuum=off"], superviseParent: true)
            session.server = server
            try server.start()
            var ready = false
            for _ in 0..<100 {
                try Task.checkCancellation()
                guard server.isRunning else {
                    throw DatabaseUserError(kind: .generic, message: "The private PostgreSQL workspace could not start.", recoverySuggestion: server.outputText())
                }
                if FileManager.default.fileExists(atPath: session.socketPath),
                   (try? await session.sql("SELECT 1", database: "postgres")) != nil {
                    ready = true; break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard ready else { throw DatabaseUserError(kind: .timeout, message: "The private PostgreSQL workspace did not become ready.") }
            _ = try await session.sql("CREATE ROLE studio_restore LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS", database: "postgres")
            _ = try await session.sql("CREATE DATABASE studio_snapshot OWNER studio_restore TEMPLATE template0", database: "postgres")
            if needsVector {
                // pgvector needs superuser installation. This fixed command uses
                // the trusted runtime's extension files, never archive SQL.
                _ = try await session.sql("ALTER ROLE studio_restore SUPERUSER; SET ROLE studio_restore; CREATE EXTENSION vector WITH SCHEMA public; RESET ROLE; ALTER ROLE studio_restore NOSUPERUSER")
            }
            await progress("Restoring schema and rows…")
            _ = try await session.run("pg_restore", session.connectionArguments(user: "studio_restore") + [
                "--dbname=studio_snapshot", "--no-owner", "--no-acl", "--no-tablespaces", "--no-subscriptions",
                "--exit-on-error", "--single-transaction", archive.path
            ])
            await progress("Preparing read-only browsing…")
            _ = try await session.sql(Self.readerSQL)
            // PostgreSQL's estimates are empty after restoring; analyze this owned
            // copy before exposing it, without changing the selected archive.
            _ = try await session.sql("ANALYZE")
            try Task.checkCancellation()
            return session
        } catch {
            await session.close()
            throw error
        }
    }

    private var dataDirectory: URL { directory.appendingPathComponent("data") }
    private func connectionArguments(user: String = "studio_owner") -> [String] {
        ["--host", directory.path, "--port=5432", "--username", user, "--no-password"]
    }

    private func process(_ name: String, _ arguments: [String], superviseParent: Bool = false) -> PostgresToolProcess {
        PostgresToolProcess(executable: runtime.tool(name), arguments: arguments, directory: directory,
            profile: superviseParent ? Self.sandboxProfile(directory: directory, runtime: runtime, serverOnly: true) : profile,
            superviseParent: superviseParent)
    }

    static func copyArchive(from input: FileHandle, to destination: URL) async throws {
        let copy = Task.detached {
            // Copy bytes, not a source symlink: chmod must never follow back to the user's file.
            guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw DatabaseUserError(kind: .permission, message: "Could not create a private copy of the PostgreSQL backup.")
            }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            while true {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
        }
        try await withTaskCancellationHandler { try await copy.value } onCancel: { copy.cancel() }
    }

    private func run(_ name: String, _ arguments: [String]) async throws -> String {
        try await run(process(name, arguments))
    }

    func run(_ process: PostgresToolProcess) async throws -> String {
        try Task.checkCancellation()
        do {
            try process.start()
            return try await process.wait()
        } catch {
            // wait() stops a failed/cancelled tool, but only this session owns
            // workspace deletion. Preserve a failed confirmation even during
            // initialization, before there is a server for close() to inspect.
            if !(await process.stop()) { toolCleanupConfirmed = false }
            throw error
        }
    }

    private func sql(_ statement: String, database: String = "studio_snapshot") async throws -> String {
        // Archive-owned database defaults must not influence privileged catalog
        // hardening (for example by shadowing format() or pg_namespace).
        // Separate -c commands keep CREATE DATABASE outside a transaction block.
        try await run("psql", connectionArguments() + ["--dbname", database, "--no-psqlrc", "--set=ON_ERROR_STOP=1",
            "--command", "SET search_path=pg_catalog", "--command", statement])
    }

    func close() async {
        if let server, !(await server.stop()) { return }
        guard toolCleanupConfirmed else { return }
        // Both server and tool shutdown must be confirmed before deletion.
        try? FileManager.default.removeItem(at: directory)
    }

    private static let readerSQL = """
    ALTER ROLE studio_restore NOLOGIN;
    CREATE ROLE studio_reader LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION BYPASSRLS;
    ALTER ROLE studio_reader SET default_transaction_read_only = on;
    REVOKE ALL ON DATABASE studio_snapshot FROM PUBLIC;
    GRANT CONNECT ON DATABASE studio_snapshot TO studio_reader;
    DO $studio$
    DECLARE item record;
    BEGIN
      FOR item IN SELECT nspname FROM pg_namespace WHERE nspname NOT IN ('pg_catalog', 'information_schema') AND nspname NOT LIKE 'pg_toast%' AND nspname NOT LIKE 'pg_temp_%'
      LOOP
        EXECUTE format('REVOKE CREATE ON SCHEMA %I FROM PUBLIC', item.nspname);
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO studio_reader', item.nspname);
        EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO studio_reader', item.nspname);
        EXECUTE format('REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA %I FROM PUBLIC', item.nspname);
      END LOOP;
      FOR item IN SELECT p.oid::regprocedure AS signature FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        JOIN pg_language l ON l.oid = p.prolang
        WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND p.prokind = 'f' AND p.provolatile IN ('s', 'i') AND NOT p.prosecdef
          AND l.lanname IN ('sql', 'plpgsql')
      LOOP
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO studio_reader', item.signature);
      END LOOP;
    END $studio$;
    """

    static func sandboxProfile(directory: URL, runtime: PostgresRuntime, serverOnly: Bool = false) -> String {
        func quoted(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let readable = ["/System", "/usr", "/bin", "/dev", "/private/etc", "/private/var/db/timezone",
                        "/opt/homebrew", "/Library/Apple", runtime.bin.deletingLastPathComponent().path, directory.path]
        return """
        (version 1)
        (deny default)
        (allow process* sysctl-read mach-lookup ipc-posix* ipc-sysv*)
        (allow signal (target same-sandbox))
        (allow file-read-metadata)
        (allow file-read-data (literal "/"))
        (allow file-read* \(readable.map { "(subpath \(quoted($0)))" }.joined(separator: " ")))
        (allow file-write* (subpath \(quoted(directory.path))) (literal "/dev/null"))
        (allow network-bind network-inbound network-outbound
          (literal \(quoted(directory.appendingPathComponent(".s.PGSQL.5432").path))))
        \(serverOnly ? """
        (deny process-exec (require-not (literal \(quoted(runtime.tool("postgres").path)))))
        (deny file-map-executable (subpath \(quoted(directory.path))))
        """ : "")
        """
    }
}
