import Foundation

/// Equality-filter literals are typed and are always sent as bound parameters.
public enum RecordMappingValue: Codable, Sendable, Hashable {
    case null
    case integer(Int64)
    case double(Double)
    case boolean(Bool)
    case text(String)
    case exactNumeric(String)
    case uuid(String)
    case dateTime(String)
    case json(String)
    case array(String)
    case blob(Data)

    private enum CodingKeys: String, CodingKey { case type, value }
    private enum Kind: String, Codable { case null, integer, double, boolean, text, exactNumeric, uuid, dateTime, json, array, blob }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .null: self = .null
        case .integer: self = .integer(try container.decode(Int64.self, forKey: .value))
        case .double: self = .double(try container.decode(Double.self, forKey: .value))
        case .boolean: self = .boolean(try container.decode(Bool.self, forKey: .value))
        case .text: self = .text(try container.decode(String.self, forKey: .value))
        case .exactNumeric: self = .exactNumeric(try container.decode(String.self, forKey: .value))
        case .uuid: self = .uuid(try container.decode(String.self, forKey: .value))
        case .dateTime: self = .dateTime(try container.decode(String.self, forKey: .value))
        case .json: self = .json(try container.decode(String.self, forKey: .value))
        case .array: self = .array(try container.decode(String.self, forKey: .value))
        case .blob: self = .blob(try container.decode(Data.self, forKey: .value))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let kind: Kind
        switch self {
        case .null: kind = .null
        case .integer(let value): kind = .integer; try container.encode(value, forKey: .value)
        case .double(let value): kind = .double; try container.encode(value, forKey: .value)
        case .boolean(let value): kind = .boolean; try container.encode(value, forKey: .value)
        case .text(let value): kind = .text; try container.encode(value, forKey: .value)
        case .exactNumeric(let value): kind = .exactNumeric; try container.encode(value, forKey: .value)
        case .uuid(let value): kind = .uuid; try container.encode(value, forKey: .value)
        case .dateTime(let value): kind = .dateTime; try container.encode(value, forKey: .value)
        case .json(let value): kind = .json; try container.encode(value, forKey: .value)
        case .array(let value): kind = .array; try container.encode(value, forKey: .value)
        case .blob(let value): kind = .blob; try container.encode(value, forKey: .value)
        }
        try container.encode(kind, forKey: .type)
    }
    public var sqliteValue: SQLiteValue {
        switch self {
        case .null: .null
        case .integer(let value): .integer(value)
        case .double(let value): .double(value)
        case .boolean(let value): .boolean(value)
        case .text(let value): .text(value)
        case .exactNumeric(let value): .exactNumeric(value)
        case .uuid(let value): .uuid(value)
        case .dateTime(let value): .dateTime(value)
        case .json(let value): .json(value)
        case .array(let value): .array(value)
        case .blob(let value): .blob(value)
        }
    }
}

public struct RecordMappingFilter: Codable, Sendable, Hashable {
    public var column: String
    public var value: RecordMappingValue
    public init(column: String, value: RecordMappingValue) { self.column = column; self.value = value }
    var predicate: IdentityComponent { .init(columnName: column, value: value.sqliteValue) }
}

public struct RecordGraphMapping: Codable, Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var nodeTable: RecordTableID
    public var nodeIDColumns: [String]
    public var labelColumn: String?
    public var edgeTable: RecordTableID
    public var sourceColumns: [String]
    public var targetColumns: [String]
    public var typeColumn: String?
    public var isDirected: Bool
    public var nodeScope: [RecordMappingFilter]
    public var edgeScope: [RecordMappingFilter]
    public init(id: String, name: String, nodeTable: RecordTableID, nodeIDColumns: [String], labelColumn: String? = nil, edgeTable: RecordTableID, sourceColumns: [String], targetColumns: [String], typeColumn: String? = nil, isDirected: Bool = true, nodeScope: [RecordMappingFilter] = [], edgeScope: [RecordMappingFilter] = []) {
        self.id = id; self.name = name; self.nodeTable = nodeTable; self.nodeIDColumns = nodeIDColumns
        self.labelColumn = labelColumn; self.edgeTable = edgeTable; self.sourceColumns = sourceColumns
        self.targetColumns = targetColumns; self.typeColumn = typeColumn; self.isDirected = isDirected
        self.nodeScope = nodeScope; self.edgeScope = edgeScope
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, nodeTable, nodeIDColumns, labelColumn, edgeTable, sourceColumns, targetColumns, typeColumn, isDirected, nodeScope, edgeScope
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        nodeTable = try container.decode(RecordTableID.self, forKey: .nodeTable)
        nodeIDColumns = try container.decode([String].self, forKey: .nodeIDColumns)
        labelColumn = try container.decodeIfPresent(String.self, forKey: .labelColumn)
        edgeTable = try container.decode(RecordTableID.self, forKey: .edgeTable)
        sourceColumns = try container.decode([String].self, forKey: .sourceColumns)
        targetColumns = try container.decode([String].self, forKey: .targetColumns)
        typeColumn = try container.decodeIfPresent(String.self, forKey: .typeColumn)
        isDirected = try container.decodeIfPresent(Bool.self, forKey: .isDirected) ?? true
        nodeScope = try container.decodeIfPresent([RecordMappingFilter].self, forKey: .nodeScope) ?? []
        edgeScope = try container.decodeIfPresent([RecordMappingFilter].self, forKey: .edgeScope) ?? []
    }
}

