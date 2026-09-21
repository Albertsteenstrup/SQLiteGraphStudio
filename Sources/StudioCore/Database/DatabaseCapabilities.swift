import Foundation

public struct DatabaseCapabilities: Sendable, Hashable {
    public let isReadOnly: Bool
    public let canEditRows: Bool
    public let canInsertRows: Bool
    public let canDeleteRows: Bool
    public let canImportRows: Bool
    public let canCreateTable: Bool
    public let canAlterSchema: Bool
    public let canDropColumns: Bool
    public let canWriteSQL: Bool
    public let supportsAIWorkspace: Bool
    /// A migration model describes structure only; there are no rows to page through.
    public let canBrowseRows: Bool
    public let canRunQueries: Bool

    public init(
        isReadOnly: Bool,
        canEditRows: Bool,
        canInsertRows: Bool,
        canDeleteRows: Bool,
        canImportRows: Bool,
        canCreateTable: Bool,
        canAlterSchema: Bool,
        canDropColumns: Bool,
        canWriteSQL: Bool,
        supportsAIWorkspace: Bool,
        canBrowseRows: Bool = true,
        canRunQueries: Bool = true
    ) {
        self.isReadOnly = isReadOnly
        self.canEditRows = canEditRows
        self.canInsertRows = canInsertRows
        self.canDeleteRows = canDeleteRows
        self.canImportRows = canImportRows
        self.canCreateTable = canCreateTable
        self.canAlterSchema = canAlterSchema
        self.canDropColumns = canDropColumns
        self.canWriteSQL = canWriteSQL
        self.supportsAIWorkspace = supportsAIWorkspace
        self.canBrowseRows = canBrowseRows
        self.canRunQueries = canRunQueries
    }

    public static let sqlite = DatabaseCapabilities(
        isReadOnly: false,
        canEditRows: true,
        canInsertRows: true,
        canDeleteRows: true,
        canImportRows: true,
        canCreateTable: true,
        canAlterSchema: true,
        canDropColumns: true,
        canWriteSQL: false,
        supportsAIWorkspace: true
    )

    public static let postgresReadOnly = DatabaseCapabilities(
        isReadOnly: true,
        canEditRows: false,
        canInsertRows: false,
        canDeleteRows: false,
        canImportRows: false,
        canCreateTable: false,
        canAlterSchema: false,
        canDropColumns: false,
        canWriteSQL: false,
        supportsAIWorkspace: true
    )

    /// A schema reconstructed from migration files: structure without data.
    public static let migrationsSchemaOnly = DatabaseCapabilities(
        isReadOnly: true,
        canEditRows: false,
        canInsertRows: false,
        canDeleteRows: false,
        canImportRows: false,
        canCreateTable: false,
        canAlterSchema: false,
        canDropColumns: false,
        canWriteSQL: false,
        supportsAIWorkspace: true,
        canBrowseRows: false,
        canRunQueries: false
    )

    public static let none = DatabaseCapabilities(
        isReadOnly: true,
        canEditRows: false,
        canInsertRows: false,
        canDeleteRows: false,
        canImportRows: false,
        canCreateTable: false,
        canAlterSchema: false,
        canDropColumns: false,
        canWriteSQL: false,
        supportsAIWorkspace: false,
        canBrowseRows: false,
        canRunQueries: false
    )
}
