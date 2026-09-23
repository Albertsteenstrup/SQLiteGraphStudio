import Foundation
import CryptoKit
import Darwin

/// AI-authored metadata that lives next to a `.sqlite` file as `<name>.sqlite.studio.json`.
///
/// The `graph-clusters` skill populates `clusters` so the physics engine groups related tables
/// together by the user's chosen lens. The `schema-descriptions` skill populates `tables`
/// so table and column descriptions stay easy to edit without rewriting SQLite DDL.
/// Older sidecars may contain `stories`. The store backs those entries up and removes
/// them when it next loads the sidecar; they are not part of the current model.
public struct SchemaSidecar: Codable, Sendable, Hashable {
    public var version: Int
    public var clusters: [ClusterHint]
    public var tables: [String: TableDescription]
    public var recordGraphMappings: [RecordGraphMapping]
    /// Explicitly saved, human-readable notes. Temporary view annotations are
    /// kept in the workspace instead and never enter this sidecar.
    public var notes: [Note]

    public init(
        version: Int = 1,
        clusters: [ClusterHint] = [],
        tables: [String: TableDescription] = [:],
        recordGraphMappings: [RecordGraphMapping] = [],
        notes: [Note] = []
    ) {
        self.version = version
        self.clusters = clusters
        self.tables = tables
        self.recordGraphMappings = recordGraphMappings
        self.notes = notes
    }

    public static let empty = SchemaSidecar()

    private enum CodingKeys: String, CodingKey {
        case version
        case clusters
        case tables
        case recordGraphMappings
        case notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        clusters = try container.decodeIfPresent([ClusterHint].self, forKey: .clusters) ?? []
        tables = try container.decodeIfPresent([String: TableDescription].self, forKey: .tables) ?? [:]
        recordGraphMappings = try container.decodeIfPresent([RecordGraphMapping].self, forKey: .recordGraphMappings) ?? []
        notes = try container.decodeIfPresent([Note].self, forKey: .notes) ?? []
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

    public struct Note: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var text: String
        public var tableID: String?
        public var columnName: String?
        public var relationID: String?

        public init(id: String, text: String, tableID: String? = nil,
                    columnName: String? = nil, relationID: String? = nil) {
            self.id = id
            self.text = text
            self.tableID = tableID
            self.columnName = columnName
            self.relationID = relationID
        }
    }


}

public enum SchemaSidecarStore {
    public struct Snapshot: Sendable {
        public var sidecar: SchemaSidecar
        public var revision: String
    }

    /// `mydb.sqlite` -> `mydb.sqlite.studio.json` (sibling file, easy for AI to read/write).
    public static func sidecarURL(for databaseURL: URL) -> URL {
        let name = databaseURL.lastPathComponent + ".studio.json"
        return databaseURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    public static func load(for databaseURL: URL) throws -> SchemaSidecar {
        try loadSnapshot(for: databaseURL).sidecar
    }

    /// Reads the sidecar and its content revision from the same bytes. An
    /// absent file has a distinct revision so a later creation is a conflict.
    public static func loadSnapshot(for databaseURL: URL) throws -> Snapshot {
        let url = sidecarURL(for: databaseURL)
        guard let data = try readIfPresent(at: url) else {
            return Snapshot(sidecar: .empty, revision: revision(of: nil))
        }
        let sidecar = try decodeAndValidate(data)
        guard try containsLegacyStories(in: data) else {
            return Snapshot(sidecar: sidecar, revision: revision(of: data))
        }

        // Loading an absent sidecar remains read-only. For an existing legacy
        // sidecar, serialize migration with writers and re-read after taking
        // the lock so a save that won the race is never replaced by stale bytes.
        return try withExclusiveWriteLock(for: databaseURL) {
            guard let currentData = try readIfPresent(at: url) else {
                return Snapshot(sidecar: .empty, revision: revision(of: nil))
            }
            let currentSidecar = try decodeAndValidate(currentData)
            guard try containsLegacyStories(in: currentData) else {
                return Snapshot(sidecar: currentSidecar, revision: revision(of: currentData))
            }
            let migrated = try migrateLegacyStories(currentData, at: url)
            return Snapshot(sidecar: try decodeAndValidate(migrated), revision: revision(of: migrated))
        }
    }

    private static func readIfPresent(at url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        } catch {
            throw SchemaMetadataError.unreadable(error.localizedDescription)
        }
    }

