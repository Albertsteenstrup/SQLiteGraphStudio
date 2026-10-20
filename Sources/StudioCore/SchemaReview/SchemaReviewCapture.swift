import Foundation

public enum SchemaReviewCapture {
    public static func snapshot(document url: URL, unixSocketPath: String? = nil) async throws -> SchemaReviewSnapshot {
        let service = DatabaseService()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try Task.checkCancellation()
            let engine: String
            if DatabaseDocument.sqliteExtensions.contains(url.pathExtension.lowercased()) {
                guard FileManager.default.fileExists(atPath: url.path) else { throw SchemaReviewError.invalid("Database file does not exist.") }
                engine = "sqlite"
                try await service.open(url: url, readOnly: true, includeRowCounts: false)
            } else if DatabaseDocument.isArchive(url) {
                engine = "postgresql"
                try await service.open(dump: url)
            } else if PostgresConnectionDocument.supportedFileExtensions.contains(url.pathExtension.lowercased()) {
                engine = "postgresql"
                let doc = try JSONDecoder().decode(PostgresConnectionDocument.self, from: Data(contentsOf: url))
                try await service.open(postgres: doc.configuration, unixSocketPath: unixSocketPath)
            } else { throw SchemaReviewError.invalid("Choose a SQLite file, PostgreSQL backup, or connection document.") }
            let catalog = try await service.loadCatalogSnapshot()
            try Task.checkCancellation()
            var result = makeSnapshot(catalog, engine: engine)
            if engine == "postgresql" {
                // Full FK definitions include actions/deferrability that the browsing
                // catalog does not need. Object OIDs never enter the saved evidence.
                let definitions = try await service.executeReadOnlyQuery(sql: """
                    SELECT n.nspname AS schema_name, c.relname AS table_name, k.conname AS name,
                           pg_catalog.pg_get_constraintdef(k.oid, false) AS definition
                    FROM pg_catalog.pg_constraint k
                    JOIN pg_catalog.pg_class c ON c.oid = k.conrelid
                    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname !~ '^pg_temp_'
                    ORDER BY n.nspname, c.relname, k.conname
                    """, rowLimit: 100_000)
                guard definitions.rows.count < 10_000 else { throw SchemaReviewError.invalid("Constraint catalog exceeds the capture limit; refusing a partial comparison.") }
                for row in definitions.rows {
                    let values = row.values.map(\.displayText)
                    guard values.count == 4, let index = result.tables.firstIndex(where: { $0.schema == values[0] && $0.name == values[1] }) else { continue }
                    result.tables[index].metadata["constraint:" + values[2]] = values[3]
                    let key = SchemaReviewSnapshot.token([result.tables[index].id, values[2]])
                    if let relation = result.relations.firstIndex(where: { $0.id == key }) { result.relations[relation].definition = values[3] }
                }
                let views = try await service.executeReadOnlyQuery(sql: """
                    SELECT n.nspname, c.relname, pg_catalog.pg_get_viewdef(c.oid, false)
                    FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                    WHERE c.relkind IN ('v', 'm') AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname !~ '^pg_temp_'
                    ORDER BY n.nspname, c.relname
                    """, rowLimit: 100_000)
                guard views.rows.count < 10_000 else { throw SchemaReviewError.invalid("View catalog exceeds the capture limit; refusing a partial comparison.") }
                for row in views.rows {
                    let values = row.values.map(\.displayText)
                    if values.count == 3, let index = result.tables.firstIndex(where: { $0.schema == values[0] && $0.name == values[1] }) {
                        result.tables[index].metadata["definition"] = values[2]
                    }
                }
            } else {
                let sql = try await service.executeReadOnlyQuery(sql: "SELECT name, sql FROM sqlite_schema WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name", rowLimit: 100_000)
                guard sql.rows.count < 10_000 else { throw SchemaReviewError.invalid("SQLite catalog exceeds the capture limit; refusing a partial comparison.") }
                for row in sql.rows {
                    let values = row.values.map(\.displayText)
                    if values.count == 2, let index = result.tables.firstIndex(where: { $0.id == values[0] }) { result.tables[index].metadata["definition"] = values[1] }
                }
                // PRAGMA's stable column/action signatures avoid false diffs when
                // SQLite renumbers foreign keys after an unrelated constraint edit.
                var capturedRelations: [SchemaReviewSnapshot.Relation] = []
                for table in result.tables {
                    let quoted = table.name.replacingOccurrences(of: "'", with: "''")
                    let foreignKeys = try await service.executeReadOnlyQuery(sql: "SELECT * FROM pragma_foreign_key_list('\(quoted)') ORDER BY id, seq", rowLimit: 100_000)
                    guard foreignKeys.rows.count < 10_000 else { throw SchemaReviewError.invalid("Foreign-key catalog exceeds the capture limit.") }
                    let grouped = Dictionary(grouping: foreignKeys.rows) { $0.values[0].displayText }
                    for group in grouped.values {
                        let rows = group.sorted { (Int($0.values[1].displayText) ?? 0) < (Int($1.values[1].displayText) ?? 0) }
                        guard let first = rows.first, first.values.count >= 8,
                              let target = result.tables.first(where: { RecordAccess.sqliteIdentifierMatches($0.name, first.values[2].displayText) }) else {
                            throw SchemaReviewError.invalid("A foreign-key target is missing from the schema.")
                        }
                        let keys = target.columns.filter { $0.primaryKeyOrdinal > 0 }.sorted { $0.primaryKeyOrdinal < $1.primaryKeyOrdinal }
                        let sourceColumns = rows.map { row in table.columns.first { RecordAccess.sqliteIdentifierMatches($0.name, row.values[3].displayText) }?.name ?? row.values[3].displayText }
                        let targetColumns = rows.enumerated().map { index, row in
                            row.values[4] == .null ? (keys.indices.contains(index) ? keys[index].name : "") : target.columns.first { RecordAccess.sqliteIdentifierMatches($0.name, row.values[4].displayText) }?.name ?? row.values[4].displayText
                        }
                        let stable = SchemaReviewSnapshot.token([table.id, target.id] + sourceColumns + ["→"] + targetColumns)
                        let definition = "FOREIGN KEY (\(sourceColumns.joined(separator: ", "))) REFERENCES \(target.id) (\(targetColumns.joined(separator: ", "))) ON UPDATE \(first.values[5].displayText) ON DELETE \(first.values[6].displayText) MATCH \(first.values[7].displayText)"
                        capturedRelations.append(.init(id: stable, source: table.id, target: target.id, sourceColumns: sourceColumns, targetColumns: targetColumns, definition: definition))
                    }
                }
                var occurrences: [String: Int] = [:]
                result.relations = capturedRelations.sorted { [$0.id, $0.definition].lexicographicallyPrecedes([$1.id, $1.definition]) }.map { relation in
                    var value = relation
                    let occurrence = occurrences[value.id, default: 0]
                    occurrences[value.id] = occurrence + 1
                    if occurrence > 0 { value.id += ":\(occurrence)" }
                    return value
                }
            }
            try result.validate()
            try Task.checkCancellation()
            await service.close()
            return result
        } catch {
            await service.close()
            throw error
        }
    }

    static func makeSnapshot(_ catalog: CatalogSnapshot, engine: String) -> SchemaReviewSnapshot {
        let tables = catalog.descriptors.sorted { $0.id < $1.id }.map { descriptor in
            var metadata: [String: String] = [:]
            for index in descriptor.indexes {
                metadata["index:" + index.name] = index.sql ?? "\(index.isUnique):\(index.isPartial):" + index.columns.joined(separator: ",")
            }
            for trigger in descriptor.triggers { metadata["trigger:" + trigger.name] = trigger.sql }
            for constraint in descriptor.constraints where constraint.kind != .foreignKey {
                // Generated IDs may contain PostgreSQL OIDs. Definition/name are stable.
                let key = constraint.name ?? SchemaReviewSnapshot.token([constraint.kind.rawValue] + constraint.columns + [constraint.detail])
                metadata["constraint:" + key] = constraint.detail
            }
            metadata["withoutRowID"] = String(descriptor.isWithoutRowID)
            return SchemaReviewSnapshot.Table(id: descriptor.id, schema: descriptor.schemaName, name: descriptor.objectName,
                kind: descriptor.objectType.rawValue, columns: descriptor.columns.map {
                    .init(name: $0.name, type: $0.declaredType, notNull: $0.notNull, defaultSQL: $0.defaultValueSQL,
                          primaryKeyOrdinal: $0.primaryKeyOrdinal, generated: $0.hiddenValue, identity: $0.identityKind)
                }, metadata: metadata)
        }
        var duplicateCounts: [String: Int] = [:]
        let relations = RecordAccess.relationships(catalog: catalog).map { relation in
            let source = relation.sourceDescriptor?.id ?? relation.sourceTable.displayName
            let target = relation.targetDescriptor?.id ?? relation.targetTable.displayName
            let nativeID = relation.id.components(separatedBy: ":fk:").last ?? ""
            let constraint = relation.sourceDescriptor?.constraints.first { $0.id == "\(source).fk.\(nativeID)" }
            let stable = engine == "postgresql" && constraint?.name != nil
                ? SchemaReviewSnapshot.token([source, constraint!.name!])
                : SchemaReviewSnapshot.token([source, target] + relation.sourceColumns + ["→"] + relation.targetColumns)
            let occurrence = duplicateCounts[stable, default: 0]
            duplicateCounts[stable] = occurrence + 1
            return SchemaReviewSnapshot.Relation(id: occurrence == 0 ? stable : stable + ":\(occurrence)", source: source, target: target,
                sourceColumns: relation.sourceColumns, targetColumns: relation.targetColumns, definition: constraint?.detail ?? "FOREIGN KEY")
        }.sorted { $0.id < $1.id }
        return SchemaReviewSnapshot(engine: engine, tables: tables, relations: relations)
    }
}
