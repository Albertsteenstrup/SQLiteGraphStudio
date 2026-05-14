import Foundation

/// AI-authored metadata that lives next to a `.sqlite` file as `<name>.sqlite.studio.json`.
///
/// The `graph-clusters` skill populates `clusters` so the physics engine groups related tables
/// together by the user's chosen lens. The `schema-descriptions` skill populates `tables`
/// so table and column descriptions stay easy to edit without rewriting SQLite DDL.
public struct SchemaSidecar: Codable, Sendable, Hashable {
    public var version: Int
    public var clusters: [ClusterHint]
    public var tables: [String: TableDescription]

    public init(
        version: Int = 1,
        clusters: [ClusterHint] = [],
        tables: [String: TableDescription] = [:]
    ) {
        self.version = version
        self.clusters = clusters
        self.tables = tables
    }

    public static let empty = SchemaSidecar()

    private enum CodingKeys: String, CodingKey {
        case version
        case clusters
        case tables
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        clusters = try container.decodeIfPresent([ClusterHint].self, forKey: .clusters) ?? []
        tables = try container.decodeIfPresent([String: TableDescription].self, forKey: .tables) ?? [:]
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
}

public enum SchemaSidecarStore {
    /// `mydb.sqlite` -> `mydb.sqlite.studio.json` (sibling file, easy for AI to read/write).
    public static func sidecarURL(for databaseURL: URL) -> URL {
        let name = databaseURL.lastPathComponent + ".studio.json"
        return databaseURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    public static func load(for databaseURL: URL) -> SchemaSidecar {
        let url = sidecarURL(for: databaseURL)
        guard let data = try? Data(contentsOf: url) else {
            return .empty
        }
        let decoder = JSONDecoder()
        guard let sidecar = try? decoder.decode(SchemaSidecar.self, from: data) else {
            StudioLog.db.warning("Sidecar at \(url.lastPathComponent, privacy: .public) failed to decode; ignoring")
            return .empty
        }
        return sidecar
    }
}
