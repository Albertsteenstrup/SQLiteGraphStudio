@preconcurrency import GRDB
import Foundation

public enum SQLiteObjectType: String, Sendable, Hashable, CaseIterable {
    case table
    case view
    case virtual
    case shadow
    case unknown

    init(rawDatabaseType: String) {
        switch rawDatabaseType.lowercased() {
        case "table":
            self = .table
        case "view":
            self = .view
        case "virtual":
            self = .virtual
        case "shadow":
            self = .shadow
        default:
            self = .unknown
        }
    }
}

public enum ColumnAffinity: String, Sendable, Hashable, CaseIterable {
    case integer
    case real
    case text
    case blob
    case numeric
    case none

    init(declaredType: String) {
        let uppercased = declaredType.uppercased()
        if uppercased.contains("INT") {
            self = .integer
        } else if uppercased.contains("CHAR") || uppercased.contains("CLOB") || uppercased.contains("TEXT") {
            self = .text
        } else if uppercased.contains("BLOB") {
            self = .blob
        } else if uppercased.contains("REAL") || uppercased.contains("FLOA") || uppercased.contains("DOUB") {
            self = .real
        } else if uppercased.isEmpty {
            self = .none
        } else {
            self = .numeric
        }
    }
}

public enum SortDirection: String, Sendable, Hashable {
    case ascending
    case descending

    var sqlKeyword: String {
        switch self {
        case .ascending:
            return "ASC"
        case .descending:
            return "DESC"
        }
    }

    var toggled: SortDirection {
        switch self {
        case .ascending:
            return .descending
        case .descending:
            return .ascending
        }
    }
}

public enum RowIdentityStrategy: String, Sendable, Hashable {
    case primaryKey
    case rowID
    case readOnly
}

public struct TableColumn: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let declaredType: String
    public let notNull: Bool
    public let defaultValueSQL: String?
    public let primaryKeyOrdinal: Int
    public let hiddenValue: Int

    public init(
        name: String,
        declaredType: String,
        notNull: Bool,
        defaultValueSQL: String?,
        primaryKeyOrdinal: Int,
        hiddenValue: Int
    ) {
        self.id = name
        self.name = name
        self.declaredType = declaredType
        self.notNull = notNull
        self.defaultValueSQL = defaultValueSQL
        self.primaryKeyOrdinal = primaryKeyOrdinal
        self.hiddenValue = hiddenValue
    }

    public var affinity: ColumnAffinity {
        ColumnAffinity(declaredType: declaredType)
    }

    public var isGenerated: Bool {
        hiddenValue != 0
    }

    public var isEditable: Bool {
        !isGenerated && affinity != .blob
    }

    public var typeLabel: String {
        declaredType.isEmpty ? affinity.rawValue.uppercased() : declaredType.uppercased()
    }

    public var canDropInSQLite: Bool {
        !isGenerated && primaryKeyOrdinal == 0
    }
}

public struct SchemaIndex: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public let name: String
    public let columns: [String]
    public let isUnique: Bool
    public let origin: String
    public let isPartial: Bool
    public let sql: String?

    public init(name: String, columns: [String], isUnique: Bool, origin: String, isPartial: Bool, sql: String?) {
        self.id = name
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.origin = origin
        self.isPartial = isPartial
        self.sql = sql
    }
}

public struct SchemaTrigger: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public let name: String
    public let tableName: String
    public let sql: String

    public init(name: String, tableName: String, sql: String) {
        self.id = name
        self.name = name
        self.tableName = tableName
        self.sql = sql
    }
}

public enum SchemaConstraintKind: String, Sendable, Hashable, Codable {
    case primaryKey
    case foreignKey
    case unique
    case notNull
    case defaultValue
    case check
}

public struct SchemaConstraint: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public let kind: SchemaConstraintKind
    public let name: String?
    public let columns: [String]
    public let detail: String

    public init(id: String, kind: SchemaConstraintKind, name: String? = nil, columns: [String], detail: String) {
        self.id = id
        self.kind = kind
        self.name = name
        self.columns = columns
        self.detail = detail
    }
}

public struct GeneratedColumnInfo: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public let name: String
    public let declaredType: String
    public let storedKind: String

    public init(name: String, declaredType: String, storedKind: String) {
        self.id = name
        self.name = name
        self.declaredType = declaredType
        self.storedKind = storedKind
    }
}

