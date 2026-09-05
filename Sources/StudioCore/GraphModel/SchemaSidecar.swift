import Foundation

/// AI-authored metadata that lives next to a `.sqlite` file as `<name>.sqlite.studio.json`.
///
/// The `graph-clusters` skill populates `clusters` so the physics engine groups related tables
/// together by the user's chosen lens. The `schema-descriptions` skill populates `tables`
/// so table and column descriptions stay easy to edit without rewriting SQLite DDL. The
/// `story-flows` skill populates `stories` so authored application flows can play back on
/// the schema graph.
public struct SchemaSidecar: Codable, Sendable, Hashable {
    public var version: Int
    public var clusters: [ClusterHint]
    public var tables: [String: TableDescription]
    public var stories: [Story]
    public var recordGraphMappings: [RecordGraphMapping]

    public init(
        version: Int = 1,
        clusters: [ClusterHint] = [],
        tables: [String: TableDescription] = [:],
        stories: [Story] = [],
        recordGraphMappings: [RecordGraphMapping] = []
    ) {
        self.version = version
        self.clusters = clusters
        self.tables = tables
        self.stories = stories
        self.recordGraphMappings = recordGraphMappings
    }

    public static let empty = SchemaSidecar()

    private enum CodingKeys: String, CodingKey {
        case version
        case clusters
        case tables
        case stories
        case recordGraphMappings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        clusters = try container.decodeIfPresent([ClusterHint].self, forKey: .clusters) ?? []
        tables = try container.decodeIfPresent([String: TableDescription].self, forKey: .tables) ?? [:]
        stories = try container.decodeIfPresent([Story].self, forKey: .stories) ?? []
        recordGraphMappings = try container.decodeIfPresent([RecordGraphMapping].self, forKey: .recordGraphMappings) ?? []
    }

    public struct ClusterHint: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var label: String?
        public var tables: [String]
        public var color: String?

