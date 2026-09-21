import Foundation
import CoreFoundation
import CryptoKit

/// Pure metadata projection. This path never opens a database or executes SQL.
public enum SchemaPreview {
    public struct Baseline: Sendable {
        public let snapshot: SchemaReviewSnapshot
        public let label: String
    }

    public static func fingerprint(_ snapshot: SchemaReviewSnapshot) throws -> String {
        var canonical = snapshot
        canonical.tables.sort { $0.id < $1.id }
        canonical.relations.sort { $0.id < $1.id }
        return hash(try encoder().encode(canonical))
    }

    public static func loadBaseline(_ url: URL, side: String = "after") throws -> Baseline {
        guard ["before", "after"].contains(side) else { throw invalid("Side must be before or after.") }
        let data = try read(url, limit: 64 * 1024 * 1024)
        let root = try object(data)
        if root["before"] != nil || root["after"] != nil {
            let review = try JSONDecoder().decode(SchemaReviewDocument.self, from: data)
            try review.validate()
            guard review.proposal == nil else { throw invalid("A proposal is not a captured baseline. Reuse the original snapshot and revise the plan.") }
            return Baseline(snapshot: side == "before" ? review.before : review.after,
                            label: side == "before" ? review.baseRef : review.headRef)
        }
        let snapshot = try JSONDecoder().decode(SchemaReviewSnapshot.self, from: data)
        try snapshot.validate()
        return Baseline(snapshot: snapshot, label: url.lastPathComponent)
    }

