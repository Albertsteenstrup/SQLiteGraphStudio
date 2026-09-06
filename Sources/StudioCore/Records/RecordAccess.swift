import Foundation

/// Pure record identity, relationship, and bounded query planning shared by both backends.
public enum RecordAccess {
    public static let maximumPageSize = 50

    public static func snapshot(descriptor: TableDescriptor?, columns: [QueryResultColumn], values: [SQLiteValue], rowIdentity: TableRowIdentity? = nil) throws -> RecordSnapshot {
        guard columns.count == values.count else { throw RecordAccessError.invalidSnapshot }
        var identity: RecordIdentity?
        if let descriptor {
            let keys = uniqueKeys(descriptor)
            for key in keys {
                var locator: [IdentityComponent] = []
                for column in key {
                    let matches = columns.indices.filter { columns[$0].name == column }
                    guard matches.count == 1, let index = matches.first, values[index] != .null else { break }
                    locator.append(.init(columnName: column, value: values[index]))
                }
                if locator.count == key.count {
                    identity = RecordIdentity(table: .init(descriptor: descriptor), locator: locator)
                    break
                }
            }
            // Legacy table chunks select _rowid_. Never reinterpret a shadowed
            // user column or the old all-columns fallback as a proven locator.
            if identity == nil, case .rowID(let value) = rowIdentity,
               sqliteRowIDColumn(descriptor) == "_rowid_" {
                identity = RecordIdentity(table: .init(descriptor: descriptor), locator: [.init(columnName: "_rowid_", value: .integer(value))])
            }
        }
        let keyNames = Set(identity?.locator.map(\.columnName) ?? descriptor?.primaryKeyColumns ?? [])
        let nonKeyValues = columns.indices.filter { !keyNames.contains(columns[$0].name) }.map { values[$0] }
        func readable(_ value: SQLiteValue) -> Bool {
            if value == .null { return false }
            if case .blob = value { return false }
            return !value.displayText.isEmpty
        }
        let textLabel = nonKeyValues.first { value in
            if case .text(let text) = value { return !text.isEmpty }
            return false
        }
        let useful = (textLabel ?? nonKeyValues.first(where: readable) ?? values.first(where: readable))?.displayText ?? "Record"
        let label = String(useful.prefix(100))
        return RecordSnapshot(descriptor: descriptor, columns: columns, values: values, identity: identity, label: label)
    }

    public static func relationships(catalog: CatalogSnapshot) -> [RecordRelationship] {
        if let metadata = catalog.recordRelationshipMetadata { return metadata }
        struct GroupKey: Hashable {
            let source: String
            let target: String
            let constraint: String
            var order: [String] { [source, target, constraint] }
        }
        let grouped = Dictionary(grouping: catalog.graph.edges) { edge in
            let constraint: String
            if let hash = edge.id.lastIndex(of: "#"), let colon = edge.id.lastIndex(of: ":"), hash < colon,
               Int(edge.id[edge.id.index(after: colon)...]) != nil {
                constraint = String(edge.id[edge.id.index(after: hash)..<colon])
            } else { constraint = edge.id }
            return GroupKey(source: edge.sourceID, target: edge.targetID, constraint: constraint)
        }
        return grouped.sorted { $0.key.order.lexicographicallyPrecedes($1.key.order) }.compactMap { group, edges in
            let ordered = edges.sorted { componentOrdinal($0.id) < componentOrdinal($1.id) }
            guard let first = ordered.first else { return nil }
            let sourceMatches = catalog.descriptors.filter { $0.schemaName == nil ? sqliteIdentifierMatches($0.name, first.sourceID) : $0.name == first.sourceID }
            let targetMatches = catalog.descriptors.filter { $0.schemaName == nil ? sqliteIdentifierMatches($0.name, first.targetID) : $0.name == first.targetID }
            guard sourceMatches.count == 1, let source = sourceMatches.first else { return nil }
            let target = targetMatches.count == 1 ? targetMatches.first : nil
            let targetColumns = ordered.enumerated().map { index, edge in
                if !edge.targetColumn.isEmpty { return canonicalColumn(edge.targetColumn, descriptor: target) }
                guard let target, target.primaryKeyColumns.count == ordered.count else { return "" }
                return target.primaryKeyColumns[index]
            }
            let id = RecordTableID(descriptor: source).id + ":" + (target.map(RecordTableID.init(descriptor:)) ?? .init(schemaName: source.schemaName, objectName: first.targetID)).id + ":fk:" + group.constraint
            return RecordRelationship(id: id, sourceTable: .init(descriptor: source), targetTable: target.map(RecordTableID.init(descriptor:)) ?? .init(schemaName: source.schemaName, objectName: first.targetID), sourceColumns: ordered.map { canonicalColumn($0.sourceColumn, descriptor: source) }, targetColumns: targetColumns, sourceDescriptor: source, targetDescriptor: target)
        }
    }