        public init(id: String, label: String? = nil, tables: [String], color: String? = nil) {
            self.id = id
            self.label = label
            self.tables = tables
            self.color = color
        }
    }

    public struct TableDescription: Codable, Sendable, Hashable {
        public var description: String?
        public var columns: [String: String]

        public init(description: String? = nil, columns: [String: String] = [:]) {
            self.description = description
            self.columns = columns
        }

        private enum CodingKeys: String, CodingKey {
            case description
            case columns
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            columns = try container.decodeIfPresent([String: String].self, forKey: .columns) ?? [:]
        }
    }

    public struct Story: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public var createdAt: String
        public var prompt: String?
        public var actor: String?
        public var goal: String?
        public var benefit: String?
        public var clusters: [String]
        public var relatedStories: [StoryRelation]
        public var conversation: [String]
        public var acceptanceCriteria: [AcceptanceCriterion]
        public var playback: [StoryPlaybackStep]

        public init(
            id: String,
            title: String,
            createdAt: String,
            prompt: String? = nil,
            actor: String? = nil,
            goal: String? = nil,
            benefit: String? = nil,
            clusters: [String] = [],
            relatedStories: [StoryRelation] = [],
            conversation: [String] = [],
            acceptanceCriteria: [AcceptanceCriterion] = [],
            playback: [StoryPlaybackStep]
        ) {
            self.id = id
            self.title = title
            self.createdAt = createdAt
            self.prompt = prompt
            self.actor = actor
            self.goal = goal
            self.benefit = benefit
            self.clusters = clusters
            self.relatedStories = relatedStories
            self.conversation = conversation
            self.acceptanceCriteria = acceptanceCriteria
            self.playback = playback
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case title
            case createdAt = "created_at"
            case prompt
            case actor
            case goal
            case benefit
            case clusters
            case relatedStories = "related_stories"
            case conversation
            case acceptanceCriteria = "acceptance_criteria"
            case playback
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Untitled Story"
            createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
            prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
            actor = try container.decodeIfPresent(String.self, forKey: .actor)
            goal = try container.decodeIfPresent(String.self, forKey: .goal)
            benefit = try container.decodeIfPresent(String.self, forKey: .benefit)
            clusters = try container.decodeIfPresent([String].self, forKey: .clusters) ?? []
            relatedStories = try container.decodeIfPresent([StoryRelation].self, forKey: .relatedStories) ?? []
            conversation = try container.decodeIfPresent([String].self, forKey: .conversation) ?? []
            acceptanceCriteria = try container.decodeIfPresent([AcceptanceCriterion].self, forKey: .acceptanceCriteria) ?? []
            playback = try container.decodeIfPresent([StoryPlaybackStep].self, forKey: .playback) ?? []
        }

        public var userStoryText: String? {
            guard let actor = actor?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let goal = goal?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let benefit = benefit?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !actor.isEmpty,
                  !goal.isEmpty,
                  !benefit.isEmpty
            else {
                return nil
            }
            return "As \(actor), I want \(goal), so that \(benefit)."
        }

        public var coveredTableIDs: [String] {
            var ordered: [String] = []
            var seen: Set<String> = []

            func append(_ tableID: String?) {
                guard let tableID = tableID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !tableID.isEmpty,
                      !seen.contains(tableID)
                else {
                    return
                }
                seen.insert(tableID)
                ordered.append(tableID)
            }

            for beat in playback {
                append(beat.focus)
                append(beat.expand)
                append(beat.relation?.table)
                for table in beat.tables {
                    append(table)
                }
            }

            return ordered
        }

        public var primaryTableIDs: [String] {
            var ordered: [String] = []
            var seen: Set<String> = []

            func append(_ tableID: String?) {
                guard let tableID = tableID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !tableID.isEmpty,
                      !seen.contains(tableID)
                else {
                    return
                }
                seen.insert(tableID)
                ordered.append(tableID)
            }

            for beat in playback {
                append(beat.focus)
                append(beat.expand)
                append(beat.relation?.table)
            }

            if ordered.isEmpty {
                return Array(coveredTableIDs.prefix(3))
            }

            return ordered
        }
    }

    public struct StoryRelation: Codable, Sendable, Hashable, Identifiable {
        public var storyID: String
        public var kind: String
        public var note: String?

        public var id: String {
            "\(storyID)|\(kind)|\(note ?? "")"
        }

        public init(storyID: String, kind: String = "related", note: String? = nil) {
            self.storyID = storyID
            self.kind = kind
            self.note = note
        }

        private enum CodingKeys: String, CodingKey {
            case storyID = "story_id"
            case kind
            case note
        }

        public init(from decoder: Decoder) throws {
            let singleValueContainer = try decoder.singleValueContainer()
            if let storyID = try? singleValueContainer.decode(String.self) {
                self.storyID = storyID
                kind = "related"
                note = nil
                return
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            storyID = try container.decodeIfPresent(String.self, forKey: .storyID) ?? ""
            kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "related"
            note = try container.decodeIfPresent(String.self, forKey: .note)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(storyID, forKey: .storyID)
            try container.encode(kind, forKey: .kind)
            try container.encodeIfPresent(note, forKey: .note)
        }
    }

    public struct AcceptanceCriterion: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var text: String?
        public var given: String?
        public var when: String?
        public var then: String?

        public init(
            id: String,
            text: String? = nil,
            given: String? = nil,
            when: String? = nil,
            then: String? = nil
        ) {
            self.id = id
            self.text = text
            self.given = given
            self.when = when
            self.then = then
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case text
            case given
            case when
            case then
        }

        public init(from decoder: Decoder) throws {
            let singleValueContainer = try decoder.singleValueContainer()
            if let text = try? singleValueContainer.decode(String.self) {
                id = UUID().uuidString
                self.text = text
                given = nil
                when = nil
                then = nil
                return
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
            text = try container.decodeIfPresent(String.self, forKey: .text)
            given = try container.decodeIfPresent(String.self, forKey: .given)
            when = try container.decodeIfPresent(String.self, forKey: .when)
            then = try container.decodeIfPresent(String.self, forKey: .then)
        }

        public var displayText: String {
            if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }

            let parts = [
                given.map { "Given \($0)" },
                when.map { "when \($0)" },
                then.map { "then \($0)" },
            ].compactMap { part -> String? in
                guard let part = part?.trimmingCharacters(in: .whitespacesAndNewlines), !part.isEmpty else { return nil }
                return part
            }

            return parts.joined(separator: ", ")
        }
    }

    public struct StoryPlaybackStep: Codable, Sendable, Hashable {
        public var text: String
        public var spokenText: String?
        public var tables: [String]
        public var focus: String?
        public var expand: String?
        public var relation: StoryColumnReference?
        public var durationMilliseconds: Int?

        public init(
            text: String,
            spokenText: String? = nil,
            tables: [String],
            focus: String? = nil,
            expand: String? = nil,
            relation: StoryColumnReference? = nil,
            durationMilliseconds: Int? = nil
        ) {
            self.text = text
            self.spokenText = spokenText
            self.tables = tables
            self.focus = focus
            self.expand = expand
            self.relation = relation
            self.durationMilliseconds = durationMilliseconds
        }

        private enum CodingKeys: String, CodingKey {
            case text
            case spokenText = "spoken_text"
            case humanText = "human_text"
            case tables
            case focus
            case expand
            case relation
            case durationMilliseconds = "duration_ms"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
            spokenText = try container.decodeIfPresent(String.self, forKey: .spokenText)
                ?? container.decodeIfPresent(String.self, forKey: .humanText)
            tables = try container.decodeIfPresent([String].self, forKey: .tables) ?? []
            focus = try container.decodeIfPresent(String.self, forKey: .focus)
            expand = try container.decodeIfPresent(String.self, forKey: .expand)
            relation = try container.decodeIfPresent(StoryColumnReference.self, forKey: .relation)
            durationMilliseconds = try container.decodeIfPresent(Int.self, forKey: .durationMilliseconds)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(spokenText, forKey: .spokenText)
            try container.encode(tables, forKey: .tables)
            try container.encodeIfPresent(focus, forKey: .focus)
            try container.encodeIfPresent(expand, forKey: .expand)
            try container.encodeIfPresent(relation, forKey: .relation)
            try container.encodeIfPresent(durationMilliseconds, forKey: .durationMilliseconds)
        }
    }

    public struct StoryColumnReference: Codable, Sendable, Hashable {
        public var table: String
        public var column: String

        public init(table: String, column: String) {
            self.table = table
            self.column = column
        }
    }

    /// Returns `nodeID -> clusterGroupID` for every table named in a cluster hint.
    public var nodeToClusterGroup: [String: String] {
        var map: [String: String] = [:]
        for cluster in clusters {
            for table in cluster.tables where map[table] == nil {
                map[table] = cluster.id
            }
        }
        return map
    }

    public func clusterCoverage(for story: Story) -> [StoryClusterCoverage] {
        let clusterGroupByNode = nodeToClusterGroup
        let coveredTables = Set(story.coveredTableIDs)
        var tableIDsByCluster: [String: [String]] = [:]

        for tableID in story.coveredTableIDs {
            guard let clusterID = clusterGroupByNode[tableID] else { continue }
            tableIDsByCluster[clusterID, default: []].append(tableID)
        }

        for clusterID in story.clusters where tableIDsByCluster[clusterID] == nil {
            tableIDsByCluster[clusterID] = clusters
                .first { $0.id == clusterID }?
                .tables
                .filter { coveredTables.contains($0) } ?? []
        }

        return tableIDsByCluster.map { clusterID, tableIDs in
            let cluster = clusters.first { $0.id == clusterID }
            return StoryClusterCoverage(
                clusterID: clusterID,
                label: cluster?.label,
                color: cluster?.color,
                tableIDs: tableIDs
            )
        }
        .sorted { lhs, rhs in
            if lhs.tableIDs.count == rhs.tableIDs.count {
                return lhs.clusterID.localizedStandardCompare(rhs.clusterID) == .orderedAscending
            }
            return lhs.tableIDs.count > rhs.tableIDs.count
        }
    }

    public func primaryClusterCoverage(for story: Story) -> StoryClusterCoverage? {
        let coverage = clusterCoverage(for: story)
        if let explicitClusterID = story.clusters.first,
           let explicit = coverage.first(where: { $0.clusterID == explicitClusterID }) {
            return explicit
        }
        return coverage.first
    }

    public struct StoryClusterCoverage: Sendable, Hashable, Identifiable {
        public var clusterID: String
        public var label: String?
        public var color: String?
        public var tableIDs: [String]

        public var id: String { clusterID }

        public init(clusterID: String, label: String?, color: String?, tableIDs: [String]) {
            self.clusterID = clusterID
            self.label = label
            self.color = color
            self.tableIDs = tableIDs
        }

        public var displayLabel: String {
            let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed! : clusterID
        }
    }
}

