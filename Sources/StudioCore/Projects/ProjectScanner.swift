import Foundation

public enum ProjectCandidateKind: String, Sendable, Hashable, Codable, CaseIterable {
    case migrationSet
    case sqliteDatabase
    case postgresBackup
    case postgresConnection
    case schemaScript

    var rank: Int {
        switch self {
        case .migrationSet: return 0
        case .sqliteDatabase: return 1
        case .postgresBackup: return 2
        case .postgresConnection: return 3
        case .schemaScript: return 4
        }
    }

    public var displayName: String {
        switch self {
        case .migrationSet: return "Migrations"
        case .sqliteDatabase: return "SQLite database"
        case .postgresBackup: return "PostgreSQL backup"
        case .postgresConnection: return "PostgreSQL connection"
        case .schemaScript: return "Schema script"
        }
    }

    public var systemImage: String {
        switch self {
        case .migrationSet: return "square.stack.3d.up"
        case .sqliteDatabase: return "cylinder.split.1x2"
        case .postgresBackup: return "archivebox"
        case .postgresConnection: return "network"
        case .schemaScript: return "doc.text"
        }
    }
}

/// Something in a chosen project folder that Graph Studio can open.
public struct ProjectCandidate: Identifiable, Sendable, Hashable {
    public let id: String
    public let kind: ProjectCandidateKind
    public let url: URL
    public let title: String
    /// Location shown to the user, relative to the folder they chose.
    public let relativePath: String
    public let detail: String
    public let migrationSet: MigrationSet?

    public init(kind: ProjectCandidateKind, url: URL, title: String, relativePath: String,
                detail: String, migrationSet: MigrationSet? = nil) {
        self.id = "\(kind.rawValue):\(url.standardizedFileURL.path)"
        self.kind = kind
        self.url = url.standardizedFileURL
        self.title = title
        self.relativePath = relativePath
        self.detail = detail
        self.migrationSet = migrationSet
    }
}

public struct ProjectScanProgress: Sendable, Hashable {
    public var directoriesVisited: Int
    public var filesInspected: Int
    public var candidatesFound: Int
    public var currentRelativePath: String

    public init(directoriesVisited: Int = 0, filesInspected: Int = 0,
                candidatesFound: Int = 0, currentRelativePath: String = "") {
        self.directoriesVisited = directoriesVisited
        self.filesInspected = filesInspected
        self.candidatesFound = candidatesFound
        self.currentRelativePath = currentRelativePath
    }
}

public struct ProjectScanLimits: Sendable, Hashable {
    public var maximumDepth: Int
    public var maximumEntries: Int
    public var honorsGitIgnore: Bool

    public init(maximumDepth: Int = 14, maximumEntries: Int = 400_000, honorsGitIgnore: Bool = true) {
        self.maximumDepth = maximumDepth
        self.maximumEntries = maximumEntries
        self.honorsGitIgnore = honorsGitIgnore
    }

    public static let `default` = ProjectScanLimits()
}

public struct ProjectScanResult: Sendable {
    public let root: URL
    public let candidates: [ProjectCandidate]
    public let directoriesVisited: Int
    public let filesInspected: Int
    public let skippedDirectoryCount: Int
    public let reachedLimit: Bool

    /// Distinct database engines represented by every candidate, including
    /// schema scripts and migration sets rather than just live connections.
    public var sourceEngines: [SQLDialect] {
        Set(candidates.compactMap { candidate -> SQLDialect? in
            switch candidate.kind {
            case .migrationSet, .schemaScript: candidate.migrationSet?.dialect
            case .sqliteDatabase: .sqlite
            case .postgresBackup, .postgresConnection: .postgreSQL
            }
        }).sorted { $0.rawValue < $1.rawValue }
    }

    public var requiresEngineChoice: Bool { sourceEngines.count > 1 }

    public init(root: URL, candidates: [ProjectCandidate], directoriesVisited: Int,
                filesInspected: Int, skippedDirectoryCount: Int, reachedLimit: Bool) {
        self.root = root
        self.candidates = candidates
        self.directoriesVisited = directoriesVisited
        self.filesInspected = filesInspected
        self.skippedDirectoryCount = skippedDirectoryCount
        self.reachedLimit = reachedLimit
    }
}

