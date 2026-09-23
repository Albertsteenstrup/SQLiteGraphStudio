import Foundation

/// Derives the output column names of a view definition. Only the shape of the
/// outermost select list is inspected; expressions without a name are skipped
/// rather than guessed at.
enum ViewProjection {
    static func columns(from cursor: inout SQLCursor, dialect: SQLDialect) -> [String] {
        if cursor.match("WITH") {
            _ = cursor.match("RECURSIVE")
            while !cursor.isAtEnd, cursor.peekKeyword() != "SELECT" {
                // Test the token's kind, not its payload: a quoted identifier or
                // a literal can spell "(" without being one, and skipping it as
                // a group would leave the cursor where it was.
                let before = cursor.index
                if cursor.isAtOpenParenthesis { _ = cursor.readParenthesizedRange() }
                if cursor.index == before { cursor.advance() }
            }
        }
        if cursor.isAtOpenParenthesis, let inner = cursor.readParenthesizedRange() {
            var innerCursor = SQLCursor(cursor.stream, range: inner)
            return columns(from: &innerCursor, dialect: dialect)
        }
        guard cursor.match("SELECT") else { return [] }
        _ = cursor.match("ALL")
        if cursor.match("DISTINCT"), cursor.match("ON") { _ = cursor.readParenthesizedRange() }

        let selectList = cursor.consume { $0.kind == .word && $0.upper == "FROM" }
        var names: [String] = []
        for piece in cursor.splitTopLevel(selectList) {
            guard let name = columnName(in: piece, stream: cursor.stream, dialect: dialect) else { continue }
            guard !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }

    private static func columnName(in piece: Range<Int>, stream: SQLStatementTokens, dialect: SQLDialect) -> String? {
        let tokens = Array(stream.tokens[piece])
        guard let last = tokens.last else { return nil }
        func folded(_ token: SQLToken) -> String {
            dialect.fold(token.text, quoted: token.kind == .quotedIdentifier)
        }

        if tokens.count >= 2, last.isIdentifier, tokens[tokens.count - 2].upper == "AS",
           tokens[tokens.count - 2].kind == .word {
            return folded(last)
        }
        if tokens.count == 1, last.isIdentifier { return folded(last) }
        if tokens.count >= 3, last.isIdentifier, tokens[tokens.count - 2].kind == .symbol,
           tokens[tokens.count - 2].text == "." {
            return folded(last)
        }
        // `expr alias` without AS, but never a cast's type name.
        if tokens.count >= 2, last.isIdentifier {
            let previous = tokens[tokens.count - 2]
            if previous.kind == .symbol, previous.text == ")" { return folded(last) }
            if previous.isIdentifier, tokens.count == 2, tokens[0].isIdentifier { return folded(last) }
        }
        // `column::type` keeps the column's own name, as PostgreSQL does.
        if tokens.count >= 2, tokens[0].isIdentifier, tokens[1].kind == .symbol, tokens[1].text == "::" {
            return folded(tokens[0])
        }
        return nil
    }
}

/// Turns the replayed intermediate model into the catalog snapshot the rest of
/// the app already consumes.
struct MigrationCatalogAssembler {
    let dialect: SQLDialect
    let tables: [String: MigrationTable]
    let indexes: [String: MigrationIndex]
    let triggers: [String: MigrationTrigger]
    let partitionChildCounts: [String: Int]

    struct Output {
        let catalog: CatalogSnapshot
        let descriptions: [String: SchemaSidecar.TableDescription]
    }