    /// SQLite folds ASCII identifier letters; non-ASCII identifiers stay distinct.
    static func sqliteIdentifierMatches(_ lhs: String, _ rhs: String) -> Bool {
        func folded(_ value: String) -> [UInt8] { value.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 } }
        return folded(lhs) == folded(rhs)
    }

    private static func canonicalColumn(_ name: String, descriptor: TableDescriptor?) -> String {
        guard let descriptor else { return name }
        return descriptor.columns.first { descriptor.schemaName == nil ? sqliteIdentifierMatches($0.name, name) : $0.name == name }?.name ?? name
    }

    static func uniqueKeys(_ descriptor: TableDescriptor) -> [[String]] {
        guard [.table, .partitionedTable, .materializedView].contains(descriptor.objectType) else { return [] }
        let names = Set(descriptor.columns.map(\.name))
        let candidates = [descriptor.primaryKeyColumns] + descriptor.indexes
            .filter { $0.isUnique && !$0.isPartial }
            .sorted { $0.name < $1.name }.map(\.columns)
        return candidates.filter { !$0.isEmpty && Set($0).count == $0.count && $0.allSatisfy { !$0.isEmpty && names.contains($0) } }
    }

    static func sqliteRowIDColumn(_ descriptor: TableDescriptor) -> String? {
        guard descriptor.schemaName == nil, descriptor.objectType == .table, !descriptor.isWithoutRowID else { return nil }
        let names = Set(descriptor.columns.map { $0.name.lowercased() })
        return ["_rowid_", "rowid", "oid"].first { !names.contains($0) }
    }

    static func relatedPlan(record: RecordSnapshot, relationship: RecordRelationship, direction: RecordDirection, offset: Int, limit: Int, postgres: Bool) throws -> RecordQueryPlan? {
        let currentTable = direction == .outgoing ? relationship.sourceTable : relationship.targetTable
        guard record.table == currentTable else { throw RecordAccessError.wrongTable }
        let sourceColumns = direction == .outgoing ? relationship.sourceColumns : relationship.targetColumns
        let targetColumns = direction == .outgoing ? relationship.targetColumns : relationship.sourceColumns
        guard !sourceColumns.isEmpty, sourceColumns.count == targetColumns.count,
              sourceColumns.allSatisfy({ !$0.isEmpty }), targetColumns.allSatisfy({ !$0.isEmpty }) else { throw RecordAccessError.invalidRelationship }
        let missing = sourceColumns.filter { record.value(for: $0) == nil }
        guard missing.isEmpty else { throw RecordAccessError.missingColumns(missing) }
        let values = sourceColumns.compactMap { record.value(for: $0) }
        if values.contains(.null) { return nil }
        guard let descriptor = direction == .outgoing ? relationship.targetDescriptor : relationship.sourceDescriptor else { throw RecordAccessError.unavailableTable }
        if direction == .incoming {
            guard let parent = relationship.targetDescriptor else { throw RecordAccessError.unavailableTable }
            let unknown = targetColumns.filter { name in !descriptor.columns.contains { $0.name == name } }
            guard unknown.isEmpty else { throw RecordAccessError.missingColumns(unknown) }
            let childAlias = "record_child"
            let parentAlias = "record_parent"
            func parentColumn(_ name: String) -> String { quoteIdentifier(parentAlias) + "." + quoteIdentifier(name) }
            func childColumn(_ name: String) -> String { quoteIdentifier(childAlias) + "." + quoteIdentifier(name) }
            let anchor = try sourceColumns.enumerated().map { index, name in
                guard postgres else { return parentColumn(name) + " = ?" }
                guard let column = parent.columns.first(where: { $0.name == name }) else { throw RecordAccessError.missingColumns([name]) }
                return parentColumn(name) + " = $\(index + 1)::text::" + (try postgresCast(column.declaredType))
            }
            // Unary + removes the child's column affinity. FK comparisons always
            // use the parent key's affinity and collation, even for TEXT vs INTEGER.
            // PostgreSQL also allows different parent/child base types. Keep the
            // parent column in the comparison instead of narrowing its bound key
            // to the child's type (numeric 1.3 is not an integer lookup error).
            let matching = zip(sourceColumns, targetColumns).map { parentColumn($0.0) + (postgres ? " = " : " = +") + childColumn($0.1) }
            let exists = "EXISTS (SELECT 1 FROM \(parent.tableDataSQLSource) AS \(quoteIdentifier(parentAlias)) WHERE \((anchor + matching).joined(separator: " AND ")))"
            return try selectionPlan(descriptor: descriptor, terms: [exists], parameters: values, offset: offset, limit: limit, postgres: postgres, alias: childAlias)
        }
        return try plan(descriptor: descriptor, predicates: zip(targetColumns, values).map { .init(columnName: $0.0, value: $0.1) }, offset: offset, limit: limit, postgres: postgres)
    }

    static func plan(descriptor: TableDescriptor, predicates: [IdentityComponent], offset: Int, limit: Int, postgres: Bool) throws -> RecordQueryPlan {
        let columns = descriptor.columns
        guard !columns.isEmpty else { throw RecordAccessError.unavailableTable }
        let knownNames = Set(columns.map(\.name))
        let unknown = predicates.map(\.columnName).filter { !knownNames.contains($0) }
        guard unknown.isEmpty else { throw RecordAccessError.missingColumns(unknown) }
        var parameters: [SQLiteValue] = []
        let terms = try predicates.map { predicate -> String in
            let name = quoteIdentifier(predicate.columnName)
            if predicate.value == .null { return "\(name) IS NULL" }
            parameters.append(predicate.value)
            if postgres {
                let type = columns.first { $0.name == predicate.columnName }!.declaredType
                return "\(name) = $\(parameters.count)::text::\(try postgresCast(type))"
            }
            return "\(name) = ?"
        }
        return try selectionPlan(descriptor: descriptor, terms: terms, parameters: parameters, offset: offset, limit: limit, postgres: postgres)
    }

    private static func selectionPlan(descriptor: TableDescriptor, terms: [String], parameters: [SQLiteValue], offset: Int, limit: Int, postgres: Bool, alias: String? = nil) throws -> RecordQueryPlan {
        let boundedLimit = min(max(limit, 1), maximumPageSize)
        let boundedOffset = min(max(offset, 0), Int.max - maximumPageSize - 1)
        let columns = descriptor.columns
        guard !columns.isEmpty else { throw RecordAccessError.unavailableTable }
        func columnReference(_ name: String) -> String {
            (alias.map { quoteIdentifier($0) + "." } ?? "") + quoteIdentifier(name)
        }
        let rowIDColumn = postgres ? nil : sqliteRowIDColumn(descriptor)
        var order = uniqueKeys(descriptor).first { key in
            key.allSatisfy { name in columns.first { $0.name == name }?.notNull == true }
        } ?? []
        if let rowIDColumn, order.isEmpty { order = [rowIDColumn] }
        if order.isEmpty { order = descriptor.primaryKeyColumns }
        let selected = columns.map { columnReference($0.name) } + (rowIDColumn.map { [columnReference($0)] } ?? [])
        let whereSQL = terms.isEmpty ? "" : " WHERE " + terms.joined(separator: " AND ")
        let orderSQL = order.isEmpty ? "" : " ORDER BY " + order.map(columnReference).joined(separator: ", ")
        let aliasSQL = alias.map { " AS " + quoteIdentifier($0) } ?? ""
        let sql = "SELECT \(selected.joined(separator: ", ")) FROM \(descriptor.tableDataSQLSource)\(aliasSQL)\(whereSQL)\(orderSQL) LIMIT \(boundedLimit + 1) OFFSET \(boundedOffset)"
        return RecordQueryPlan(sql: sql, parameters: parameters, descriptor: descriptor, offset: boundedOffset, limit: boundedLimit, rowIDColumn: rowIDColumn)
    }

    static func page(values: [[SQLiteValue]], plan: RecordQueryPlan, missingReference: Bool = false) throws -> RecordPage {
        let descriptor = plan.descriptor
        let columns = descriptor.columns.map { QueryResultColumn(name: $0.name, typeLabel: $0.declaredType) }
        let records = try values.prefix(plan.limit).map { values -> RecordSnapshot in
            let snapshot = try snapshot(descriptor: descriptor, columns: columns, values: Array(values.prefix(columns.count)))
            guard snapshot.identity == nil, let rowIDColumn = plan.rowIDColumn,
                  values.count > columns.count, case .integer(let rowID) = values[columns.count] else { return snapshot }
            return RecordSnapshot(descriptor: descriptor, columns: columns, values: snapshot.values, identity: .init(table: .init(descriptor: descriptor), locator: [.init(columnName: rowIDColumn, value: .integer(rowID))]), label: snapshot.label)
        }
        let hasMore = values.count > plan.limit
        return RecordPage(records: records, hasMore: hasMore, nextOffset: hasMore ? plan.offset + plan.limit : nil, status: missingReference && records.isEmpty && plan.offset == 0 ? .missingReference : .loaded)
    }

    private static func componentOrdinal(_ id: String) -> Int {
        id.lastIndex(of: ":").flatMap { Int(id[id.index(after: $0)...]) } ?? 0
    }

    /// Accept only a type grammar, never arbitrary SQL from a display label.
    private static func postgresCast(_ type: String) throws -> String {
        let identifier = #"(?:"(?:[^"]|"")*"|[A-Za-z_][A-Za-z0-9_$]*)"#
        let namedType = identifier + #"(?:\."# + identifier + #")?"#
        let builtIn = #"(?:double precision|character varying|bit varying|timestamp(?:\([0-9]+\))? (?:with|without) time zone|time(?:\([0-9]+\))? (?:with|without) time zone)"#
        let pattern = "^(?:" + builtIn + "|" + namedType + #")(?:\([0-9]+(?:\s*,\s*-?[0-9]+)?\))?(?:\[\])*$"#
        guard type.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else { throw RecordAccessError.unsupportedType(type) }
        // A lookup parameter must retain its complete value. Reapplying the
        // column's length/precision can truncate or round a missing FK into a match.
        // Preserve quoted type names verbatim, even when they contain parentheses.
        var comparisonType = "", quoted = false
        var index = type.startIndex
        while index < type.endIndex {
            let character = type[index]
            if character == "\"" { quoted.toggle() }
            if character == "(" && !quoted {
                while index < type.endIndex && type[index] != ")" { index = type.index(after: index) }
            } else { comparisonType.append(character) }
            index = type.index(after: index)
        }
        let base = comparisonType.lowercased()
        // SQL character without a length defaults to one; bpchar has no typmod.
        if base == "character" || base.hasPrefix("character[") {
            return "pg_catalog.bpchar" + comparisonType.dropFirst("character".count)
        }
        if base == "bit" || base.hasPrefix("bit[") {
            // Qualified catalog BIT has no default SQL length and retains the
            // bit[] element type needed by PostgreSQL's array equality operator.
            return "pg_catalog.bit" + comparisonType.dropFirst("bit".count)
        }
        // Money input uses lc_monetary separators; our exact amounts use the
        // locale-independent numeric syntax, including each array element.
        let lower = comparisonType.lowercased()
        if lower == "money" { return "numeric::money" }
        if lower == "money[]" { return "numeric[]::money[]" }
        return comparisonType
    }
}

struct RecordQueryPlan: Sendable {
    let sql: String
    let parameters: [SQLiteValue]
    let descriptor: TableDescriptor
    let offset: Int
    let limit: Int
    let rowIDColumn: String?
}