    /// A bounded index by default; full fields and incident relations only when requested.
    public static func inspect(_ baseline: Baseline, tables requested: [String] = [], columns: [String] = [], find: String? = nil, limit: Int = 100) throws -> Data {
        guard (1...500).contains(limit) else { throw invalid("Limit must be between 1 and 500.") }
        guard columns.isEmpty || !requested.isEmpty else { throw invalid("Use --table with --column.") }
        let snapshot = baseline.snapshot
        for id in requested where !snapshot.tables.contains(where: { $0.id == id }) { throw invalid("Unknown table \(id).") }
        let matches = snapshot.tables.filter { table in
            (requested.isEmpty || requested.contains(table.id)) && (find == nil || table.id.localizedCaseInsensitiveContains(find!))
        }.sorted { $0.id < $1.id }
        let selected = Array(matches.prefix(limit))
        let selectedIDs = Set(selected.map(\.id))
        for name in columns where !selected.contains(where: { $0.columns.contains { $0.name == name } }) {
            throw invalid("Unknown field \(name) in the selected tables.")
        }
        let tables: [[String: Any]] = selected.map { table in
            var value: [String: Any] = ["id": table.id, "fields": table.columns.count,
                "relations": snapshot.relations.filter { $0.source == table.id || $0.target == table.id }.count]
            if !requested.isEmpty {
                value["kind"] = table.kind
                value["columns"] = table.columns.filter { columns.isEmpty || columns.contains($0.name) }.map { column -> [String: Any] in
                    var result: [String: Any] = ["name": column.name, "type": column.type]
                    if column.notNull { result["notNull"] = true }
                    if let sql = column.defaultSQL { result["defaultSQL"] = sql }
                    if column.primaryKeyOrdinal > 0 { result["primaryKeyOrdinal"] = column.primaryKeyOrdinal }
                    if column.generated != 0 { result["generated"] = column.generated }
                    if !column.identity.isEmpty { result["identity"] = column.identity }
                    return result
                }
            }
            return value
        }
        var result: [String: Any] = ["engine": snapshot.engine, "baseRef": baseline.label,
            "baseFingerprint": try fingerprint(snapshot), "totalMatches": matches.count,
            "truncated": matches.count > selected.count, "tables": tables]
        if !requested.isEmpty {
            let relations = snapshot.relations.filter {
                (selectedIDs.contains($0.source) && (columns.isEmpty || !Set($0.sourceColumns).isDisjoint(with: columns))) ||
                (selectedIDs.contains($0.target) && (columns.isEmpty || !Set($0.targetColumns).isDisjoint(with: columns)))
            }
            result["relations"] = try JSONSerialization.jsonObject(with: encoder().encode(relations))
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    public static func project(_ baseline: Baseline, planData: Data) throws -> SchemaReviewDocument {
        guard planData.count <= 2 * 1024 * 1024 else { throw invalid("Plan exceeds 2 MB.") }
        let plan = Fields(try object(planData))
        try plan.only(["version", "title", "baseFingerprint", "changes", "notes"])
        guard try plan.integer("version", fallback: 1) == 1 else { throw invalid("Unsupported plan version.") }
        let fingerprint = try fingerprint(baseline.snapshot)
        guard try plan.string("baseFingerprint") == fingerprint else {
            throw invalid("The plan's baseline fingerprint does not match. Inspect the intended baseline and revise the plan before retrying.")
        }
        try baseline.snapshot.validate()
        guard let rawChanges = plan.values["changes"] as? [[String: Any]], rawChanges.count <= 2_000 else {
            throw invalid("Provide a changes array with at most 2,000 operations.")
        }
        var result = baseline.snapshot
        for (index, change) in rawChanges.enumerated() {
            do { try apply(Fields(change), to: &result) }
            catch { throw invalid("Change \(index + 1): \(error.localizedDescription)") }
        }
        try result.validate()
        let canonicalPlan = try JSONSerialization.data(withJSONObject: plan.values, options: [.sortedKeys, .withoutEscapingSlashes])
        let proposal = SchemaReviewDocument.Proposal(baseFingerprint: fingerprint, planFingerprint: hash(canonicalPlan))
        let notes = try plan.strings("notes", fallback: [])
        let review = SchemaReviewDocument(title: try plan.string("title", fallback: "Proposed database changes"),
            baseRef: baseline.label, headRef: "Proposed", before: baseline.snapshot, after: result,
            notes: notes + ["Proposed fields, tables and relations only. No SQL was executed. Indexes, triggers, other constraints, data, permissions and migration validity are not projected. Compare real schemas after implementation."], proposal: proposal)
        try review.validate()
        return review
    }

    private static func apply(_ change: Fields, to snapshot: inout SchemaReviewSnapshot) throws {
        let op = try change.string("op")
        let tableOps: [String: Set<String>] = [
            "addTable": ["op", "table", "schema", "name", "kind", "columns"],
            "removeTable": ["op", "table", "cascade"],
            "renameTable": ["op", "table", "to", "schema", "name"],
            "addColumn": ["op", "table", "column"],
            "alterColumn": ["op", "table", "column", "set"],
            "removeColumn": ["op", "table", "column", "cascade"],
            "renameColumn": ["op", "table", "column", "to"]
        ]
        if let allowed = tableOps[op] {
            try change.only(allowed)
            let id = try change.string("table")
            if op == "addTable" {
                guard !snapshot.tables.contains(where: { $0.id == id }) else { throw invalid("Table \(id) already exists.") }
                guard let columns = change.values["columns"] as? [[String: Any]], !columns.isEmpty else { throw invalid("A new table needs columns.") }
                let identity = try tableIdentity(id, engine: snapshot.engine, fields: change)
                let kind = try change.string("kind", fallback: "table")
                guard ["table", "view", "materializedView"].contains(kind) else { throw invalid("Unsupported object kind \(kind).") }
                snapshot.tables.append(.init(id: id, schema: identity.schema, name: identity.name, kind: kind,
                    columns: try columns.map { try column(Fields($0)) }, metadata: [:]))
                return
            }
            guard let tableIndex = snapshot.tables.firstIndex(where: { $0.id == id }) else { throw invalid("Unknown table \(id).") }
            if op == "removeTable" {
                try removeRelations(in: &snapshot, cascade: change.boolean("cascade", fallback: false)) { $0.source == id || $0.target == id }
                snapshot.tables.remove(at: tableIndex)
            } else if op == "renameTable" {
                let target = try change.string("to")
                guard !snapshot.tables.contains(where: { $0.id == target }) else { throw invalid("Table \(target) already exists.") }
                let identity = try tableIdentity(target, engine: snapshot.engine, fields: change)
                snapshot.tables[tableIndex].id = target
                snapshot.tables[tableIndex].name = identity.name
                snapshot.tables[tableIndex].schema = identity.schema
                for index in snapshot.relations.indices {
                    var relation = snapshot.relations[index]
                    let touches = relation.source == id || relation.target == id
                    if relation.source == id { relation.source = target }
                    if relation.target == id { relation.target = target }
                    if touches { relation.definition = proposedDefinition(relation) }
                    snapshot.relations[index] = relation
                }
            } else if op == "addColumn" {
                let added = try column(change.object("column"))
                guard !snapshot.tables[tableIndex].columns.contains(where: { $0.name == added.name }) else { throw invalid("Field \(id).\(added.name) already exists.") }
                snapshot.tables[tableIndex].columns.append(added)
            } else {
                let name = try change.string("column")
                guard let columnIndex = snapshot.tables[tableIndex].columns.firstIndex(where: { $0.name == name }) else { throw invalid("Unknown field \(id).\(name).") }
                if op == "alterColumn" {
                    let patch = try change.object("set")
                    snapshot.tables[tableIndex].columns[columnIndex] = try column(patch, existing: snapshot.tables[tableIndex].columns[columnIndex])
                } else if op == "removeColumn" {
                    guard snapshot.tables[tableIndex].columns.count > 1 else { throw invalid("Remove the table instead of its last field.") }
                    try removeRelations(in: &snapshot, cascade: change.boolean("cascade", fallback: false)) {
                        ($0.source == id && $0.sourceColumns.contains(name)) || ($0.target == id && $0.targetColumns.contains(name))
                    }
                    snapshot.tables[tableIndex].columns.remove(at: columnIndex)
                } else if op == "renameColumn" {
                    let target = try change.string("to")
                    guard !snapshot.tables[tableIndex].columns.contains(where: { $0.name == target }) else { throw invalid("Field \(id).\(target) already exists.") }
                    snapshot.tables[tableIndex].columns[columnIndex].name = target
                    for index in snapshot.relations.indices {
                        var relation = snapshot.relations[index]
                        let original = relation
                        if relation.source == id { relation.sourceColumns = relation.sourceColumns.map { $0 == name ? target : $0 } }
                        if relation.target == id { relation.targetColumns = relation.targetColumns.map { $0 == name ? target : $0 } }
                        if relation != original { relation.definition = proposedDefinition(relation) }
                        snapshot.relations[index] = relation
                    }
                }
            }
        } else if op == "addRelation" {
            try change.only(["op", "id", "source", "target", "sourceColumns", "targetColumns", "definition"])
            let id = try change.string("id")
            guard !snapshot.relations.contains(where: { $0.id == id }) else { throw invalid("Relation \(id) already exists.") }
            var relation = SchemaReviewSnapshot.Relation(id: id, source: try change.string("source"), target: try change.string("target"),
                sourceColumns: try change.strings("sourceColumns"), targetColumns: try change.strings("targetColumns"), definition: "")
            relation.definition = try change.string("definition", fallback: proposedDefinition(relation))
            snapshot.relations.append(relation)
        } else if op == "alterRelation" || op == "removeRelation" {
            try change.only(op == "alterRelation" ? ["op", "id", "set"] : ["op", "id"])
            let id = try change.string("id")
            guard let index = snapshot.relations.firstIndex(where: { $0.id == id }) else { throw invalid("Unknown relation \(id). Use inspect --table to find its ID.") }
            if op == "removeRelation" { snapshot.relations.remove(at: index); return }
            let patch = try change.object("set")
            try patch.only(["source", "target", "sourceColumns", "targetColumns", "definition"])
            guard !patch.values.isEmpty else { throw invalid("The relation patch is empty.") }
            var relation = snapshot.relations[index]
            relation.source = try patch.string("source", fallback: relation.source)
            relation.target = try patch.string("target", fallback: relation.target)
            relation.sourceColumns = try patch.strings("sourceColumns", fallback: relation.sourceColumns)
            relation.targetColumns = try patch.strings("targetColumns", fallback: relation.targetColumns)
            relation.definition = try patch.string("definition", fallback: proposedDefinition(relation))
            snapshot.relations[index] = relation
        } else { throw invalid("Unknown operation \(op).") }
    }

    private static func tableIdentity(_ id: String, engine: String, fields: Fields) throws -> (schema: String?, name: String) {
        if engine == "sqlite" {
            let name = try fields.string("name", fallback: id)
            guard fields.values["schema"] == nil, name == id else {
                throw invalid("SQLite table IDs are their unqualified names.")
            }
            return (nil, id)
        }
        let parts = id.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw invalid("PostgreSQL table IDs need a schema, for example public.orders.") }
        let schema = try fields.string("schema", fallback: parts[0]), name = try fields.string("name", fallback: parts[1])
        guard id == schema + "." + name else { throw invalid("Table ID must equal schema.name.") }
        return (schema, name)
    }

    private static func column(_ fields: Fields, existing: SchemaReviewSnapshot.Column? = nil) throws -> SchemaReviewSnapshot.Column {
        let allowed: Set<String> = ["type", "notNull", "defaultSQL", "primaryKeyOrdinal", "generated", "identity"]
        try fields.only(existing == nil ? allowed.union(["name"]) : allowed)
        guard !fields.values.isEmpty else { throw invalid("The field patch is empty.") }
        var column = SchemaReviewSnapshot.Column(name: try fields.string("name", fallback: existing?.name),
            type: try fields.string("type", fallback: existing?.type),
            notNull: try fields.boolean("notNull", fallback: existing?.notNull ?? false),
            defaultSQL: existing?.defaultSQL,
            primaryKeyOrdinal: try fields.integer("primaryKeyOrdinal", fallback: existing?.primaryKeyOrdinal ?? 0),
            generated: try fields.integer("generated", fallback: existing?.generated ?? 0),
            identity: try fields.string("identity", fallback: existing?.identity ?? "", allowEmpty: true))
        if let value = fields.values["defaultSQL"] {
            if value is NSNull { column.defaultSQL = nil }
            else if let sql = value as? String { column.defaultSQL = sql }
            else { throw invalid("defaultSQL must be a string or null.") }
        }
        return column
    }

    private static func removeRelations(in snapshot: inout SchemaReviewSnapshot, cascade: Bool, matching: (SchemaReviewSnapshot.Relation) -> Bool) throws {
        let dependent = snapshot.relations.filter(matching)
        guard dependent.isEmpty || cascade else { throw invalid("Relations depend on this object: \(dependent.map(\.id).joined(separator: ", ")). Remove them first or explicitly set cascade: true.") }
        snapshot.relations.removeAll(where: matching)
    }

    private static func proposedDefinition(_ relation: SchemaReviewSnapshot.Relation) -> String {
        "Proposed relation: \(relation.source) (\(relation.sourceColumns.joined(separator: ", "))) → \(relation.target) (\(relation.targetColumns.joined(separator: ", "))). Actions are not specified."
    }

    static func read(_ url: URL, limit: Int) throws -> Data {
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= limit else { throw invalid("Input exceeds the size limit.") }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw invalid("Input exceeds the size limit.") }
        return data
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw invalid("Expected a JSON object.") }
        return object
    }
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return encoder
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func invalid(_ text: String) -> SchemaReviewError { .invalid(text) }

    private struct Fields {
        let values: [String: Any]
        init(_ values: [String: Any]) { self.values = values }
        func only(_ allowed: Set<String>) throws {
            let unknown = Set(values.keys).subtracting(allowed)
            guard unknown.isEmpty else { throw invalid("Unknown properties: \(unknown.sorted().joined(separator: ", ")).") }
        }
        func string(_ key: String, fallback: String? = nil, allowEmpty: Bool = false) throws -> String {
            if values[key] == nil, let fallback { return fallback }
            guard let value = values[key] as? String, allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw invalid("\(key) must be a\(allowEmpty ? "" : " nonempty") string.")
            }
            return value
        }
        func strings(_ key: String, fallback: [String]? = nil) throws -> [String] {
            if values[key] == nil, let fallback { return fallback }
            guard let value = values[key] as? [String], value.allSatisfy({ !$0.isEmpty }) else { throw invalid("\(key) must be an array of nonempty strings.") }
            return value
        }
        func boolean(_ key: String, fallback: Bool) throws -> Bool {
            guard let value = values[key] else { return fallback }
            guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(), let boolean = value as? Bool else { throw invalid("\(key) must be true or false.") }
            return boolean
        }
        func integer(_ key: String, fallback: Int) throws -> Int {
            guard let value = values[key] else { return fallback }
            guard CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID(), let number = value as? Int, number >= 0 else { throw invalid("\(key) must be a nonnegative integer.") }
            return number
        }
        func object(_ key: String) throws -> Fields {
            guard let value = values[key] as? [String: Any] else { throw invalid("\(key) must be an object.") }
            return Fields(value)
        }
    }
}
