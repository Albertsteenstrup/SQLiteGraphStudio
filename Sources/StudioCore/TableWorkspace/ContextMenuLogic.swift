/// Pure logic for computing context menu item enabled/disabled states
/// and filtering columns eligible for clone operations.
///
/// These functions are free of AppKit dependencies so they can be
/// exercised directly in property-based and unit tests.

/// Captures the table/column/row state at the moment the user right-clicks.
public struct ContextMenuState: Sendable, Hashable {
    public let isTableEditable: Bool
    public let clickedColumn: TableColumn?
    public let isRowLoaded: Bool

    public init(isTableEditable: Bool, clickedColumn: TableColumn?, isRowLoaded: Bool) {
        self.isTableEditable = isTableEditable
        self.clickedColumn = clickedColumn
        self.isRowLoaded = isRowLoaded
    }
}

/// The enabled/disabled state for every item in the context menu.
public struct ContextMenuItemStates: Sendable, Hashable {
    public let setNullEnabled: Bool
    public let copyEnabled: Bool
    public let pasteEnabled: Bool
    public let addRowEnabled: Bool
    public let cloneRowEnabled: Bool
    public let deleteRowEnabled: Bool

    public init(
        setNullEnabled: Bool,
        copyEnabled: Bool,
        pasteEnabled: Bool,
        addRowEnabled: Bool,
        cloneRowEnabled: Bool,
        deleteRowEnabled: Bool
    ) {
        self.setNullEnabled = setNullEnabled
        self.copyEnabled = copyEnabled
        self.pasteEnabled = pasteEnabled
        self.addRowEnabled = addRowEnabled
        self.cloneRowEnabled = cloneRowEnabled
        self.deleteRowEnabled = deleteRowEnabled
    }
}

/// Computes the enabled/disabled state for each context menu item based on
/// table editability, column properties, and whether the clicked row is loaded.
///
/// Business rules:
/// - Set Null: enabled iff table is editable AND column is nullable (`notNull == false`)
///   AND column is editable AND row is loaded.
/// - Copy: always enabled.
/// - Paste: enabled iff table is editable.
/// - Add row: enabled iff table is editable.
/// - Clone row: enabled iff table is editable AND row is loaded.
/// - Delete row: enabled iff table is editable AND row is loaded.
public func contextMenuItemStates(for state: ContextMenuState) -> ContextMenuItemStates {
    let isEditable = state.isTableEditable
    let isRowLoaded = state.isRowLoaded

    let setNullEnabled: Bool = {
        guard isEditable, isRowLoaded, let column = state.clickedColumn else {
            return false
        }
        return !column.notNull && column.isEditable
    }()

    return ContextMenuItemStates(
        setNullEnabled: setNullEnabled,
        copyEnabled: true,
        pasteEnabled: isEditable,
        addRowEnabled: isEditable,
        cloneRowEnabled: isEditable && isRowLoaded,
        deleteRowEnabled: isEditable && isRowLoaded
    )
}

/// Returns the subset of columns from `descriptor` that are eligible for
/// inclusion in a clone-row operation.
///
/// A column is cloneable when:
/// - `isEditable` is `true` (not generated, not blob), AND
/// - `primaryKeyOrdinal` is `0` (not part of the primary key).
public func cloneableColumns(from descriptor: EditableTableDescriptor) -> [TableColumn] {
    descriptor.columns.filter { $0.isEditable && $0.primaryKeyOrdinal == 0 }
}