public struct ValidatedRecordGraphMapping: Sendable {
    public let mapping: RecordGraphMapping
    public let nodeDescriptor: TableDescriptor
    public let edgeDescriptor: TableDescriptor
}

public struct RecordMappedConnection: Identifiable, Sendable, Hashable {
    public var id: String { edge.id }
    public let edge: RecordSnapshot
    public let source: RecordSnapshot
    public let target: RecordSnapshot
    public let label: String?
    public let isDirected: Bool
    public let edgeOffset: Int
    public init(edge: RecordSnapshot, source: RecordSnapshot, target: RecordSnapshot, label: String? = nil, isDirected: Bool, edgeOffset: Int = 0) {
        self.edge = edge; self.source = source; self.target = target; self.label = label
        self.isDirected = isDirected; self.edgeOffset = edgeOffset
    }
}

public struct RecordMappedPage: Sendable, Hashable {
    public let connections: [RecordMappedConnection]
    public let hasMore: Bool
    public let nextOffset: Int?
    public let messages: [String]
    public let queryCount: Int
    public init(connections: [RecordMappedConnection], hasMore: Bool, nextOffset: Int?, messages: [String] = [], queryCount: Int) {
        self.connections = connections; self.hasMore = hasMore; self.nextOffset = nextOffset
        self.messages = messages; self.queryCount = queryCount
    }
}

public enum RecordGraphMappingError: Error, LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

public enum RecordGraphMappingAccess {
    public static let pageSize = 5
    public static let maximumQueriesPerPage = 7

