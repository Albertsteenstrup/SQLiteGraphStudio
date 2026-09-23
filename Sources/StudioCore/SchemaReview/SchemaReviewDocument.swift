import Foundation
import CryptoKit

/// Portable schema evidence. No rows, connection settings, or credentials belong here.
public struct SchemaReviewSnapshot: Codable, Sendable, Equatable {
    public var version = 1
    public var engine: String
    public var tables: [Table]
    public var relations: [Relation]

    public struct Column: Codable, Sendable, Equatable, Identifiable {
        public var name: String
        public var type: String
        public var notNull: Bool
        public var defaultSQL: String?
        public var primaryKeyOrdinal: Int
        public var generated: Int
        public var identity: String
        public var id: String { name }
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

    static func token(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.map { "\($0.utf8.count):\($0)" }.joined().utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum SchemaReviewError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

/// Agent tools whose reviews carry their own mark in the review header.
public enum SchemaReviewAgent: String, CaseIterable, Sendable {
    case claude, codex, opencode, copilot

    public init?(identifier: String) {
        let key = identifier.lowercased().filter { $0.isLetter }
        switch key {
        case "claude", "claudecode", "anthropicclaude": self = .claude
        case "codex", "openaicodex", "codexcli": self = .codex
        case "opencode": self = .opencode
        case "copilot", "githubcopilot", "vscodecopilot", "vscode", "copilotchat": self = .copilot
        default: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .copilot: "Copilot"
        }
    }
}

public enum SchemaChangeKind: String, Sendable, Codable {
    case unchanged, added, removed, modified
    public var label: String {
        switch self { case .unchanged: "Unchanged"; case .added: "New"; case .removed: "Removed"; case .modified: "Changed" }
    }
}

public struct SchemaTableChange: Sendable, Identifiable {
    public let id: String
    public let before: SchemaReviewSnapshot.Table?
    public let after: SchemaReviewSnapshot.Table?
    public let relationChanged: Bool
    public var table: SchemaReviewSnapshot.Table { after ?? before! }
    public var added: [SchemaReviewSnapshot.Column] { after?.columns.filter { column in !(before?.columns.contains { $0.name == column.name } ?? false) } ?? [] }
    public var removed: [SchemaReviewSnapshot.Column] { before?.columns.filter { column in !(after?.columns.contains { $0.name == column.name } ?? false) } ?? [] }
    public var modified: [SchemaReviewSnapshot.Column] { after?.columns.filter { column in before?.columns.first { $0.name == column.name }.map { $0 != column } ?? false } ?? [] }
    public var kind: SchemaChangeKind {
        before == nil ? .added : after == nil ? .removed : before != after || relationChanged ? .modified : .unchanged
    }
    public var badge: String {
        if kind == .added || kind == .removed { return kind.label }
        return ([added.isEmpty ? nil : "+\(added.count)", removed.isEmpty ? nil : "−\(removed.count)",
                 modified.isEmpty ? nil : "~\(modified.count)", relationChanged ? "↔" : nil].compactMap { $0 }).joined(separator: " ")
    }
    public func columnKind(_ name: String) -> SchemaChangeKind {
        if added.contains(where: { $0.name == name }) { return .added }
        if removed.contains(where: { $0.name == name }) { return .removed }
        if modified.contains(where: { $0.name == name }) { return .modified }
        return .unchanged
    }
    var unionTable: SchemaReviewSnapshot.Table {
        var value = table
        if after != nil { value.columns += removed }
        return value
    }
}

public struct SchemaReviewDocument: Codable, Sendable {
    public var version = 1
    public var title: String
    public var baseRef: String
    public var headRef: String
    public var before: SchemaReviewSnapshot
    public var after: SchemaReviewSnapshot
    public var notes: [String]
    public struct Proposal: Codable, Sendable {
        public var baseFingerprint: String
        public var planFingerprint: String
    }
    public var proposal: Proposal?
    /// The agent that produced the document, when it is allowed to say. Display only:
    /// it identifies which tool and session a review came from, never who approved it.
    public var author: Author?

    public struct Author: Codable, Sendable, Equatable {
        /// A known agent's identifier (`claude`, `codex`, `opencode`, `copilot`) or
        /// another tool's own name.
        public var tool: String
        /// The human-readable name of the chat or session that produced the document.
        public var session: String?

        /// Normalises the spellings agents are likely to pass (`Claude Code`,
        /// `openai-codex`, `vscode-copilot`) and drops empty values.
        public init?(tool: String?, session: String?) {
            guard let tool = tool?.trimmingCharacters(in: .whitespacesAndNewlines), !tool.isEmpty else { return nil }
            self.tool = SchemaReviewAgent(identifier: tool)?.rawValue ?? tool
            let session = session?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.session = session?.isEmpty == false ? session : nil
        }

        public var agent: SchemaReviewAgent? { SchemaReviewAgent(identifier: tool) }
        public var toolName: String { agent?.displayName ?? tool }
        /// `Claude · Table diff visualization clarity`
        public var summary: String { ([toolName] + [session].compactMap { $0 }).joined(separator: " · ") }

        func validate() throws {
            func isPlainLine(_ value: String, limit: Int) -> Bool {
                !value.isEmpty && value.count <= limit && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            }
            guard isPlainLine(tool, limit: 64), session.map({ isPlainLine($0, limit: 200) }) ?? true else {
                throw SchemaReviewError.invalid("The author must be a single-line tool name (64 characters) and session name (200 characters).")
            }
        }
    }

    public init(title: String, baseRef: String, headRef: String, before: SchemaReviewSnapshot, after: SchemaReviewSnapshot, notes: [String] = [], proposal: Proposal? = nil, author: Author? = nil) {
        self.title = title; self.baseRef = baseRef; self.headRef = headRef
        self.before = before; self.after = after; self.notes = notes; self.proposal = proposal; self.author = author
    }
    public func validate() throws {
        guard version == 1, before.engine == after.engine else { throw SchemaReviewError.invalid("Compare snapshots of the same database engine.") }
        try author?.validate()
        try before.validate(); try after.validate()
        if let proposal {
            guard proposal.baseFingerprint == (try SchemaPreview.fingerprint(before)),
                  proposal.planFingerprint.count == 64,
                  proposal.planFingerprint.allSatisfy({ $0.isHexDigit }) else {
                throw SchemaReviewError.invalid("Invalid proposal provenance.")
            }
        }
        let graphIDs = relationChanges.map(\.graphID)
        guard Set(graphIDs).count == graphIDs.count else {
            throw SchemaReviewError.invalid("Conflicting relation identities in the comparison.")
        }
    }
    public static func load(_ url: URL) throws -> Self {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 64 * 1024 * 1024 else { throw SchemaReviewError.invalid("Schema comparison exceeds 64 MB.") }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try value.validate()
        return value
    }
    public var changes: [SchemaTableChange] {
        let old = Dictionary(uniqueKeysWithValues: before.tables.map { ($0.id, $0) })
        let new = Dictionary(uniqueKeysWithValues: after.tables.map { ($0.id, $0) })
        let changedRelations = relationChanges.filter { $0.kind != .unchanged }
        let touched = Set(changedRelations.flatMap { [$0.relation.source, $0.relation.target] })
        return Set(old.keys).union(new.keys).sorted().map { SchemaTableChange(id: $0, before: old[$0], after: new[$0], relationChanged: touched.contains($0)) }
    }
    public struct RelationChange: Sendable {
        public let relation: SchemaReviewSnapshot.Relation
        public let kind: SchemaChangeKind
        public let graphID: String
    }
    public var relationChanges: [RelationChange] {
        let old = Dictionary(uniqueKeysWithValues: before.relations.map { ($0.id, $0) })
        let new = Dictionary(uniqueKeysWithValues: after.relations.map { ($0.id, $0) })
        return Set(old.keys).union(new.keys).sorted().flatMap { id -> [RelationChange] in
            if let a = old[id], let b = new[id] {
                if a == b { return [.init(relation: b, kind: .unchanged, graphID: id)] }
                return [.init(relation: a, kind: .removed, graphID: "before:" + id), .init(relation: b, kind: .added, graphID: "after:" + id)]
            }
            return [.init(relation: new[id] ?? old[id]!, kind: new[id] == nil ? .removed : .added, graphID: id)]
        }
    }
    var graph: SchemaGraph {
        SchemaGraph(nodes: changes.map { GraphNode(id: $0.id, title: $0.table.displayName, isEditable: false) },
                    edges: relationChanges.flatMap { change in change.relation.sourceColumns.indices.map { index in
                        GraphEdge(id: change.graphID + ":\(index)", sourceID: change.relation.source, targetID: change.relation.target,
                                  sourceColumn: change.relation.sourceColumns[index], targetColumn: change.relation.targetColumns[index])
                    } })
    }
    public func write(to url: URL) throws {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
