import Foundation

public enum SchemaMetadataError: Error, Sendable, Equatable, LocalizedError {
    case unreadable(String)
    case malformed(String)
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let detail): return "Cannot read metadata: \(detail)"
        case .malformed(let detail): return "Malformed metadata: \(detail)"
        case .unsupportedVersion(let version): return "Metadata version \(version) is unsupported; this app supports version 1."
        }
    }
}

public enum SchemaMetadataStatus: Sendable, Equatable {
    case absent, loaded, removed
    case failed(SchemaMetadataError)
}

/// A document-scoped last-good value. Failed reads cannot replace good metadata,
/// and a different document can never inherit another document's annotations.
public struct SchemaMetadataState: Sendable {
    public private(set) var documentURL: URL?
    public private(set) var sidecar: SchemaSidecar = .empty
    public private(set) var status: SchemaMetadataStatus = .absent
    public private(set) var diagnostics: [String] = []
    private var hasObservedFile = false

    public init() {}

    public mutating func reload(for url: URL, descriptors: [TableDescriptor]) {
        let normalized = url.standardizedFileURL
        if documentURL != normalized {
            self = Self()
            documentURL = normalized
        }
        do {
            let file = SchemaSidecarStore.sidecarURL(for: normalized)
            do {
                _ = try file.resourceValues(forKeys: [.isRegularFileKey])
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                sidecar = .empty
                diagnostics = []
                status = hasObservedFile ? .removed : .absent
                return
            }
            hasObservedFile = true
            let loaded = try SchemaSidecarStore.load(for: normalized)
            sidecar = loaded
            status = .loaded
            diagnostics = Self.validate(loaded, descriptors: descriptors)
        } catch {
            let metadataError = error as? SchemaMetadataError ?? .unreadable(error.localizedDescription)
            status = .failed(metadataError)
            diagnostics = [metadataError.localizedDescription] + Self.validate(sidecar, descriptors: descriptors)
        }
    }

    public static func validate(_ sidecar: SchemaSidecar, descriptors: [TableDescriptor]) -> [String] {
        let columns = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.name, Set($0.columns.map(\.name))) })
        var issues: Set<String> = []
        func table(_ name: String) {
            if columns[name] == nil { issues.insert("Metadata references missing table ‘\(name)’.") }
        }
        func column(_ name: String, in tableName: String) {
            table(tableName)
            if let known = columns[tableName], !known.contains(name) {
                issues.insert("Metadata references missing column ‘\(tableName).\(name)’.")
            }
        }
        for (name, description) in sidecar.tables {
            table(name)
            for nameOfColumn in description.columns.keys { column(nameOfColumn, in: name) }
        }
        for cluster in sidecar.clusters { for name in cluster.tables { table(name) } }
        let clusterIDs = Set(sidecar.clusters.map(\.id))
        let storyIDs = Set(sidecar.stories.map(\.id))
        for story in sidecar.stories {
            for name in story.coveredTableIDs { table(name) }
            for step in story.playback { if let relation = step.relation { column(relation.column, in: relation.table) } }
            for id in story.clusters where !clusterIDs.contains(id) { issues.insert("Story ‘\(story.title)’ references missing cluster ‘\(id)’.") }
            for relation in story.relatedStories where !storyIDs.contains(relation.storyID) { issues.insert("Story ‘\(story.title)’ references missing story ‘\(relation.storyID)’.") }
        }
        return issues.sorted()
    }
}
