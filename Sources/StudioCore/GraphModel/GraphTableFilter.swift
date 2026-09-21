import Foundation

public struct GraphTableFilter: Equatable, Sendable {
    public var minimumFields: Int?
    public var maximumFields: Int?
    public var minimumRows: Int?
    public var maximumRows: Int?
    public var minimumRelations: Int?
    public var maximumRelations: Int?

    public init(minimumFields: Int? = nil, maximumFields: Int? = nil, minimumRows: Int? = nil, maximumRows: Int? = nil,
                minimumRelations: Int? = nil, maximumRelations: Int? = nil) {
        self.minimumFields = minimumFields
        self.maximumFields = maximumFields
        self.minimumRows = minimumRows
        self.maximumRows = maximumRows
        self.minimumRelations = minimumRelations
        self.maximumRelations = maximumRelations
    }

    public var hasRowBounds: Bool { minimumRows != nil || maximumRows != nil }
    public var hasRelationBounds: Bool { minimumRelations != nil || maximumRelations != nil }
    public var isActive: Bool { minimumFields != nil || maximumFields != nil || hasRowBounds || hasRelationBounds }
    public var isValid: Bool {
        [minimumFields, maximumFields, minimumRows, maximumRows, minimumRelations, maximumRelations].compactMap { $0 }.allSatisfy { $0 >= 0 }
            && (minimumFields ?? 0) <= (maximumFields ?? Int.max)
            && (minimumRows ?? 0) <= (maximumRows ?? Int.max)
            && (minimumRelations ?? 0) <= (maximumRelations ?? Int.max)
    }

    public func matchesFields(_ count: Int) -> Bool {
        isValid && count >= (minimumFields ?? 0) && count <= (maximumFields ?? Int.max)
    }

    public func matchesRelations(_ count: Int) -> Bool {
        isValid && count >= (minimumRelations ?? 0) && count <= (maximumRelations ?? Int.max)
    }

    public func matches(fields: Int, rows: Int?, relations: Int) -> Bool {
        guard matchesFields(fields), matchesRelations(relations) else { return false }
        guard hasRowBounds else { return true }
        guard let rows else { return false }
        return rows >= (minimumRows ?? 0) && rows <= (maximumRows ?? Int.max)
    }
}