/// Walks a chosen project folder and reports everything Graph Studio can open.
/// Dependency trees, build output and anything the project's own `.gitignore`
/// excludes are skipped rather than searched.
public enum ProjectScanner {
    private static let schemaScriptNames: Set<String> = ["schema.sql", "structure.sql"]

    public static func scan(
        root: URL,
        limits: ProjectScanLimits = .default,
        progress: @Sendable (ProjectScanProgress) -> Void = { _ in }
    ) throws -> ProjectScanResult {
        let rootURL = root.standardizedFileURL
        let rootPath = rootURL.path
        let fileManager = FileManager.default

        var candidates: [ProjectCandidate] = []
        // Ignore files travel with the branch they belong to. Accumulating them
        // globally would keep consulting finished sibling subtrees, which on a
        // monorepo with a .gitignore per package costs more than the walk.
        var stack: [(url: URL, depth: Int, ignores: [GitIgnoreFile])] = [(rootURL, 0, [])]
        var directoriesVisited = 0
        var filesInspected = 0
        var skippedDirectoryCount = 0
        var reachedLimit = false

        func relativePath(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            guard path.count > rootPath.count + 1, path.hasPrefix(rootPath + "/") else {
                return url.lastPathComponent
            }
            return String(path.dropFirst(rootPath.count + 1))
        }

        // `ignores` is ordered outermost-first, so the deepest .gitignore with
        // an opinion is found by walking it backwards.
        func isIgnored(_ url: URL, isDirectory: Bool, ignores: [GitIgnoreFile]) -> Bool {
            guard limits.honorsGitIgnore, !ignores.isEmpty else { return false }
            let path = url.standardizedFileURL.path
            for file in ignores.reversed() {
                if let decision = file.decision(forPath: path, isDirectory: isDirectory) { return decision }
            }
            return false
        }

        func report(_ current: String) {
            progress(ProjectScanProgress(
                directoriesVisited: directoriesVisited,
                filesInspected: filesInspected,
                candidatesFound: candidates.count,
                currentRelativePath: current
            ))
        }

        while let frame = stack.popLast() {
            try Task.checkCancellation()
            guard directoriesVisited + filesInspected < limits.maximumEntries else {
                reachedLimit = true
                break
            }
            directoriesVisited += 1
            report(relativePath(frame.url))

            let contents: [URL]
            do {
                contents = try fileManager.contentsOfDirectory(
                    at: frame.url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey],
                    options: []
                )
            } catch {
                continue
            }

            var ignores = frame.ignores
            if limits.honorsGitIgnore, let ignoreFile = GitIgnoreFile.load(in: frame.url) {
                ignores.append(ignoreFile)
            }

            var sqlFiles: [URL] = []

            for entry in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                // Never follow links: they can leave the chosen folder or form cycles.
                if values?.isSymbolicLink == true { continue }
                let name = entry.lastPathComponent

                if values?.isDirectory == true {
                    if ProjectIgnoreRules.isSkippedDirectoryName(name) || name.hasPrefix(".")
                        || ProjectIgnoreRules.isVirtualEnvironment(entry)
                        || isIgnored(entry, isDirectory: true, ignores: ignores) {
                        skippedDirectoryCount += 1
                        continue
                    }
                    guard frame.depth < limits.maximumDepth else {
                        skippedDirectoryCount += 1
                        continue
                    }
                    stack.append((entry, frame.depth + 1, ignores))
                    continue
                }

                filesInspected += 1
                if isIgnored(entry, isDirectory: false, ignores: ignores) { continue }

                let lowercasedName = name.lowercased()
                if lowercasedName.hasSuffix(".sql") {
                    sqlFiles.append(entry)
                    if ProjectScanner.schemaScriptNames.contains(lowercasedName) {
                        candidates.append(
                            ProjectCandidate(
                                kind: .schemaScript,
                                url: entry,
                                title: name,
                                relativePath: relativePath(entry),
                                detail: byteDetail(values?.fileSize),
                                migrationSet: MigrationSet(
                                    directoryURL: frame.url,
                                    files: [MigrationFile(url: entry, version: "schema", sortKey: "schema", fileName: name)],
                                    dialect: MigrationSchemaReplay.detectDialect(
                                        directoryURL: entry,
                                        files: [MigrationFile(url: entry, version: "schema", sortKey: "schema", fileName: name)]
                                    )
                                )
                            )
                        )
                    }
                    continue
                }

                guard let candidate = fileCandidate(at: entry, name: name, size: values?.fileSize,
                                                    relativePath: relativePath(entry)) else { continue }
                candidates.append(candidate)
            }

