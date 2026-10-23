import Foundation

public enum MigrationSchemaReplay {
    /// Refuses a single file larger than this rather than pulling an arbitrary
    /// blob that happens to carry a `.sql` suffix into memory.
    static let maximumFileBytes = 16 * 1024 * 1024

    public struct Progress: Sendable, Hashable {
        public let completedFiles: Int
        public let totalFiles: Int
        public let fileName: String
    }

    /// Replays `files` in order and returns the schema they describe.
    public static func buildModel(
        files: [MigrationFile],
        dialect: SQLDialect,
        progress: @Sendable (Progress) -> Void = { _ in }
    ) throws -> MigrationSchemaModel {
        let builder = MigrationSchemaBuilder(dialect: dialect)
        var readFailures: [MigrationDiagnostic] = []

        for (offset, file) in files.enumerated() {
            try Task.checkCancellation()
            progress(Progress(completedFiles: offset, totalFiles: files.count, fileName: file.fileName))
            do {
                builder.apply(sql: try read(file.url), fileName: file.fileName)
            } catch {
                readFailures.append(
                    MigrationDiagnostic(fileName: file.fileName,
                                        message: "could not be read: \(error.localizedDescription)",
                                        statementPreview: "")
                )
            }
        }
        progress(Progress(completedFiles: files.count, totalFiles: files.count, fileName: ""))

        let model = builder.makeModel(fileCount: files.count)
        guard !readFailures.isEmpty else { return model }
        return MigrationSchemaModel(
            catalog: model.catalog,
            diagnostics: readFailures + model.diagnostics,
            fileCount: model.fileCount,
            statementCount: model.statementCount,
            dialect: model.dialect
        )
    }

    /// Enough of a file to recognise dialect markers. Reading whole files just
    /// to guess a dialect made discovery cost seconds per large SQL dump.
    static let dialectSampleBytes = 64 * 1024

    static func read(_ url: URL, limit: Int? = nil) throws -> String {
        if let limit {
            // Read a bounded prefix rather than mapping the file: `.mappedIfSafe`
            // falls back to a whole-file read on volumes it will not map, such as
            // a network share, which would defeat the point of sampling.
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                throw DatabaseUserError(kind: .notFound, message: "the file could not be opened")
            }
            defer { try? handle.close() }
            let sample = (try handle.read(upToCount: limit)) ?? Data()
            // A cut multi-byte character only costs a replacement character in
            // text this is about to scan for markers.
            return String(decoding: sample, as: UTF8.self)
        }
        // A size that cannot be read is treated as too large rather than as
        // zero, so a file the scan cannot measure is never pulled in whole.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        guard size <= maximumFileBytes else {
            throw DatabaseUserError(kind: .invalidInput,
                                    message: "the file is larger than \(maximumFileBytes / (1024 * 1024)) MB")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        if let text = String(data: data, encoding: .utf8) { return text }
        // A migration written in a legacy single-byte encoding still parses; only
        // literal text loses fidelity, and this model never evaluates literals.
        return String(decoding: data, as: UTF8.self)
    }

    private static let postgresWordHints: Set<String> = [
        "JSONB", "TIMESTAMPTZ", "BIGSERIAL", "SERIAL", "GEN_RANDOM_UUID", "UUID", "CITEXT", "TSVECTOR",
    ]

    /// Specific SQL syntax takes priority. Ambiguous type/identifier words use
    /// the selected file or folder's own name as a hint, never its ancestors.
    /// PostgreSQL remains the default for otherwise ambiguous SQL.
    public static func detectDialect(directoryURL: URL, files: [MigrationFile]) -> SQLDialect {
        var sqliteScore = 0
        var postgresScore = 0
        var sqliteSyntaxScore = 0
        var postgresSyntaxScore = 0
        for file in sample(files) {
            guard let text = try? read(file.url, limit: dialectSampleBytes) else { continue }
            let stream = SQLStatementTokens(text)
            let syntax = stream.tokens.map { token in
                token.kind == .word ? token.upper : (token.kind == .symbol ? token.text : "")
            }
            func contains(_ sequence: [String]) -> Bool {
                syntax.indices.contains { index in
                    index + sequence.count <= syntax.count &&
                        zip(syntax[index...], sequence).allSatisfy { $0.0 == $0.1 }
                }
            }
            var previous = ""
            var primaryKey = false
            var autoincrement = false
            for token in syntax {
                if ["(", ",", ";"].contains(token) { primaryKey = false }
                if previous == "PRIMARY", token == "KEY" { primaryKey = true }
                if token == "AUTOINCREMENT", primaryKey { autoincrement = true }
                previous = token
            }
            let pragma = syntax.indices.contains {
                syntax[$0] == "PRAGMA" && ($0 == 0 || syntax[$0 - 1] == ";")
            }
            if autoincrement || contains(["WITHOUT", "ROWID"]) || pragma {
                sqliteSyntaxScore += 1
            }
            let dollarQuoted = stream.tokens.contains {
                $0.kind == .string && stream.characters[$0.start] == "$"
            }
            if contains(["::"]) || dollarQuoted || contains(["CREATE", "EXTENSION"]) ||
                contains(["GENERATED", "BY", "DEFAULT", "AS", "IDENTITY"]) {
                postgresSyntaxScore += 1
            }
            let words = Set(stream.tokens.filter { $0.kind == .word }.map(\.upper))
            if words.contains(where: { $0.hasPrefix("SQLITE_") }) { sqliteScore += 1 }
            postgresScore += postgresWordHints.intersection(words).count
            if contains(["TEXT", "[", "]"]) || contains(["NOW", "(", ")"]) { postgresScore += 1 }
        }
        if sqliteSyntaxScore > 0 || postgresSyntaxScore > 0 {
            return sqliteSyntaxScore > postgresSyntaxScore ? .sqlite : .postgreSQL
        }

        // Ancestor names such as a checkout called SQLiteGraphStudio do not
        // describe the source's dialect and must not strip PostgreSQL schemas.
        let name = directoryURL.lastPathComponent.lowercased()
        if name.contains("sqlite") { return .sqlite }
        if name.contains("postgres") || name.contains("pgsql") { return .postgreSQL }
        return sqliteScore > postgresScore ? .sqlite : .postgreSQL
    }

    private static func sample(_ files: [MigrationFile]) -> [MigrationFile] {
        guard files.count > 6 else { return files }
        return Array(files.prefix(3)) + Array(files.suffix(3))
    }
}