public struct TableSummary: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let objectType: SQLiteObjectType
    public let isEditable: Bool
    public let columnCount: Int
    public let rowCount: Int?

    public init(
        name: String,
        objectType: SQLiteObjectType,
        isEditable: Bool,
        columnCount: Int,
        rowCount: Int? = nil
    ) {
        self.id = name
        self.name = name
        self.objectType = objectType
        self.isEditable = isEditable
        self.columnCount = columnCount
        self.rowCount = rowCount
    }
}

public struct EditableTableDescriptor: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let objectType: SQLiteObjectType
    public let columns: [TableColumn]
    public let primaryKeyColumns: [String]
    public let rowIdentityStrategy: RowIdentityStrategy
    public let isWithoutRowID: Bool
    public let isEditable: Bool
    public let rowCount: Int?
    public let indexes: [SchemaIndex]
    public let triggers: [SchemaTrigger]
    public let constraints: [SchemaConstraint]
    public let generatedColumns: [GeneratedColumnInfo]

    public init(
        name: String,
        objectType: SQLiteObjectType,
        columns: [TableColumn],
        primaryKeyColumns: [String],
        rowIdentityStrategy: RowIdentityStrategy,
        isWithoutRowID: Bool,
        isEditable: Bool,
        rowCount: Int? = nil,
        indexes: [SchemaIndex] = [],
        triggers: [SchemaTrigger] = [],
        constraints: [SchemaConstraint] = [],
        generatedColumns: [GeneratedColumnInfo] = []
    ) {
        self.id = name
        self.name = name
        self.objectType = objectType
        self.columns = columns
        self.primaryKeyColumns = primaryKeyColumns
        self.rowIdentityStrategy = rowIdentityStrategy
        self.isWithoutRowID = isWithoutRowID
        self.isEditable = isEditable
        self.rowCount = rowCount
        self.indexes = indexes
        self.triggers = triggers
        self.constraints = constraints
        self.generatedColumns = generatedColumns
    }

    public var summary: TableSummary {
        TableSummary(
            name: name,
            objectType: objectType,
            isEditable: isEditable,
            columnCount: columns.count,
            rowCount: rowCount
        )
    }

    public var searchableColumns: [TableColumn] {
        columns.filter { $0.affinity != .blob }
    }

    public var fallbackSortColumns: [String] {
        switch rowIdentityStrategy {
        case .primaryKey:
            return primaryKeyColumns
        case .rowID:
            return ["_rowid_"]
        case .readOnly:
            return columns.map(\.name)
        }
    }
}

public struct DatabaseConnectionProfile: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public var name: String
    public var filePath: String
    public var bookmarkData: Data?
    public var lastOpenedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        filePath: String,
        bookmarkData: Data? = nil,
        lastOpenedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.filePath = filePath
        self.bookmarkData = bookmarkData
        self.lastOpenedAt = lastOpenedAt
    }

    public var url: URL {
        URL(fileURLWithPath: filePath).standardizedFileURL
    }
}

public struct IdentityComponent: Sendable, Hashable {
    public let columnName: String
    public let value: SQLiteValue

    public init(columnName: String, value: SQLiteValue) {
        self.columnName = columnName
        self.value = value
    }
}

public enum TableRowIdentity: Sendable, Hashable {
    case primaryKey([IdentityComponent])
    case rowID(Int64)
}

public enum SQLiteValue: Sendable, Hashable {
    case null
    case integer(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public init(databaseValue: DatabaseValue) {
        switch databaseValue.storage {
        case .null:
            self = .null
        case .int64(let value):
            self = .integer(value)
        case .double(let value):
            self = .double(value)
        case .string(let value):
            self = .text(value)
        case .blob(let value):
            self = .blob(value)
        }
    }

    public var displayText: String {
        switch self {
        case .null:
            return "NULL"
        case .integer(let value):
            return String(value)
        case .double(let value):
            return value.formatted(.number.precision(.fractionLength(0...4)))
        case .text(let value):
            return value
        case .blob(let data):
            return "<\(data.count) bytes>"
        }
    }

    public var typeLabel: String {
        switch self {
        case .null:
            return "NULL"
        case .integer:
            return "INTEGER"
        case .double:
            return "REAL"
        case .text:
            return "TEXT"
        case .blob:
            return "BLOB"
        }
    }

    public var editorText: String {
        switch self {
        case .null:
            return "NULL"
        case .integer(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .text(let value):
            return value
        case .blob:
            return ""
        }
    }

    public var databaseValue: DatabaseValue {
        switch self {
        case .null:
            return .null
        case .integer(let value):
            return value.databaseValue
        case .double(let value):
            return value.databaseValue
        case .text(let value):
            return value.databaseValue
        case .blob(let value):
            return value.databaseValue
        }
    }
}

public struct QueryResultColumn: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let typeLabel: String

    public init(name: String, typeLabel: String) {
        self.id = name
        self.name = name
        self.typeLabel = typeLabel
    }
}

public struct QueryResultRow: Identifiable, Sendable, Hashable {
    public let id: Int
    public let values: [SQLiteValue]