public enum SchemaSidecarStore {
    /// `mydb.sqlite` -> `mydb.sqlite.studio.json` (sibling file, easy for AI to read/write).
    public static func sidecarURL(for databaseURL: URL) -> URL {
        let name = databaseURL.lastPathComponent + ".studio.json"
        return databaseURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    public static func load(for databaseURL: URL) throws -> SchemaSidecar {
        let url = sidecarURL(for: databaseURL)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return .empty
        } catch {
            throw SchemaMetadataError.unreadable(error.localizedDescription)
        }
        struct VersionEnvelope: Decodable { var version: Int? }
        let version: Int
        do { version = try JSONDecoder().decode(VersionEnvelope.self, from: data).version ?? 1 }
        catch { throw SchemaMetadataError.malformed(error.localizedDescription) }
        guard version == 1 else { throw SchemaMetadataError.unsupportedVersion(version) }
        let sidecar: SchemaSidecar
        do {
            sidecar = try JSONDecoder().decode(SchemaSidecar.self, from: data)
        } catch {
            throw SchemaMetadataError.malformed(error.localizedDescription)
        }
        guard Set(sidecar.stories.map(\.id)).count == sidecar.stories.count,
              Set(sidecar.clusters.map(\.id)).count == sidecar.clusters.count else {
            throw SchemaMetadataError.malformed("Story and cluster identifiers must be unique.")
        }
        return sidecar
    }

    public static func save(_ sidecar: SchemaSidecar, for databaseURL: URL) throws {
        let url = sidecarURL(for: databaseURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(sidecar)
        try data.write(to: url, options: .atomic)
    }
}
