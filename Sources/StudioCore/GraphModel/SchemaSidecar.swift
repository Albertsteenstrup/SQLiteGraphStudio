import Foundation

/// AI-authored metadata that lives next to a `.sqlite` file as `<name>.sqlite.studio.json`.
///
/// The `graph-clusters` skill populates `clusters` so the physics engine groups related tables
/// together by domain. Table and column descriptions are **not** stored here — they live in the
/// DDL itself as `--` comments and are extracted at load time by `DDLCommentParser`.
public struct SchemaSidecar: Codable, Sendable, Hashable {
    public var version: Int
    public var clusters: [ClusterHint]

    public init(version: Int = 1, clusters: [ClusterHint] = []) {
        self.version = version
        self.clusters = clusters
    }

    public static let empty = SchemaSidecar()

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
