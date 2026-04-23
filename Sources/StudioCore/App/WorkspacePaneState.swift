import CoreTransferable
import Foundation
import UniformTypeIdentifiers

public enum PaneContentKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case schema
    case tables
    case query

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .schema:
            return "Schema"
        case .tables:
            return "Tables"
        case .query:
            return "Query"
        }
    }

    public var systemImage: String {
        switch self {
        case .schema:
            return "point.3.connected.trianglepath.dotted"
        case .tables:
            return "tablecells"
        case .query:
            return "terminal"
        }
    }
}

public enum WorkspacePaneSide: String, CaseIterable, Identifiable, Sendable {
    case left
    case right

    public var id: String { rawValue }

    public var opposite: WorkspacePaneSide {
        switch self {
        case .left:
            return .right
        case .right:
            return .left
        }
    }
}

public struct WorkspacePaneState: Hashable, Sendable {
    public var kind: PaneContentKind

    public init(kind: PaneContentKind) {
        self.kind = kind
    }
}

public struct WorkspaceDockItem: Codable, Hashable, Identifiable, Sendable, Transferable {
    public let kind: PaneContentKind

    public init(kind: PaneContentKind) {
        self.kind = kind
    }

    public var id: PaneContentKind { kind }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .studioWorkspaceDockItem)
    }
}

private extension UTType {
    static let studioWorkspaceDockItem = UTType(exportedAs: "com.sqlitegraphstudio.workspace-dock-item")
}