    func assemble() -> Output {
        let primaryKeyColumns = tables.mapValues { $0.primaryKey?.columns ?? [] }
        var indexesByTable: [String: [SchemaIndex]] = [:]
        var uniqueKeySets: [String: Set<String>] = [:]

        for (key, table) in tables {
            var collected: [SchemaIndex] = []
            if let primaryKey = table.primaryKey {
                collected.append(SchemaIndex(name: primaryKey.name, columns: primaryKey.columns,
                                             isUnique: true, origin: "primary", isPartial: false, sql: nil))
            }
            for unique in table.uniques {
                collected.append(SchemaIndex(name: unique.name, columns: unique.columns,
                                             isUnique: true, origin: "c", isPartial: false, sql: nil))
            }
            indexesByTable[key] = collected
        }
        for index in indexes.values.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            guard tables[index.tableKey] != nil else { continue }
            let existing = indexesByTable[index.tableKey] ?? []
            guard !existing.contains(where: { $0.name.caseInsensitiveCompare(index.name) == .orderedSame }) else { continue }
            indexesByTable[index.tableKey, default: []].append(
                SchemaIndex(name: index.name, columns: index.columns, isUnique: index.isUnique,
                            origin: "c", isPartial: index.isPartial, sql: index.sql)
            )
        }
        for (key, collected) in indexesByTable {
            uniqueKeySets[key] = Set(
                collected
                    .filter { $0.isUnique && !$0.isPartial && !$0.columns.isEmpty }
                    .map { $0.columns.map { $0.lowercased() }.joined(separator: "\u{1F}") }
            )
        }

        var triggersByTable: [String: [SchemaTrigger]] = [:]
        for trigger in triggers.values {
            guard tables[trigger.tableKey] != nil else { continue }
            triggersByTable[trigger.tableKey, default: []].append(
                SchemaTrigger(name: trigger.name, tableName: descriptorName(for: trigger.tableKey), sql: trigger.sql)
            )
        }

        var descriptors: [TableDescriptor] = []
        var descriptions: [String: SchemaSidecar.TableDescription] = [:]

        for (key, table) in tables {
            let name = table.qualifiedName
            let keyColumns = table.primaryKey?.columns ?? []
            let columns = table.columns.map { column in
                TableColumn(
                    name: column.name,
                    declaredType: column.type,
                    notNull: column.notNull || keyColumns.contains { $0.caseInsensitiveCompare(column.name) == .orderedSame },
                    defaultValueSQL: column.defaultSQL,
                    primaryKeyOrdinal: keyColumns.firstIndex { $0.caseInsensitiveCompare(column.name) == .orderedSame }
                        .map { $0 + 1 } ?? 0,
                    hiddenValue: column.generatedKind == "stored" ? 3 : (column.generatedKind == "virtual" ? 2 : 0),
                    isEditable: false,
                    identityKind: column.identityKind
                )
            }

            descriptors.append(
                TableDescriptor(
                    name: name,
                    objectType: table.objectType,
                    columns: columns,
                    primaryKeyColumns: keyColumns,
                    rowIdentityStrategy: .readOnly,
                    isWithoutRowID: table.isWithoutRowID,
                    isEditable: false,
                    rowCount: nil,
                    indexes: (indexesByTable[key] ?? []).sorted {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    },
                    triggers: (triggersByTable[key] ?? []).sorted {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    },
                    constraints: constraints(for: table, name: name, primaryKeyColumns: primaryKeyColumns),
                    generatedColumns: table.columns.compactMap { column in
                        guard !column.generatedKind.isEmpty else { return nil }
                        return GeneratedColumnInfo(name: column.name, declaredType: column.type,
                                                   storedKind: column.generatedKind)
                    },
                    schemaName: table.schema,
                    objectName: table.objectName,
                    hasInheritanceChildren: (partitionChildCounts[key] ?? 0) > 0
                )
            )

            let columnComments = Dictionary(
                uniqueKeysWithValues: table.columns.compactMap { column -> (String, String)? in
                    guard let comment = column.comment?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !comment.isEmpty else { return nil }
                    return (column.name, comment)
                }
            )
            let tableComment = table.comment?.trimmingCharacters(in: .whitespacesAndNewlines)
            if !(tableComment?.isEmpty ?? true) || !columnComments.isEmpty {
                descriptions[name] = SchemaSidecar.TableDescription(
                    description: (tableComment?.isEmpty ?? true) ? nil : tableComment,
                    columns: columnComments
                )
            }
        }