    public init(id: Int, values: [SQLiteValue]) {
        self.id = id
        self.values = values
    }
}

public struct QueryResult: Sendable, Hashable {
    public let columns: [QueryResultColumn]
    public let rows: [QueryResultRow]
    public let isTruncated: Bool
    public let rowLimit: Int

    public init(columns: [QueryResultColumn], rows: [QueryResultRow], isTruncated: Bool, rowLimit: Int) {
        self.columns = columns
        self.rows = rows
        self.isTruncated = isTruncated
        self.rowLimit = rowLimit
    }

    public static let empty = QueryResult(columns: [], rows: [], isTruncated: false, rowLimit: 0)
}

public struct ExplainPlanRow: Identifiable, Sendable, Hashable {
    public let id: Int
    public let parent: Int
    public let notUsed: Int
    public let detail: String

    public init(id: Int, parent: Int, notUsed: Int, detail: String) {
        self.id = id
        self.parent = parent
        self.notUsed = notUsed
        self.detail = detail
    }
}

public struct QueryHistoryEntry: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public let title: String
    public let sqlText: String
    public let executedAt: Date
    public let durationMilliseconds: Double
    public let rowCount: Int
    public let succeeded: Bool
    public let message: String?

    public init(
        id: UUID = UUID(),
        title: String,
        sqlText: String,
        executedAt: Date = Date(),
        durationMilliseconds: Double,
        rowCount: Int,
        succeeded: Bool,
        message: String? = nil
    ) {
        self.id = id
        self.title = title
        self.sqlText = sqlText
        self.executedAt = executedAt
        self.durationMilliseconds = durationMilliseconds
        self.rowCount = rowCount
        self.succeeded = succeeded
        self.message = message
    }
}

public enum DataTransferFormat: String, CaseIterable, Identifiable, Sendable, Hashable {
    case csv
    case json

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .json: return "json"
        }
    }
}

public struct ImportRowsResult: Sendable, Hashable {
    public let insertedRowCount: Int
    public let skippedRowCount: Int
    public let messages: [String]

    public init(insertedRowCount: Int, skippedRowCount: Int, messages: [String] = []) {
        self.insertedRowCount = insertedRowCount
        self.skippedRowCount = skippedRowCount
        self.messages = messages
    }
}

public struct TableColumnDraft: Identifiable, Sendable, Hashable {
    public let id: UUID
    public var name: String
    public var type: String
    public var isPrimaryKey: Bool
    public var isNotNull: Bool
    public var defaultValueSQL: String

    public init(
        id: UUID = UUID(),
        name: String = "",
        type: String = "TEXT",
        isPrimaryKey: Bool = false,
        isNotNull: Bool = false,
        defaultValueSQL: String = ""
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.isPrimaryKey = isPrimaryKey
        self.isNotNull = isNotNull
        self.defaultValueSQL = defaultValueSQL
    }
}

public struct TableCreateDraft: Sendable, Hashable {
    public var tableName: String
    public var columns: [TableColumnDraft]

    public init(tableName: String = "", columns: [TableColumnDraft] = [TableColumnDraft(name: "id", type: "INTEGER", isPrimaryKey: true)]) {
        self.tableName = tableName
        self.columns = columns
    }
}

public struct TableRow: Sendable, Hashable {
    public let identity: TableRowIdentity
    public let values: [SQLiteValue]

    public init(identity: TableRowIdentity, values: [SQLiteValue]) {
        self.identity = identity
        self.values = values
    }
}

public struct TableChunk: Sendable, Hashable {
    public let rows: [TableRow]
    public let totalRowCount: Int
    public let offset: Int
    public let limit: Int

    public init(rows: [TableRow], totalRowCount: Int, offset: Int, limit: Int) {
        self.rows = rows
        self.totalRowCount = totalRowCount
        self.offset = offset
        self.limit = limit
    }

    public static func empty(limit: Int) -> TableChunk {
        TableChunk(rows: [], totalRowCount: 0, offset: 0, limit: limit)
    }

