import Foundation

/// Builds the interactive schema-review view that MCP Apps hosts show inside the
/// conversation. It reads a saved `.sgreview` comparison or `.sgpreview` proposal
/// directly, so showing a review needs no running app, database, or window.
///
/// The helper does not link StudioCore, so the change rules below mirror
/// `SchemaReviewDocument.changes` and `relationChanges` there. The parity test in
/// StudioAutomationTests keeps the two in step.
public enum SchemaReviewInlineView {
    public static let toolName = "studio_show_review_inline"

    static let maximumFileBytes = 64 * 1024 * 1024
    static let maximumChangedTables = 300
    /// Related unchanged tables are drawn only when a review has this few; beyond it
    /// (a change to a hub such as a users table) they are summarized per changed table.
    static let maximumDrawnContextTables = 12
    static let maximumListedLinks = 60
    /// Changed tables sharing an identical change (the same fields and references,
    /// typical of a migration applied across many tables) are grouped from this size.
    static let minimumGroupSize = 3
    static let maximumGroups = 20
    static let maximumColumnsPerTable = 60
    static let maximumContextColumns = 20
    static let maximumDefinitionCharacters = 500
    static let maximumSummaryNames = 20

    /// Returns an MCP CallToolResult. `content` is a short summary for the model;
    /// `structuredContent` carries the view data, which MCP Apps hosts hand to the
    /// view without adding it to the model's context.
    public static func result(path: String, workingDirectory: String) -> [String: Any] {
        do {
            let url = try resolve(path, workingDirectory: workingDirectory)
            let document = try load(url)
            let view = try build(document, path: url.path)
            return [
                "content": [["type": "text", "text": view.summary]],
                "structuredContent": view.model,
                "isError": false,
            ]
        } catch let error as InlineReviewError {
            return errorResult(error)
        } catch {
            return errorResult(.invalidArtifact("The review file could not be read: \(error.localizedDescription)"))
        }
    }

    // MARK: File access