        var edges: [GraphEdge] = []
        for (key, table) in tables {
            let sourceID = table.qualifiedName
            for foreignKey in table.foreignKeys {
                guard let target = tables[foreignKey.targetKey] else { continue }
                let targetColumns = foreignKey.targetColumns.isEmpty
                    ? (primaryKeyColumns[foreignKey.targetKey] ?? [])
                    : foreignKey.targetColumns
                guard !targetColumns.isEmpty, targetColumns.count == foreignKey.columns.count else { continue }
                let sourceUnique = uniqueKeySets[key]?.contains(
                    foreignKey.columns.map { $0.lowercased() }.joined(separator: "\u{1F}")
                ) ?? false
                let targetUnique = uniqueKeySets[foreignKey.targetKey]?.contains(
                    targetColumns.map { $0.lowercased() }.joined(separator: "\u{1F}")
                ) ?? false
                let cardinality = inferEdgeCardinality(sourceUnique: sourceUnique, targetUnique: targetUnique)
                let targetID = target.qualifiedName
                for (offset, pair) in zip(foreignKey.columns, targetColumns).enumerated() {
                    edges.append(
                        GraphEdge(
                            id: "\(sourceID)->\(targetID)#\(foreignKey.name):\(offset)",
                            sourceID: sourceID,
                            targetID: targetID,
                            sourceColumn: pair.0,
                            targetColumn: pair.1,
                            cardinality: cardinality
                        )
                    )
                }
            }
        }

        let sortedDescriptors = descriptors.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let nodes = sortedDescriptors
            .map { GraphNode(id: $0.name, title: $0.displayName, isEditable: false) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        return Output(
            catalog: CatalogSnapshot(
                descriptors: sortedDescriptors,
                graph: SchemaGraph(nodes: nodes, edges: edges.sorted { $0.id < $1.id }),
                sourceDescriptions: descriptions
            ),
            descriptions: descriptions
        )
    }

    private func descriptorName(for key: String) -> String {
        tables[key]?.qualifiedName ?? key
    }

    private func constraints(
        for table: MigrationTable,
        name: String,
        primaryKeyColumns: [String: [String]]
    ) -> [SchemaConstraint] {
        var constraints: [SchemaConstraint] = []
        if let primaryKey = table.primaryKey, !primaryKey.columns.isEmpty {
            constraints.append(
                SchemaConstraint(
                    id: "\(name).pk",
                    kind: .primaryKey,
                    name: primaryKey.name,
                    columns: primaryKey.columns,
                    detail: "PRIMARY KEY (\(primaryKey.columns.joined(separator: ", ")))"
                )
            )
        }
        for column in table.columns where column.notNull {
            constraints.append(
                SchemaConstraint(id: "\(name).notNull.\(column.name)", kind: .notNull,
                                 columns: [column.name], detail: "\(column.name) NOT NULL")
            )
        }
        for column in table.columns {
            guard let defaultValue = column.defaultSQL else { continue }
            constraints.append(
                SchemaConstraint(id: "\(name).default.\(column.name)", kind: .defaultValue,
                                 columns: [column.name], detail: "\(column.name) DEFAULT \(defaultValue)")
            )
        }
        for unique in table.uniques {
            constraints.append(
                SchemaConstraint(id: "\(name).unique.\(unique.name)", kind: .unique, name: unique.name,
                                 columns: unique.columns,
                                 detail: "UNIQUE (\(unique.columns.joined(separator: ", ")))")
            )
        }
        for foreignKey in table.foreignKeys {
            let targetName = tables[foreignKey.targetKey]?.qualifiedName ?? foreignKey.targetKey
            let targetColumns = foreignKey.targetColumns.isEmpty
                ? (primaryKeyColumns[foreignKey.targetKey] ?? [])
                : foreignKey.targetColumns
            let reference = targetColumns.isEmpty ? targetName : "\(targetName) (\(targetColumns.joined(separator: ", ")))"
            let actions = foreignKey.actions.isEmpty ? "" : " \(foreignKey.actions)"
            constraints.append(
                SchemaConstraint(
                    id: "\(name).fk.\(foreignKey.name)",
                    kind: .foreignKey,
                    name: foreignKey.name,
                    columns: foreignKey.columns,
                    detail: "FOREIGN KEY (\(foreignKey.columns.joined(separator: ", "))) REFERENCES \(reference)\(actions)"
                )
            )
        }
        for check in table.checks.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            constraints.append(
                SchemaConstraint(id: "\(name).check.\(check.name)", kind: .check, name: check.name,
                                 columns: check.columns, detail: check.detail)
            )
        }
        return constraints
    }
}