    private static func decodeAndValidate(_ data: Data) throws -> SchemaSidecar {
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
        guard Set(sidecar.clusters.map(\.id)).count == sidecar.clusters.count else {
            throw SchemaMetadataError.malformed("Cluster identifiers must be unique.")
        }
        guard Set(sidecar.notes.map(\.id)).count == sidecar.notes.count,
              sidecar.notes.count <= 500,
              sidecar.notes.allSatisfy({ validNote($0) }) else {
            throw SchemaMetadataError.malformed("Saved note identifiers must be unique and notes must stay within their field limits.")
        }
        return sidecar
    }

    private static func containsLegacyStories(in data: Data) throws -> Bool {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SchemaMetadataError.malformed("The metadata document must be a JSON object.")
        }
        return root["stories"] != nil
    }

    public static func revision(for databaseURL: URL) throws -> String {
        let url = sidecarURL(for: databaseURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return revision(of: nil) }
        return revision(of: try Data(contentsOf: url))
    }

    private static func revision(of data: Data?) -> String {
        let tagged = Data([data == nil ? 0 : 1]) + (data ?? Data())
        return SHA256.hash(data: tagged).map { String(format: "%02x", $0) }.joined()
    }

    private static func validNote(_ note: SchemaSidecar.Note) -> Bool {
        !note.id.isEmpty && note.id.count <= 200
            && !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && note.text.count <= 4_000
            && (note.tableID?.count ?? 0) <= 500
            && (note.columnName?.count ?? 0) <= 500
            && (note.relationID?.count ?? 0) <= 500
            && (note.columnName == nil || note.tableID != nil)
    }

    public static func save(_ sidecar: SchemaSidecar, for databaseURL: URL) throws {
        _ = try withExclusiveWriteLock(for: databaseURL) {
            try write(sidecar, for: databaseURL, expectedRevision: nil)
        }
    }

    /// An optimistic write for coding-agent requests. A client must first read
    /// the current revision, and a stale request cannot replace another edit.
    @discardableResult
    public static func save(_ sidecar: SchemaSidecar, for databaseURL: URL,
                            expectedRevision: String) throws -> String {
        try withExclusiveWriteLock(for: databaseURL) {
            try write(sidecar, for: databaseURL, expectedRevision: expectedRevision)
        }
    }

    private static func withExclusiveWriteLock<T>(for databaseURL: URL, _ operation: () throws -> T) throws -> T {
        let lockURL = sidecarURL(for: databaseURL).appendingPathExtension("lock")
        let normalizedLockURL = lockURL.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(lockURL.lastPathComponent)
            .standardizedFileURL
        let processLock = SchemaSidecarProcessLockRegistry.shared.lock(for: normalizedLockURL.path)
        processLock.lock()
        defer { processLock.unlock() }

        let fd = lockURL.path.withCString { Darwin.open($0, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600)) }
        guard fd >= 0 else {
            throw SchemaMetadataError.unreadable("Could not lock metadata for an atomic update.")
        }
        defer { _ = Darwin.close(fd) }
        guard Darwin.lockf(fd, F_LOCK, 0) == 0 else {
            throw SchemaMetadataError.unreadable("Could not acquire the metadata write lock.")
        }
        defer { _ = Darwin.lockf(fd, F_ULOCK, 0) }
        return try operation()
    }

    private static func write(_ sidecar: SchemaSidecar, for databaseURL: URL,
                              expectedRevision: String?) throws -> String {
        guard Set(sidecar.notes.map(\.id)).count == sidecar.notes.count,
              sidecar.notes.count <= 500,
              sidecar.notes.allSatisfy({ validNote($0) }) else {
            throw SchemaMetadataError.malformed("Saved note identifiers must be unique and notes must stay within their field limits.")
        }
        let url = sidecarURL(for: databaseURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(sidecar)
        guard var replacement = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw SchemaMetadataError.malformed("The metadata document must be a JSON object.")
        }
        replacement.removeValue(forKey: "stories")

        var root = [String: Any]()
        let existing = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        if let expectedRevision, expectedRevision != revision(of: existing) {
            throw SchemaMetadataError.conflict(revision(of: existing))
        }
        if let existing {
            guard let existingRoot = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw SchemaMetadataError.malformed("The existing metadata document must be a JSON object.")
            }
            let version = existingRoot["version"] as? Int ?? 1
            guard version == 1 else { throw SchemaMetadataError.unsupportedVersion(version) }
            root = existingRoot
            if root["stories"] != nil {
                try backupOriginal(existing, at: url)
            }
        }

        let oldTables = root["tables"] as? [String: [String: Any]] ?? [:]
        let newTables = replacement["tables"] as? [String: [String: Any]] ?? [:]
        var preservedTables = [String: [String: Any]]()
        for id in Set(oldTables.keys).union(newTables.keys) {
            let merged = mergeKnownFields(
                oldTables[id] ?? [:], newTables[id] ?? [:],
                names: ["description", "columns"]
            )
            if !merged.isEmpty { preservedTables[id] = merged }
        }
        root["tables"] = preservedTables
        root["clusters"] = mergeIdentifiedEntries(
            existing: root["clusters"], replacement: replacement["clusters"],
            knownFields: ["id", "label", "tables", "color"]
        )
        root["recordGraphMappings"] = mergeIdentifiedEntries(
            existing: root["recordGraphMappings"], replacement: replacement["recordGraphMappings"],
            knownFields: ["id", "name", "nodeTable", "nodeIDColumns", "labelColumn", "edgeTable", "sourceColumns", "targetColumns", "typeColumn", "isDirected", "nodeScope", "edgeScope"]
        )
        root["notes"] = mergeIdentifiedEntries(
            existing: root["notes"], replacement: replacement["notes"],
            knownFields: ["id", "text", "tableID", "columnName", "relationID"]
        )
        root["version"] = replacement["version"]
        root.removeValue(forKey: "stories")
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
        return revision(of: data)
    }

    /// The caller holds the same write lock used by save. Migration changes the
    /// original only after a byte-for-byte backup is verified.
    private static func migrateLegacyStories(_ data: Data, at url: URL) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SchemaMetadataError.malformed("The metadata document must be a JSON object.")
        }
        guard root.removeValue(forKey: "stories") != nil else { return data }
        let replacement = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try backupOriginal(data, at: url)
        try replacement.write(to: url, options: .atomic)
        return replacement
    }

    private static func backupOriginal(_ data: Data, at url: URL) throws {
        let backup = url.deletingLastPathComponent().appendingPathComponent(
            url.lastPathComponent + ".stories-backup-" + UUID().uuidString + ".json"
        )
        guard FileManager.default.createFile(
            atPath: backup.path, contents: data,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else {
            throw SchemaMetadataError.unreadable("Could not back up old story metadata at \(backup.path).")
        }
        guard try Data(contentsOf: backup) == data else {
            throw SchemaMetadataError.unreadable("Story metadata backup failed verification at \(backup.path).")
        }
    }

    private static func mergeKnownFields(
        _ old: [String: Any], _ updated: [String: Any], names: Set<String>
    ) -> [String: Any] {
        var result = old
        for name in names { result[name] = updated[name] }
        return result
    }

    private static func mergeIdentifiedEntries(
        existing: Any?, replacement: Any?, knownFields: Set<String>
    ) -> [[String: Any]] {
        let old = existing as? [[String: Any]] ?? []
        let updated = replacement as? [[String: Any]] ?? []
        let byID = Dictionary(old.compactMap { item -> (String, [String: Any])? in
            guard let id = item["id"] as? String else { return nil }
            return (id, item)
        }, uniquingKeysWith: { first, _ in first })
        return updated.map { item in
            guard let id = item["id"] as? String else { return item }
            return mergeKnownFields(byID[id] ?? [:], item, names: knownFields)
        }
    }
}

/// `lockf` record locks are process-owned, so two descriptors held by threads
/// in this process do not exclude each other. Keep a stable mutex per lock-file
/// path and acquire it before the interprocess lock.
private final class SchemaSidecarProcessLockRegistry: @unchecked Sendable {
    static let shared = SchemaSidecarProcessLockRegistry()

    private let registryLock = NSLock()
    private var locks: [String: NSLock] = [:]

    func lock(for path: String) -> NSLock {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = locks[path] { return existing }
        let lock = NSLock()
        locks[path] = lock
        return lock
    }
}
