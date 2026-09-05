import CryptoKit
import Foundation

/// Structured identity: dots and quoting in schema/object names are never parsed.
public struct RecordTableID: Codable, Sendable, Hashable, Identifiable {
    public let schemaName: String?
    public let objectName: String
    public init(schemaName: String?, objectName: String) {
        self.schemaName = schemaName
        self.objectName = objectName
    }
    public init(descriptor: TableDescriptor) {
        self.init(schemaName: descriptor.schemaName, objectName: descriptor.objectName)
    }
    public var id: String { recordToken([schemaName.map { "schema:" + $0 } ?? "default", objectName]) }
    public var displayName: String { schemaName.map { $0 + "." + objectName } ?? objectName }
    public var qualifiedSQLIdentifier: String {
        schemaName.map { qualifiedIdentifier(schema: $0, object: objectName) } ?? quoteIdentifier(objectName)
    }
}

public struct RecordIdentity: Sendable, Hashable, Identifiable {
    public let table: RecordTableID
    public let locator: [IdentityComponent]
    public init(table: RecordTableID, locator: [IdentityComponent]) {
        self.table = table
        self.locator = locator
    }
    public var id: String {
        recordToken([table.id] + locator.flatMap { [$0.columnName, recordValueToken($0.value)] })
    }
}

public struct RecordSnapshot: Identifiable, Hashable, Sendable {
    public let id: String
    public let descriptor: TableDescriptor?
    public let columns: [QueryResultColumn]
    public let values: [SQLiteValue]
    public let identity: RecordIdentity?
    public let label: String
    public init(descriptor: TableDescriptor?, columns: [QueryResultColumn], values: [SQLiteValue], identity: RecordIdentity?, label: String) {
        self.id = identity?.id ?? "snapshot:" + UUID().uuidString
        self.descriptor = descriptor
        self.columns = columns
        self.values = values
        self.identity = identity
        self.label = label
    }
    public var table: RecordTableID? { descriptor.map(RecordTableID.init(descriptor:)) }
    /// Duplicate column labels are ambiguous, not silently resolved to the first.
    public func value(for column: String) -> SQLiteValue? {
        let matches = columns.indices.filter { columns[$0].name == column }
        guard matches.count == 1, let index = matches.first, values.indices.contains(index) else { return nil }
        return values[index]
    }
}

public enum RecordDirection: String, Sendable, Hashable, Codable { case outgoing, incoming }

public struct RecordRelationship: Identifiable, Hashable, Sendable {
    public let id: String
    public let sourceTable: RecordTableID
    public let targetTable: RecordTableID
    public let sourceColumns: [String]
    public let targetColumns: [String]
    public let sourceDescriptor: TableDescriptor?
    public let targetDescriptor: TableDescriptor?
    public init(id: String, sourceTable: RecordTableID, targetTable: RecordTableID, sourceColumns: [String], targetColumns: [String], sourceDescriptor: TableDescriptor?, targetDescriptor: TableDescriptor?) {
        self.id = id
        self.sourceTable = sourceTable
        self.targetTable = targetTable
        self.sourceColumns = sourceColumns
        self.targetColumns = targetColumns
        self.sourceDescriptor = sourceDescriptor
        self.targetDescriptor = targetDescriptor
    }
}

public enum RecordPageStatus: String, Sendable, Hashable {
    case loaded, nullReference, missingReference, unavailable
}

public struct RecordPage: Sendable, Hashable {
    public let records: [RecordSnapshot]
    public let hasMore: Bool
    public let nextOffset: Int?
    public let status: RecordPageStatus
    public init(records: [RecordSnapshot], hasMore: Bool, nextOffset: Int?, status: RecordPageStatus = .loaded) {
        self.records = records
        self.hasMore = hasMore
        self.nextOffset = nextOffset
        self.status = status
    }
    public static func empty(_ status: RecordPageStatus) -> Self {
        Self(records: [], hasMore: false, nextOffset: nil, status: status)
    }
}

public enum RecordAccessError: Error, LocalizedError, Sendable, Equatable {
    case invalidSnapshot
    case missingColumns([String])
    case wrongTable
    case invalidRelationship
    case unavailableTable
    case unsupportedType(String)
    public var errorDescription: String? {
        switch self {
        case .invalidSnapshot: "The loaded row does not match its result columns."
        case .missingColumns(let columns): "The loaded row does not include unambiguous values for: \(columns.joined(separator: ", "))."
        case .wrongTable: "This relationship belongs to a different table."
        case .invalidRelationship: "The relationship does not have a complete column mapping."
        case .unavailableTable: "The related table is unavailable or cannot be read."
        case .unsupportedType(let type): "This PostgreSQL type cannot be used for record lookup: \(type)."
        }
    }
}

private func recordToken(_ parts: [String]) -> String {
    let encoded = parts.map { "\($0.utf8.count):\($0)" }.joined()
    return SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func recordValueToken(_ value: SQLiteValue) -> String {
    switch value {
    case .null: return "null"
    case .integer(let value): return "integer:\(value)"
    case .double(let value): return "double:\(value.bitPattern)"
    case .boolean(let value): return "boolean:\(value)"
    case .exactNumeric(let value): return "numeric:" + value
    case .text(let value): return "text:" + value
    case .uuid(let value): return "uuid:" + value.lowercased()
    case .dateTime(let value): return "datetime:" + value
    case .json(let value): return "json:" + value
    case .array(let value): return "array:" + value
    case .blob(let value): return "blob:" + value.base64EncodedString()
    }
}
