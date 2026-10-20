import Foundation
import CryptoKit

/// Portable schema evidence. No rows, connection settings, or credentials belong here.
public struct SchemaReviewSnapshot: Codable, Sendable, Equatable {
    public var version = 1
    public var engine: String
    public var tables: [Table]
    public var relations: [Relation]

    public init(version: Int = 1, engine: String, tables: [Table], relations: [Relation]) {
        self.version = version
        self.engine = engine
        self.tables = tables
        self.relations = relations
    }

    public struct Column: Codable, Sendable, Equatable, Identifiable {
        public var name: String
        public var type: String
        public var notNull: Bool
        public var defaultSQL: String?
        public var primaryKeyOrdinal: Int
        public var generated: Int
        public var identity: String
        public var id: String { name }

        public init(name: String, type: String, notNull: Bool, defaultSQL: String? = nil,
                    primaryKeyOrdinal: Int, generated: Int, identity: String) {
            self.name = name
            self.type = type
            self.notNull = notNull
            self.defaultSQL = defaultSQL
            self.primaryKeyOrdinal = primaryKeyOrdinal
            self.generated = generated
            self.identity = identity
        }

        var descriptor: TableColumn {
            TableColumn(name: name, declaredType: type, notNull: notNull, defaultValueSQL: defaultSQL,
                        primaryKeyOrdinal: primaryKeyOrdinal, hiddenValue: generated, isEditable: false, identityKind: identity)
        }
        public var description: String {
            ([type, notNull ? "NOT NULL" : "NULL"] + (defaultSQL.map { ["DEFAULT " + $0] } ?? [])
             + (primaryKeyOrdinal > 0 ? ["PK \(primaryKeyOrdinal)"] : [])
             + (generated != 0 ? ["GENERATED"] : []) + (identity.isEmpty ? [] : ["IDENTITY " + identity])).joined(separator: " · ")
        }
    }
    public struct Table: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var schema: String?
        public var name: String
        public var kind: String
        public var columns: [Column]
        /// Canonical definitions of constraints, indexes, triggers, and table/view options.
        public var metadata: [String: String]
        public var displayName: String { schema == "public" ? name : id }

        public init(id: String, schema: String?, name: String, kind: String,
                    columns: [Column], metadata: [String: String]) {
            self.id = id
            self.schema = schema
            self.name = name
            self.kind = kind
            self.columns = columns
            self.metadata = metadata
        }

        var descriptor: EditableTableDescriptor {
            EditableTableDescriptor(name: id, objectType: SQLiteObjectType(rawValue: kind) ?? .unknown,
                                    columns: columns.map(\.descriptor), primaryKeyColumns: columns.filter { $0.primaryKeyOrdinal > 0 }.sorted { $0.primaryKeyOrdinal < $1.primaryKeyOrdinal }.map(\.name),
                                    rowIdentityStrategy: .readOnly, isWithoutRowID: false, isEditable: false,
                                    schemaName: schema, objectName: name)
        }
    }
    public struct Relation: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var source: String
        public var target: String
        public var sourceColumns: [String]
        public var targetColumns: [String]
        public var definition: String

        public init(id: String, source: String, target: String,
                    sourceColumns: [String], targetColumns: [String], definition: String) {
            self.id = id
            self.source = source
            self.target = target
            self.sourceColumns = sourceColumns
            self.targetColumns = targetColumns
            self.definition = definition
        }
    }

    public func validate() throws {
        guard version == 1, ["sqlite", "postgresql"].contains(engine), tables.count <= 20_000,
              Set(tables.map(\.id)).count == tables.count, Set(relations.map(\.id)).count == relations.count else {
            throw SchemaReviewError.invalid("Unsupported or duplicate schema objects.")
        }
        let lookup = Dictionary(uniqueKeysWithValues: tables.map { ($0.id, $0) })
        for table in tables {
            guard !table.id.isEmpty, !table.name.isEmpty, table.columns.count <= 10_000,
                  Set(table.columns.map(\.name)).count == table.columns.count,
                  table.columns.allSatisfy({ !$0.name.isEmpty && $0.primaryKeyOrdinal >= 0 }) else {
                throw SchemaReviewError.invalid("Invalid fields in \(table.id).")
            }
        }
        for relation in relations {
            guard !relation.id.isEmpty, let source = lookup[relation.source], let target = lookup[relation.target],
                  !relation.sourceColumns.isEmpty, relation.sourceColumns.count == relation.targetColumns.count,
                  relation.sourceColumns.allSatisfy({ name in source.columns.contains { $0.name == name } }),
                  relation.targetColumns.allSatisfy({ name in target.columns.contains { $0.name == name } }) else {
                throw SchemaReviewError.invalid("Incomplete relation \(relation.id). Capture both endpoints with sufficient catalog permissions.")
            }
        }
    }

    public func fingerprint() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }

    public func schemaChanges(to fresh: SchemaReviewSnapshot) -> [String] {
        let oldRelations = Dictionary(uniqueKeysWithValues: relations.map { ($0.id, $0) })
        let newRelations = Dictionary(uniqueKeysWithValues: fresh.relations.map { ($0.id, $0) })
        let changedRelations = Set(oldRelations.keys).union(newRelations.keys).sorted().flatMap { id -> [(label: String, relation: Relation)] in
            if let a = oldRelations[id], let b = newRelations[id] {
                if a == b { return [] }
                if a.source == b.source, a.target == b.target {
                    return [("Changed", b)]
                }
                return [("Removed", a), ("New", b)]
            }
            return [(newRelations[id] == nil ? "Removed" : "New", newRelations[id] ?? oldRelations[id]!)]
        }
        let touched = Set(changedRelations.flatMap { [$0.relation.source, $0.relation.target] })
        let oldTables = Dictionary(uniqueKeysWithValues: tables.map { ($0.id, $0) })
        let newTables = Dictionary(uniqueKeysWithValues: fresh.tables.map { ($0.id, $0) })
        let tableSummaries = Set(oldTables.keys).union(newTables.keys).sorted().compactMap { id -> String? in
            let before = oldTables[id]
            let after = newTables[id]
            let added = after?.columns.filter { col in !(before?.columns.contains { $0.name == col.name } ?? false) }.count ?? 0
            let removed = before?.columns.filter { col in !(after?.columns.contains { $0.name == col.name } ?? false) }.count ?? 0
            let modified = after?.columns.filter { col in before?.columns.first { $0.name == col.name }.map { $0 != col } ?? false }.count ?? 0
            let label: String? = before == nil ? "New" : after == nil ? "Removed" : (before != after || touched.contains(id) ? "Changed" : nil)
            guard let label else { return nil }
            return "\(label): \(id) (\(added) fields added, \(removed) removed, \(modified) modified)"
        }
        let relationSummaries = changedRelations.map { "\($0.label) relation: \($0.relation.source) → \($0.relation.target)" }
        return tableSummaries + relationSummaries
    }

    static func token(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.map { "\($0.utf8.count):\($0)" }.joined().utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum SchemaReviewError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