    public var rowRange: Range<Int> {
        offset..<(offset + rows.count)
    }

    public func contains(absoluteRow row: Int) -> Bool {
        rowRange.contains(row)
    }
}

public struct SortState: Sendable, Hashable {
    public let columnName: String
    public let direction: SortDirection

    public init(columnName: String, direction: SortDirection) {
        self.columnName = columnName
        self.direction = direction
    }
}

public struct ColumnFilter: Sendable, Hashable {
    public let columnName: String
    public let value: String

    public init(columnName: String, value: String) {
        self.columnName = columnName
        self.value = value
    }
}

public struct TableQueryState: Sendable, Hashable {
    public var searchText: String
    public var columnFilters: [ColumnFilter]
    public var sort: SortState?
    public var offset: Int
    public var limit: Int

    public init(
        searchText: String = "",
        columnFilters: [ColumnFilter] = [],
        sort: SortState? = nil,
        offset: Int = 0,
        limit: Int = 300
    ) {
        self.searchText = searchText
        self.columnFilters = columnFilters
        self.sort = sort
        self.offset = offset
        self.limit = limit
    }

    public var sanitizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var sanitizedFilters: [ColumnFilter] {
        columnFilters
            .map { ColumnFilter(columnName: $0.columnName, value: $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.value.isEmpty }
            .sorted { $0.columnName.localizedStandardCompare($1.columnName) == .orderedAscending }
    }
}

public struct CellEditChange: Sendable, Hashable {
    public let descriptor: EditableTableDescriptor
    public let rowIdentity: TableRowIdentity
    public let columnName: String
    public let rawValue: String

    public init(
        descriptor: EditableTableDescriptor,
        rowIdentity: TableRowIdentity,
        columnName: String,
        rawValue: String
    ) {
        self.descriptor = descriptor
        self.rowIdentity = rowIdentity
        self.columnName = columnName
        self.rawValue = rawValue
    }
}

public struct SQLiteUserError: Error, Sendable, Hashable, Identifiable, LocalizedError {
    public enum Kind: String, Sendable, Hashable {
        case busy
        case constraint
        case readOnly
        case invalidInput
        case notFound
        case generic
    }

    public let kind: Kind
    public let message: String
    public let recoverySuggestion: String?

    public init(kind: Kind, message: String, recoverySuggestion: String? = nil) {
        self.kind = kind
        self.message = message
        self.recoverySuggestion = recoverySuggestion
    }

    public var id: String {
        "\(kind.rawValue):\(message)"
    }

    public var errorDescription: String? {
        message
    }

    public static func from(_ error: any Error) -> SQLiteUserError {
        if let userError = error as? SQLiteUserError {
            return userError
        }

        if let dbError = error as? DatabaseError {
            let message = dbError.message ?? dbError.resultCode.description
            switch dbError.resultCode {
            case .SQLITE_BUSY:
                return SQLiteUserError(
                    kind: .busy,
                    message: message,
                    recoverySuggestion: "The database is busy. Retry the change after pending work finishes."
                )
            case .SQLITE_CONSTRAINT:
                return SQLiteUserError(kind: .constraint, message: message)
            case .SQLITE_READONLY:
                return SQLiteUserError(kind: .readOnly, message: message)
            default:
                return SQLiteUserError(kind: .generic, message: message)
            }
        }

        return SQLiteUserError(kind: .generic, message: error.localizedDescription)
    }
}

func quoteIdentifier(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
}

func quoteStringLiteral(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "''"))'"
}

func parseSQLiteValue(_ rawValue: String, for column: TableColumn) throws -> SQLiteValue {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.uppercased() == "NULL" {
        if column.notNull {
            throw SQLiteUserError(kind: .invalidInput, message: "\(column.name) does not allow NULL values.")
        }
        return .null
    }

    switch column.affinity {
    case .integer:
        if let intValue = Int64(trimmed) {
            return .integer(intValue)
        }
        return .text(rawValue)
    case .real:
        if let doubleValue = Double(trimmed) {
            return .double(doubleValue)
        }
        return .text(rawValue)
    case .blob:
        throw SQLiteUserError(kind: .invalidInput, message: "Inline blob editing is not supported for \(column.name).")
    case .numeric:
        if let intValue = Int64(trimmed) {
            return .integer(intValue)
        }
        if let doubleValue = Double(trimmed) {
            return .double(doubleValue)
        }
        return .text(rawValue)
    case .text, .none:
        return .text(rawValue)
    }
}
