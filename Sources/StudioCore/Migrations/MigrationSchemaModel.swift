import Foundation

/// One migration file in an ordered set.
public struct MigrationFile: Identifiable, Sendable, Hashable, Codable {
    public let url: URL
    /// The leading version token, e.g. `0001` or `20240115093000` or `1.2`.
    public let version: String
    /// Sort key derived from `version`; numeric runs compare by value, not text.
    public let sortKey: String
    public let fileName: String

    public var id: String { url.standardizedFileURL.path }

    public init(url: URL, version: String, sortKey: String, fileName: String) {
        self.url = url.standardizedFileURL
        self.version = version
        self.sortKey = sortKey
        self.fileName = fileName
    }

    /// `0042_add_orders.sql` → `0042 · add orders`
    public var displayLabel: String {
        let stem = fileName.hasSuffix(".sql") ? String(fileName.dropLast(4)) : fileName
        var remainder = stem
        if remainder.hasPrefix(version) { remainder = String(remainder.dropFirst(version.count)) }
        remainder = remainder.trimmingCharacters(in: CharacterSet(charactersIn: "_-. "))
        remainder = remainder.replacingOccurrences(of: "_", with: " ")
        if remainder.hasSuffix(".up") { remainder = String(remainder.dropLast(3)) }
        return remainder.isEmpty ? version : "\(version) · \(remainder)"
    }
}

/// A directory of ordered migration files that Graph Studio can replay.
public struct MigrationSet: Sendable, Hashable, Codable {
    public let directoryURL: URL
    public let files: [MigrationFile]
    public let dialect: SQLDialect

    public init(directoryURL: URL, files: [MigrationFile], dialect: SQLDialect) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.files = files
        self.dialect = dialect
    }

    public var latest: MigrationFile? { files.last }

    public func index(ofVersion version: String) -> Int? {
        files.firstIndex { $0.version == version }
    }

    /// Every file up to and including `version`; the whole set when it is unknown.
    public func files(through version: String?) -> [MigrationFile] {
        guard let version, let index = index(ofVersion: version) else { return files }
        return Array(files[...index])
    }
}

/// A statement the replayer could not interpret. Surfaced in the existing
/// metadata diagnostics panel so an incomplete model is never silently wrong.
public struct MigrationDiagnostic: Identifiable, Sendable, Hashable {
    public let id: String
    public let fileName: String
    public let message: String
    public let statementPreview: String

    public init(fileName: String, message: String, statementPreview: String) {
        self.id = "\(fileName)|\(message)|\(statementPreview)"
        self.fileName = fileName
        self.message = message
        self.statementPreview = statementPreview
    }

    public var displayText: String {
        statementPreview.isEmpty ? "\(fileName): \(message)" : "\(fileName): \(message) — \(statementPreview)"
    }
}

/// The result of replaying a migration set's DDL.
public struct MigrationSchemaModel: Sendable {
    public let catalog: CatalogSnapshot
    public let diagnostics: [MigrationDiagnostic]
    public let fileCount: Int
    public let statementCount: Int
    public let dialect: SQLDialect

    public init(
        catalog: CatalogSnapshot,
        diagnostics: [MigrationDiagnostic],
        fileCount: Int,
        statementCount: Int,
        dialect: SQLDialect
    ) {
        self.catalog = catalog
        self.diagnostics = diagnostics
        self.fileCount = fileCount
        self.statementCount = statementCount
        self.dialect = dialect
    }
}

// MARK: - Intermediate model

struct MigrationColumn: Sendable, Hashable {
    var name: String
    var type: String
    var notNull = false
    var defaultSQL: String?
    var identityKind = ""
    /// "", "stored" or "virtual".
    var generatedKind = ""
    var comment: String?
}

struct MigrationKeyConstraint: Sendable, Hashable {
    var name: String
    var columns: [String]
}

struct MigrationCheckConstraint: Sendable, Hashable {
    var name: String
    var columns: [String]
    var detail: String
}

struct MigrationForeignKeyConstraint: Sendable, Hashable {
    var name: String
    var columns: [String]
    var targetKey: String
    var targetColumns: [String]
    var actions: String
}

struct MigrationTable: Sendable, Hashable {
    var schema: String?
    var objectName: String
    var objectType: SQLiteObjectType
    var columns: [MigrationColumn] = []
    var primaryKey: MigrationKeyConstraint?
    var uniques: [MigrationKeyConstraint] = []
    var checks: [MigrationCheckConstraint] = []
    var foreignKeys: [MigrationForeignKeyConstraint] = []
    var comment: String?
    var isWithoutRowID = false
    var partitionParentKey: String?

    var qualifiedName: String {
        guard let schema else { return objectName }
        return "\(schema).\(objectName)"
    }

    func columnIndex(named name: String) -> Int? {
        columns.firstIndex { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }
}

struct MigrationIndex: Sendable, Hashable {
    var name: String
    var tableKey: String
    var columns: [String]
    var isUnique: Bool
    var isPartial: Bool
    var sql: String
}

struct MigrationTrigger: Sendable, Hashable {
    var name: String
    var tableKey: String
    var sql: String
}