            if let set = migrationSet(in: frame.url, sqlFiles: sqlFiles) {
                candidates.append(
                    ProjectCandidate(
                        kind: .migrationSet,
                        url: frame.url,
                        title: frame.url.lastPathComponent,
                        relativePath: relativePath(frame.url),
                        detail: migrationDetail(set),
                        migrationSet: set
                    )
                )
            }
        }

        report("")
        return ProjectScanResult(
            root: rootURL,
            candidates: sorted(candidates),
            directoriesVisited: directoriesVisited,
            filesInspected: filesInspected,
            skippedDirectoryCount: skippedDirectoryCount,
            reachedLimit: reachedLimit
        )
    }

    // MARK: - Candidate construction

    private static func fileCandidate(at url: URL, name: String, size: Int?, relativePath: String) -> ProjectCandidate? {
        let fileExtension = url.pathExtension.lowercased()
        if DatabaseDocument.sqliteExtensions.contains(fileExtension) {
            guard looksLikeSQLiteDatabase(url, size: size) else { return nil }
            return ProjectCandidate(kind: .sqliteDatabase, url: url, title: name,
                                    relativePath: relativePath, detail: byteDetail(size))
        }
        if DatabaseDocument.archiveExtensions.contains(fileExtension) {
            guard looksLikePostgresArchive(url) else { return nil }
            return ProjectCandidate(kind: .postgresBackup, url: url, title: name,
                                    relativePath: relativePath, detail: byteDetail(size))
        }
        if PostgresConnectionDocument.supportedFileExtensions.contains(fileExtension) {
            guard let document = connectionDocument(at: url, size: size) else { return nil }
            return ProjectCandidate(
                kind: .postgresConnection, url: url, title: document.name ?? name, relativePath: relativePath,
                detail: "\(document.host):\(document.port)/\(document.database)"
            )
        }
        return nil
    }

    /// A directory is a migration set when it holds versioned SQL files,
    /// whatever the directory itself is called. Discovery asks for at least two
    /// so a lone numbered script is not mistaken for a set; a folder the user
    /// chose explicitly opens with one.
    static func migrationSet(in directory: URL, sqlFiles: [URL], minimumFiles: Int = 2) -> MigrationSet? {
        var files: [MigrationFile] = []
        for url in sqlFiles {
            let name = url.lastPathComponent
            guard let parsed = migrationVersion(fileName: name) else { continue }
            files.append(MigrationFile(url: url, version: parsed.version, sortKey: parsed.sortKey, fileName: name))
        }
        guard files.count >= max(1, minimumFiles) else { return nil }
        files.sort {
            $0.sortKey == $1.sortKey
                ? $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
                : $0.sortKey < $1.sortKey
        }
        return MigrationSet(
            directoryURL: directory,
            files: files,
            dialect: MigrationSchemaReplay.detectDialect(directoryURL: directory, files: files)
        )
    }

    /// Recognises `0001_name.sql`, `001-name.sql`, `20240115093000_name.sql`,
    /// `V1_2__name.sql` and golang-migrate's `000001_name.up.sql`. Down/rollback
    /// files are excluded so a set only ever moves forward.
    static func migrationVersion(fileName: String) -> (version: String, sortKey: String)? {
        let lowercased = fileName.lowercased()
        guard lowercased.hasSuffix(".sql") else { return nil }
        var stem = String(fileName.dropLast(4))
        let lowercasedStem = stem.lowercased()
        for suffix in [".down", "_down", "-down", ".rollback", "_rollback", ".undo"]
        where lowercasedStem.hasSuffix(suffix) {
            return nil
        }
        if lowercasedStem.hasSuffix(".up") { stem = String(stem.dropLast(3)) }

        if let match = stem.range(of: #"^[Vv](\d+(?:[._]\d+)*)__"#, options: .regularExpression) {
            let version = stem[match].dropFirst().dropLast(2).replacingOccurrences(of: "_", with: ".")
            return (String(version), naturalSortKey(String(version)))
        }
        if let match = stem.range(of: #"^\d+"#, options: .regularExpression) {
            let version = String(stem[match])
            let rest = stem[match.upperBound...]
            guard rest.isEmpty || rest.first == "_" || rest.first == "-" || rest.first == "." else { return nil }
            return (version, naturalSortKey(version))
        }
        return nil
    }

    /// Zero-pads every digit run so `2` sorts before `10`.
    static func naturalSortKey(_ value: String) -> String {
        var result = ""
        var digits = ""
        for character in value {
            if character.isNumber {
                digits.append(character)
            } else {
                if !digits.isEmpty { result += String(repeating: "0", count: max(0, 20 - digits.count)) + digits }
                digits = ""
                result.append(character)
            }
        }
        if !digits.isEmpty { result += String(repeating: "0", count: max(0, 20 - digits.count)) + digits }
        return result
    }

    // MARK: - File shape checks

    static func looksLikeSQLiteDatabase(_ url: URL, size: Int?) -> Bool {
        // A freshly created, never-written database is a legitimate empty file.
        if let size, size == 0 { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 16) else { return false }
        return header == Data("SQLite format 3\u{0}".utf8)
    }

    static func looksLikePostgresArchive(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 5) else { return false }
        return header == Data("PGDMP".utf8)
    }

    static func connectionDocument(at url: URL, size: Int?) -> PostgresConnectionDocument? {
        // An unreadable size counts as too large; a connection document is a
        // few hundred bytes of JSON.
        guard (size ?? Int.max) <= 1_048_576, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PostgresConnectionDocument.self, from: data)
    }

    // MARK: - Presentation

    private static func byteDetail(_ size: Int?) -> String {
        guard let size else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    static func migrationDetail(_ set: MigrationSet) -> String {
        var parts = ["\(set.files.count) migration\(set.files.count == 1 ? "" : "s")", set.dialect.displayName]
        if let first = set.files.first, let last = set.files.last, first.version != last.version {
            parts.append("\(first.version) → \(last.version)")
        }
        return parts.joined(separator: " · ")
    }

    /// Resolves a previously chosen migration target: a directory of ordered SQL
    /// files, or a single schema script.
    public static func migrationSet(at url: URL) throws -> MigrationSet {
        let resolved = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
            throw DatabaseUserError(kind: .notFound, message: "‘\(resolved.lastPathComponent)’ is no longer there.")
        }
        guard isDirectory.boolValue else {
            let file = MigrationFile(url: resolved, version: "schema", sortKey: "schema",
                                     fileName: resolved.lastPathComponent)
            return MigrationSet(
                directoryURL: resolved.deletingLastPathComponent(),
                files: [file],
                dialect: MigrationSchemaReplay.detectDialect(directoryURL: resolved, files: [file])
            )
        }
        let sqlFiles = ((try? FileManager.default.contentsOfDirectory(
            at: resolved, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "sql" }
        guard let set = migrationSet(in: resolved, sqlFiles: sqlFiles, minimumFiles: 1) else {
            throw DatabaseUserError(
                kind: .invalidInput,
                message: "‘\(resolved.lastPathComponent)’ has no versioned SQL migration files.",
                recoverySuggestion: "Migration files are named with a leading version, such as 0001_initial.sql or V1__initial.sql."
            )
        }
        return set
    }

    private static func sorted(_ candidates: [ProjectCandidate]) -> [ProjectCandidate] {
        candidates.sorted { lhs, rhs in
            if lhs.kind.rank != rhs.kind.rank { return lhs.kind.rank < rhs.kind.rank }
            let lhsCount = lhs.migrationSet?.files.count ?? 0
            let rhsCount = rhs.migrationSet?.files.count ?? 0
            if lhs.kind == .migrationSet, lhsCount != rhsCount { return lhsCount > rhsCount }
            let lhsDepth = lhs.relativePath.filter { $0 == "/" }.count
            let rhsDepth = rhs.relativePath.filter { $0 == "/" }.count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }
}