    static func resolve(_ path: String, workingDirectory: String) throws -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : URL(fileURLWithPath: workingDirectory, isDirectory: true).appendingPathComponent(expanded)
        let standardized = url.standardizedFileURL
        guard ["sgreview", "sgpreview"].contains(standardized.pathExtension.lowercased()) else {
            throw InlineReviewError.invalidArgument(
                "Pass a .sgreview comparison or a .sgpreview proposal created with --schema-review."
            )
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            throw InlineReviewError.notFound("No review file exists at \(standardized.path).")
        }
        return standardized
    }

    static func load(_ url: URL) throws -> Document {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maximumFileBytes else {
            throw InlineReviewError.tooLarge("The review file exceeds 64 MB.")
        }
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        } catch {
            throw InlineReviewError.invalidArtifact("This is not a Graph Studio schema review or proposal file.")
        }
        try document.validate()
        return document
    }

    // MARK: File format (the parts of SchemaReviewDocument the view needs)

    struct Document: Decodable {
        var version: Int
        var title: String
        var baseRef: String
        var headRef: String
        var before: Snapshot
        var after: Snapshot
        var notes: [String]
        var proposal: Proposal?
        var author: Author?

        /// Presence marks a proposal. Its provenance fingerprint is verified when
        /// the app opens the file; the inline view only labels it as not applied.
        struct Proposal: Decodable {}

        struct Author: Decodable {
            var tool: String
            var session: String?

            var summary: String {
                let key = tool.lowercased().filter(\.isLetter)
                let name: String = switch key {
                case "claude", "claudecode", "anthropicclaude": "Claude"
                case "codex", "openaicodex", "codexcli": "Codex"
                case "opencode": "OpenCode"
                case "copilot", "githubcopilot", "vscodecopilot", "vscode", "copilotchat": "Copilot"
                default: tool
                }
                return ([name] + [session].compactMap { $0 }).joined(separator: " · ")
            }
        }

        func validate() throws {
            guard version == 1, before.engine == after.engine else {
                throw InlineReviewError.invalidArtifact("Compare snapshots of the same database engine.")
            }
            if let author {
                // Line breaks and direction overrides could misrepresent who wrote the review.
                let disallowed = CharacterSet(charactersIn: "\u{2028}\u{2029}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")
                func isPlainLine(_ value: String, limit: Int) -> Bool {
                    !value.isEmpty && value.count <= limit && !value.unicodeScalars.contains {
                        $0.properties.generalCategory == .control || disallowed.contains($0)
                    }
                }
                guard isPlainLine(author.tool, limit: 64), author.session.map({ isPlainLine($0, limit: 200) }) ?? true else {
                    throw InlineReviewError.invalidArtifact("The review's author label is not a plain single line.")
                }
            }
            try before.validate()
            try after.validate()
            let graphIDs = SchemaReviewInlineView.relationChanges(self).map(\.graphID)
            guard Set(graphIDs).count == graphIDs.count else {
                throw InlineReviewError.invalidArtifact("Conflicting relation identities in the comparison.")
            }
        }
    }

    struct Snapshot: Decodable {
        var version: Int
        var engine: String
        var tables: [Table]
        var relations: [Relation]

        func validate() throws {
            guard version == 1, ["sqlite", "postgresql"].contains(engine), tables.count <= 20_000,
                  Set(tables.map(\.id)).count == tables.count, Set(relations.map(\.id)).count == relations.count
            else {
                throw InlineReviewError.invalidArtifact("Unsupported or duplicate schema objects.")
            }
            let lookup = Dictionary(uniqueKeysWithValues: tables.map { ($0.id, $0) })
            for table in tables {
                guard !table.id.isEmpty, !table.name.isEmpty, table.columns.count <= 10_000,
                      Set(table.columns.map(\.name)).count == table.columns.count,
                      table.columns.allSatisfy({ !$0.name.isEmpty && $0.primaryKeyOrdinal >= 0 })
                else {
                    throw InlineReviewError.invalidArtifact("Invalid fields in \(table.id).")
                }
            }
            for relation in relations {
                guard !relation.id.isEmpty, let source = lookup[relation.source], let target = lookup[relation.target],
                      !relation.sourceColumns.isEmpty, relation.sourceColumns.count == relation.targetColumns.count,
                      relation.sourceColumns.allSatisfy({ name in source.columns.contains { $0.name == name } }),
                      relation.targetColumns.allSatisfy({ name in target.columns.contains { $0.name == name } })
                else {
                    throw InlineReviewError.invalidArtifact("Incomplete relation \(relation.id).")
                }
            }
        }
    }

    struct Table: Decodable, Equatable {
        var id: String
        var schema: String?
        var name: String
        var kind: String
        var columns: [Column]
        var metadata: [String: String]

        var displayName: String { schema == "public" ? name : id }
    }

    struct Column: Decodable, Equatable {
        var name: String
        var type: String
        var notNull: Bool
        var defaultSQL: String?
        var primaryKeyOrdinal: Int
        var generated: Int
        var identity: String

        var description: String {
            ([type, notNull ? "NOT NULL" : "NULL"] + (defaultSQL.map { ["DEFAULT " + $0] } ?? [])
             + (primaryKeyOrdinal > 0 ? ["PK \(primaryKeyOrdinal)"] : [])
             + (generated != 0 ? ["GENERATED"] : []) + (identity.isEmpty ? [] : ["IDENTITY " + identity]))
                .joined(separator: " · ")
        }
    }

    struct Relation: Decodable, Equatable {
        var id: String
        var source: String
        var target: String
        var sourceColumns: [String]
        var targetColumns: [String]
        var definition: String
    }

    // MARK: Change rules (mirror of StudioCore's SchemaReviewDocument)

    enum ChangeKind: String {
        case unchanged, added, removed, modified

        var label: String {
            switch self { case .unchanged: "Unchanged"; case .added: "New"; case .removed: "Removed"; case .modified: "Changed" }
        }
    }

    struct RelationChange {
        let relation: Relation
        let kind: ChangeKind
        let graphID: String
    }

    struct TableChange {
        let id: String
        let before: Table?
        let after: Table?
        let relationChanged: Bool

        var table: Table { after ?? before! }
        var added: [Column] { after?.columns.filter { column in !(before?.columns.contains { $0.name == column.name } ?? false) } ?? [] }
        var removed: [Column] { before?.columns.filter { column in !(after?.columns.contains { $0.name == column.name } ?? false) } ?? [] }
        var modified: [Column] { after?.columns.filter { column in before?.columns.first { $0.name == column.name }.map { $0 != column } ?? false } ?? [] }
        var kind: ChangeKind {
            before == nil ? .added : after == nil ? .removed : before != after || relationChanged ? .modified : .unchanged
        }
        var badge: String {
            if kind == .added || kind == .removed { return kind.label }
            return ([added.isEmpty ? nil : "+\(added.count)", removed.isEmpty ? nil : "−\(removed.count)",
                     modified.isEmpty ? nil : "~\(modified.count)", relationChanged ? "↔" : nil].compactMap { $0 })
                .joined(separator: " ")
        }
        func columnKind(_ name: String) -> ChangeKind {
            if added.contains(where: { $0.name == name }) { return .added }
            if removed.contains(where: { $0.name == name }) { return .removed }
            if modified.contains(where: { $0.name == name }) { return .modified }
            return .unchanged
        }
        /// The current fields followed by removed ones, as the app shows them.
        var unionColumns: [Column] { after == nil ? table.columns : table.columns + removed }
    }

    static func relationChanges(_ document: Document) -> [RelationChange] {
        let old = Dictionary(document.before.relations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let new = Dictionary(document.after.relations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(old.keys).union(new.keys).sorted().flatMap { id -> [RelationChange] in
            if let a = old[id], let b = new[id] {
                if a == b { return [.init(relation: b, kind: .unchanged, graphID: id)] }
                return [.init(relation: a, kind: .removed, graphID: "before:" + id),
                        .init(relation: b, kind: .added, graphID: "after:" + id)]
            }
            return [.init(relation: new[id] ?? old[id]!, kind: new[id] == nil ? .removed : .added, graphID: id)]
        }
    }

    static func tableChanges(_ document: Document, relationChanges: [RelationChange]) -> [TableChange] {
        let old = Dictionary(uniqueKeysWithValues: document.before.tables.map { ($0.id, $0) })
        let new = Dictionary(uniqueKeysWithValues: document.after.tables.map { ($0.id, $0) })
        let touched = Set(relationChanges.filter { $0.kind != .unchanged }.flatMap { [$0.relation.source, $0.relation.target] })
        return Set(old.keys).union(new.keys).sorted().map {
            TableChange(id: $0, before: old[$0], after: new[$0], relationChanged: touched.contains($0))
        }
    }

    // MARK: View data

    struct View {
        let model: [String: Any]
        let summary: String
    }

    static func build(_ document: Document, path: String) throws -> View {
        let relations = relationChanges(document)
        let changes = tableChanges(document, relationChanges: relations)
        let changed = changes.filter { $0.kind != .unchanged }
        let shownChanged = Array(changed.prefix(maximumChangedTables))
        let shownChangedIDs = Set(shownChanged.map(\.id))
        let unchangedByID = Dictionary(uniqueKeysWithValues: changes.filter { $0.kind == .unchanged }.map { ($0.id, $0) })

        // Unchanged tables linked to a shown change. A few of them orient the reader,
        // but a hub (a users table referenced from every feature) would bury the
        // changes, so beyond a handful they are summarized on each changed table.
        var links: [String: [Link]] = [:]
        var contextIDs = Set<String>()
        for change in relations where change.kind == .unchanged {
            let relation = change.relation
            for (near, far, referencedByFar) in [(relation.target, relation.source, true), (relation.source, relation.target, false)]
            where shownChangedIDs.contains(near) && unchangedByID[far] != nil {
                links[near, default: []].append(Link(table: far, referencedByTable: referencedByFar,
                                                     columns: referencedByFar ? relation.sourceColumns : relation.targetColumns))
                contextIDs.insert(far)
            }
        }
        let drawContext = contextIDs.count <= maximumDrawnContextTables
        let shownContext = drawContext ? contextIDs.sorted().compactMap { unchangedByID[$0] } : []
        let shownIDs = shownChangedIDs.union(shownContext.map(\.id))

        let tables = shownChanged.map { change in
            var model = tableModel(change, context: false)
            model["unchangedLinks"] = linksModel(links[change.id] ?? [], drawn: drawContext, names: unchangedByID)
            return model
        } + shownContext.map { tableModel($0, context: true) }
        let shownRelations = relations.filter { shownIDs.contains($0.relation.source) && shownIDs.contains($0.relation.target) }
        let relationModels: [[String: Any]] = shownRelations.map { change in
            [
                "id": change.graphID,
                "source": change.relation.source,
                "target": change.relation.target,
                "sourceColumns": change.relation.sourceColumns,
                "targetColumns": change.relation.targetColumns,
                "kind": change.kind.rawValue,
                "definition": truncated(change.relation.definition),
            ]
        }

        let groups = changeGroups(changed, relations: relations)
        let addedCount = changed.filter { $0.kind == .added }.count
        let removedCount = changed.filter { $0.kind == .removed }.count
        let modifiedCount = changed.filter { $0.kind == .modified }.count
        let unchangedCount = changes.count - changed.count
        let relationsAdded = relations.filter { $0.kind == .added }.count
        let relationsRemoved = relations.filter { $0.kind == .removed }.count
        let isProposal = document.proposal != nil

        let model: [String: Any] = [
            "format": "sqlite-graph-studio/schema-review-view",
            "version": 1,
            "artifact": isProposal ? "proposal" : "comparison",
            "title": document.title,
            "baseRef": document.baseRef,
            "headRef": document.headRef,
            "engine": document.after.engine,
            "notes": Array(document.notes.prefix(20)),
            "author": document.author.map { $0.summary as Any } ?? NSNull(),
            "path": path,
            "summary": [
                "addedTables": addedCount,
                "removedTables": removedCount,
                "modifiedTables": modifiedCount,
                "unchangedTables": unchangedCount,
                "addedRelations": relationsAdded,
                "removedRelations": relationsRemoved,
            ],
            "tables": tables,
            "relations": relationModels,
            "changeGroups": groups.map { ["summary": $0.summary, "tables": $0.tables, "count": $0.tables.count] as [String: Any] },
            "omitted": [
                "changedTables": changed.count - shownChanged.count,
                "relatedTables": drawContext ? 0 : contextIDs.count,
            ],
        ]
        return View(model: model, summary: summaryText(document, changed: changed, unchanged: unchangedCount,
                                                         relationsAdded: relationsAdded, relationsRemoved: relationsRemoved,
                                                         summarizedRelated: drawContext ? 0 : contextIDs.count, groups: groups))
    }

    struct ChangeGroup {
        let summary: String
        let tables: [String]
    }

    /// Groups modified tables whose field and reference changes are identical, such as
    /// `+ updated_by_user_id bigint · + → app_user` added to thirty tables at once.
    static func changeGroups(_ changed: [TableChange], relations: [RelationChange]) -> [ChangeGroup] {
        let names = Dictionary(changed.map { ($0.id, $0.table.displayName) }, uniquingKeysWith: { first, _ in first })
        var byRelationTable: [String: [RelationChange]] = [:]
        for change in relations where change.kind != .unchanged {
            byRelationTable[change.relation.source, default: []].append(change)
            if change.relation.target != change.relation.source {
                byRelationTable[change.relation.target, default: []].append(change)
            }
        }
        var members: [String: [String]] = [:]
        var order: [String] = []
        for change in changed where change.kind == .modified {
            var parts = change.added.map { "+ \($0.name) \($0.type)" }
                + change.removed.map { "− \($0.name)" }
                + change.modified.map { "~ \($0.name)" }
            for relation in byRelationTable[change.id] ?? [] {
                let outgoing = relation.relation.source == change.id
                let other = outgoing ? relation.relation.target : relation.relation.source
                let label = names[other] ?? other
                parts.append("\(relation.kind == .added ? "+" : "−") \(outgoing ? "→" : "←") \(label)")
            }
            if let before = change.before, let after = change.after, before.metadata != after.metadata {
                parts.append("~ definitions")
            }
            guard !parts.isEmpty else { continue }
            let signature = parts.sorted().joined(separator: " · ")
            if members[signature] == nil { order.append(signature) }
            members[signature, default: []].append(change.id)
        }
        return order.compactMap { signature in
            guard let tables = members[signature], tables.count >= minimumGroupSize else { return nil }
            return ChangeGroup(summary: signature, tables: tables)
        }
        .sorted { $0.tables.count != $1.tables.count ? $0.tables.count > $1.tables.count : $0.tables[0] < $1.tables[0] }
        .prefix(maximumGroups)
        .map { $0 }
    }

    /// One unchanged relation between a changed table and an unchanged one.
    struct Link {
        let table: String
        /// True when the unchanged table's foreign key points at the changed table.
        let referencedByTable: Bool
        let columns: [String]
    }

    private static func linksModel(_ links: [Link], drawn: Bool, names: [String: TableChange]) -> [String: Any] {
        let sorted = links.sorted { ($0.table, $0.columns.joined(separator: ",")) < ($1.table, $1.columns.joined(separator: ",")) }
        let items: [[String: Any]] = sorted.prefix(maximumListedLinks).map { link in
            [
                "table": link.table,
                "name": names[link.table]?.table.displayName ?? link.table,
                "direction": link.referencedByTable ? "referencedBy" : "references",
                "columns": link.columns,
            ]
        }
        return [
            "relations": links.count,
            "tables": Set(links.map(\.table)).count,
            "drawn": drawn,
            "items": items,
            "more": max(0, links.count - maximumListedLinks),
        ]
    }

    private static func tableModel(_ change: TableChange, context: Bool) -> [String: Any] {
        let columns = change.unionColumns
        let limit = context ? maximumContextColumns : maximumColumnsPerTable
        var shown: [Column]
        if columns.count <= limit {
            shown = columns
        } else {
            // Every changed field stays visible; unchanged ones fill the rest in order.
            let changedNames = Set(columns.filter { change.columnKind($0.name) != .unchanged }.map(\.name))
            var remaining = max(0, limit - changedNames.count)
            shown = columns.filter { column in
                if changedNames.contains(column.name) { return true }
                guard remaining > 0 else { return false }
                remaining -= 1
                return true
            }
        }
        let beforeColumns = Dictionary(uniqueKeysWithValues: (change.before?.columns ?? []).map { ($0.name, $0) })
        let columnModels: [[String: Any]] = shown.map { column in
            let kind = change.columnKind(column.name)
            var model: [String: Any] = [
                "name": column.name,
                "description": column.description,
                "kind": kind.rawValue,
                "primaryKey": column.primaryKeyOrdinal > 0,
            ]
            if kind == .modified, let previous = beforeColumns[column.name] {
                model["before"] = previous.description
            }
            return model
        }
        return [
            "id": change.id,
            "name": change.table.displayName,
            "objectKind": change.table.kind,
            "kind": change.kind.rawValue,
            "badge": change.badge,
            "context": context,
            "columns": columnModels,
            "hiddenColumns": columns.count - shown.count,
            "definitionChanges": definitionChanges(change),
        ]
    }

    /// Constraint, index, trigger and option definitions that differ.
    private static func definitionChanges(_ change: TableChange) -> [[String: Any]] {
        guard let before = change.before, let after = change.after, before.metadata != after.metadata else { return [] }
        return Set(before.metadata.keys).union(after.metadata.keys).sorted().compactMap { key in
            let label = definitionLabel(key)
            switch (before.metadata[key], after.metadata[key]) {
            case (nil, let added?):
                return ["key": key, "label": label, "kind": ChangeKind.added.rawValue, "after": truncated(added)]
            case (let removed?, nil):
                return ["key": key, "label": label, "kind": ChangeKind.removed.rawValue, "before": truncated(removed)]
            case (let old?, let new?) where old != new:
                return ["key": key, "label": label, "kind": ChangeKind.modified.rawValue, "before": truncated(old), "after": truncated(new)]
            default: return nil
            }
        }
    }

    /// `index:users_email` reads as "Index users_email". Unnamed constraints are
    /// keyed by a content hash, which says nothing to a reader, so only the
    /// category is shown for those.
    static func definitionLabel(_ key: String) -> String {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        let category = parts.first ?? key
        let name = parts.count > 1 ? parts[1] : ""
        let title: String = switch category {
        case "definition": "Table definition"
        case "index": "Index"
        case "constraint": "Constraint"
        case "trigger": "Trigger"
        default: category.prefix(1).uppercased() + category.dropFirst()
        }
        let isHash = name.count == 64 && name.allSatisfy(\.isHexDigit)
        return name.isEmpty || isHash ? title : "\(title) \(name)"
    }

    private static func summaryText(_ document: Document, changed: [TableChange], unchanged: Int,
                                    relationsAdded: Int, relationsRemoved: Int, summarizedRelated: Int,
                                    groups: [ChangeGroup]) -> String {
        let isProposal = document.proposal != nil
        let heading = isProposal
            ? "Proposed schema changes \"\(document.title)\" are shown inline (not applied; based on \(document.baseRef))."
            : "Schema review \"\(document.title)\" is shown inline (\(document.baseRef) → \(document.headRef))."
        guard !changed.isEmpty || relationsAdded + relationsRemoved > 0 else {
            return heading + " No table, field, or relation changes. \(unchanged) tables unchanged."
        }
        func count(_ kind: ChangeKind) -> Int { changed.filter { $0.kind == kind }.count }
        var lines = [heading,
                     "\(changed.count) changed tables: \(count(.added)) new, \(count(.removed)) removed, \(count(.modified)) changed; "
                        + "\(relationsAdded) relations added, \(relationsRemoved) removed; \(unchanged) tables unchanged."]
        for group in groups.prefix(2) {
            lines.append("\(group.tables.count) tables share one change: \(group.summary).")
        }
        let names = changed.prefix(maximumSummaryNames).map { "\($0.table.displayName) (\($0.badge))" }
        let more = changed.count > maximumSummaryNames ? ", and \(changed.count - maximumSummaryNames) more" : ""
        lines.append("Changed: " + names.joined(separator: ", ") + more + ".")
        if summarizedRelated > 0 {
            lines.append("\(summarizedRelated) related unchanged tables are summarized on the changed tables rather than drawn.")
        }
        if let author = document.author { lines.append("Author: \(author.summary).") }
        lines.append("Schema evidence only; it does not approve a merge or show data effects.")
        return lines.joined(separator: " ")
    }

    private static func truncated(_ value: String) -> String {
        value.count <= maximumDefinitionCharacters ? value : String(value.prefix(maximumDefinitionCharacters)) + "…"
    }

    // MARK: Errors

    enum InlineReviewError: Error {
        case invalidArgument(String)
        case notFound(String)
        case tooLarge(String)
        case invalidArtifact(String)

        var code: String {
            switch self {
            case .invalidArgument: "INVALID_ARGUMENT"
            case .notFound: "OBJECT_NOT_FOUND"
            case .tooLarge: "LIMIT_REACHED"
            case .invalidArtifact: "INVALID_ARTIFACT"
            }
        }

        var message: String {
            switch self {
            case .invalidArgument(let message), .notFound(let message), .tooLarge(let message), .invalidArtifact(let message):
                message
            }
        }
    }

    private static func errorResult(_ error: InlineReviewError) -> [String: Any] {
        [
            "content": [["type": "text", "text": error.message]],
            "structuredContent": ["error": ["code": error.code, "message": error.message]],
            "isError": true,
        ]
    }
}