    public static func validate(mapping: RecordGraphMapping, catalog: CatalogSnapshot) throws -> ValidatedRecordGraphMapping {
        func reject(_ message: String) -> RecordGraphMappingError { .invalid(message) }
        guard !mapping.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw reject("A graph mapping needs an ID.") }
        let nodes = catalog.descriptors.filter { RecordTableID(descriptor: $0) == mapping.nodeTable }
        let edges = catalog.descriptors.filter { RecordTableID(descriptor: $0) == mapping.edgeTable }
        guard nodes.count == 1, let node = nodes.first else { throw reject("The mapping's node table is unavailable or ambiguous.") }
        guard edges.count == 1, let edge = edges.first else { throw reject("The mapping's edge table is unavailable or ambiguous.") }
        let count = mapping.nodeIDColumns.count
        guard (1...16).contains(count), mapping.sourceColumns.count == count, mapping.targetColumns.count == count else { throw reject("Node, source and target identifier tuples must have the same number of columns (1–16).") }
        func requireColumns(_ names: [String], in descriptor: TableDescriptor) throws {
            let available = Set(descriptor.columns.map(\.name))
            guard Set(names).count == names.count, names.allSatisfy({ !$0.isEmpty && available.contains($0) }) else { throw reject("The mapping includes missing or repeated columns in \(descriptor.name).") }
        }
        try requireColumns(mapping.nodeIDColumns, in: node)
        try requireColumns(mapping.sourceColumns, in: edge)
        try requireColumns(mapping.targetColumns, in: edge)
        if let column = mapping.labelColumn { try requireColumns([column], in: node) }
        if let column = mapping.typeColumn { try requireColumns([column], in: edge) }
        guard RecordAccess.uniqueKeys(node).contains(where: { Set($0) == Set(mapping.nodeIDColumns) && $0.count == count }) else { throw reject("The node identifier must be a complete primary key or nonpartial unique key.") }
        guard !RecordAccess.uniqueKeys(edge).isEmpty || RecordAccess.sqliteRowIDColumn(edge) != nil else { throw reject("The edge table needs a unique key or an unshadowed SQLite rowid.") }
        for (filters, descriptor) in [(mapping.nodeScope, node), (mapping.edgeScope, edge)] {
            guard filters.count <= 16 else { throw reject("A mapping scope may contain at most 16 equality filters.") }
            try requireColumns(filters.map(\.column), in: descriptor)
            guard filters.allSatisfy({ if case .double(let value) = $0.value { return value.isFinite }; return true }) else { throw reject("Mapping filters must contain finite numbers.") }
        }
        return ValidatedRecordGraphMapping(mapping: mapping, nodeDescriptor: node, edgeDescriptor: edge)
    }

    public static func load(mapping: RecordGraphMapping, root: RecordSnapshot, direction: RecordDirection, offset: Int = 0, catalog: CatalogSnapshot, database: DatabaseService) async throws -> RecordMappedPage {
        let validated = try validate(mapping: mapping, catalog: catalog)
        guard root.table == mapping.nodeTable else { throw RecordGraphMappingError.invalid("Choose a record from the mapping's node table.") }
        func tuple(_ record: RecordSnapshot, _ names: [String]) -> [IdentityComponent]? {
            let values = names.compactMap { name -> IdentityComponent? in
                guard let value = record.value(for: name), value != .null else { return nil }
                return .init(columnName: name, value: value)
            }
            return values.count == names.count ? values : nil
        }
        guard let rootKey = tuple(root, mapping.nodeIDColumns) else { throw RecordGraphMappingError.invalid("The selected row is missing a complete, non-NULL node identifier.") }
        let scope = mapping.nodeScope.map(\.predicate)
        var queryCount = 1
        let anchorPage = try await database.fetchRecords(descriptor: validated.nodeDescriptor, predicates: scope + rootKey, offset: 0, limit: 2)
        guard anchorPage.records.count == 1, !anchorPage.hasMore, let anchorRecord = anchorPage.records.first, anchorRecord.identity != nil else {
            return .init(connections: [], hasMore: false, nextOffset: nil, messages: ["This record is outside the mapping's node scope, no longer exists, or has no stable identity."], queryCount: queryCount)
        }
        let anchor = labeled(anchorRecord, column: mapping.labelColumn)
        guard let anchorKey = tuple(anchor, mapping.nodeIDColumns) else { throw RecordGraphMappingError.invalid("The scoped node no longer has its configured identifier.") }
        let nearColumns = direction == .outgoing ? mapping.sourceColumns : mapping.targetColumns
        let farColumns = direction == .outgoing ? mapping.targetColumns : mapping.sourceColumns
        let endpointPredicates = zip(nearColumns, anchorKey).map { IdentityComponent(columnName: $0.0, value: $0.1.value) }
        try Task.checkCancellation()
        queryCount += 1
        let pageOffset = min(max(offset, 0), Int.max - RecordAccess.maximumPageSize - 1)
        let edgePage = try await database.fetchRecords(descriptor: validated.edgeDescriptor, predicates: mapping.edgeScope.map(\.predicate) + endpointPredicates, offset: pageOffset, limit: pageSize)
        var connections: [RecordMappedConnection] = []
        var messages: [String] = []
        enum Endpoint { case found(RecordSnapshot), absent }
        var cache: [[IdentityComponent]: Endpoint] = [anchorKey: .found(anchor)]
        for (index, edge) in edgePage.records.enumerated() {
            try Task.checkCancellation()
            guard edge.identity != nil else { messages.append("Edge at offset \(pageOffset + index) has no stable identity."); continue }
            guard let farTuple = tuple(edge, farColumns) else { messages.append("Edge \(edge.label) has a missing or NULL endpoint identifier."); continue }
            let key = zip(mapping.nodeIDColumns, farTuple).map { IdentityComponent(columnName: $0.0, value: $0.1.value) }
            let endpoint: Endpoint
            if let cached = cache[key] { endpoint = cached }
            else {
                queryCount += 1
                let targetPage = try await database.fetchRecords(descriptor: validated.nodeDescriptor, predicates: scope + key, offset: 0, limit: 2)
                if targetPage.records.count == 1, !targetPage.hasMore, let record = targetPage.records.first, record.identity != nil {
                    endpoint = .found(labeled(record, column: mapping.labelColumn))
                } else { endpoint = .absent }
                cache[key] = endpoint
            }
            guard case .found(let other) = endpoint else { messages.append("Edge \(edge.label) points to a missing, unstable or out-of-scope node."); continue }
            let typeValue = mapping.typeColumn.flatMap { edge.value(for: $0) }
            let label = typeValue.flatMap { $0 == .null ? nil : String($0.displayText.prefix(100)) }
            connections.append(.init(edge: edge, source: direction == .outgoing ? anchor : other, target: direction == .outgoing ? other : anchor, label: label, isDirected: mapping.isDirected, edgeOffset: pageOffset + index))
        }
        return .init(connections: connections, hasMore: edgePage.hasMore, nextOffset: edgePage.nextOffset, messages: messages, queryCount: queryCount)
    }

    private static func labeled(_ record: RecordSnapshot, column: String?) -> RecordSnapshot {
        guard let column, let value = record.value(for: column), value != .null, !value.displayText.isEmpty else { return record }
        return .init(descriptor: record.descriptor, columns: record.columns, values: record.values, identity: record.identity, label: String(value.displayText.prefix(100)))
    }
}
