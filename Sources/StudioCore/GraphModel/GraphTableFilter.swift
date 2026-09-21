import Foundation

public struct GraphTableFilter: Equatable, Sendable {
    public var minimumFields: Int?
    public var maximumFields: Int?
    public var minimumRows: Int?
    public var maximumRows: Int?

    public init(minimumFields: Int? = nil, maximumFields: Int? = nil, minimumRows: Int? = nil, maximumRows: Int? = nil) {
        self.minimumFields = minimumFields
        self.maximumFields = maximumFields
        self.minimumRows = minimumRows
        self.maximumRows = maximumRows
    }

    public var hasRowBounds: Bool { minimumRows != nil || maximumRows != nil }
    public var isActive: Bool { minimumFields != nil || maximumFields != nil || hasRowBounds }
    public var isValid: Bool {
        [minimumFields, maximumFields, minimumRows, maximumRows].compactMap { $0 }.allSatisfy { $0 >= 0 }
            && (minimumFields ?? 0) <= (maximumFields ?? Int.max)
            && (minimumRows ?? 0) <= (maximumRows ?? Int.max)
    }

    public func matchesFields(_ count: Int) -> Bool {
        isValid && count >= (minimumFields ?? 0) && count <= (maximumFields ?? Int.max)
    }

    public func matches(fields: Int, rows: Int?) -> Bool {
        guard matchesFields(fields) else { return false }
        guard hasRowBounds else { return true }
        guard let rows else { return false }
        return rows >= (minimumRows ?? 0) && rows <= (maximumRows ?? Int.max)
    }
}
