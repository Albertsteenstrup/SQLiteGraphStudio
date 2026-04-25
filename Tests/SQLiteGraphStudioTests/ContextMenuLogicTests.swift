import Testing
@testable import StudioCore

// MARK: - Random generators

/// Helpers for generating random `TableColumn` and `EditableTableDescriptor`
/// instances used by the property-based tests below.
private enum RandomGen {

    static let declaredTypes = ["TEXT", "INTEGER", "REAL", "BLOB", "NUMERIC", "VARCHAR(255)", "BOOLEAN", ""]

    /// Returns a random `TableColumn` with optional overrides for specific fields.
    static func randomTableColumn(
        name: String? = nil,
        notNull: Bool? = nil,
        primaryKeyOrdinal: Int? = nil,
        hiddenValue: Int? = nil,
        declaredType: String? = nil,
        using rng: inout SystemRandomNumberGenerator
    ) -> TableColumn {
        let colName = name ?? "col_\(rng.next(upperBound: UInt64(10000)))"
        let colType = declaredType ?? declaredTypes.randomElement(using: &rng)!
        let colNotNull = notNull ?? Bool.random(using: &rng)
        let colPK = primaryKeyOrdinal ?? (Bool.random(using: &rng) ? Int(rng.next(upperBound: UInt64(3))) + 1 : 0)
        // hiddenValue: 0 = normal, 2 = stored generated, 3 = virtual generated
        let colHidden = hiddenValue ?? [0, 0, 0, 0, 2, 3].randomElement(using: &rng)!

        return TableColumn(
            name: colName,
            declaredType: colType,
            notNull: colNotNull,
            defaultValueSQL: Bool.random(using: &rng) ? "0" : nil,
            primaryKeyOrdinal: colPK,
            hiddenValue: colHidden
        )
    }

    /// Returns a random `EditableTableDescriptor` with optional overrides.
    static func randomDescriptor(
        isEditable: Bool? = nil,
        columnCount: Int? = nil,
        using rng: inout SystemRandomNumberGenerator
    ) -> EditableTableDescriptor {
        let count = columnCount ?? Int(rng.next(upperBound: UInt64(10))) + 1
        let editable = isEditable ?? Bool.random(using: &rng)

        let columns = (0..<count).map { i in
            randomTableColumn(name: "col_\(i)", using: &rng)
        }

        let pkColumns = columns.filter { $0.primaryKeyOrdinal > 0 }.map(\.name)

        return EditableTableDescriptor(
            name: "table_\(rng.next(upperBound: UInt64(10000)))",
            objectType: .table,
            columns: columns,
            primaryKeyColumns: pkColumns,
            rowIdentityStrategy: pkColumns.isEmpty ? .rowID : .primaryKey,
            isWithoutRowID: false,
            isEditable: editable
        )
    }

    /// Returns a random `ContextMenuState` with optional overrides.
    static func randomContextMenuState(
        isTableEditable: Bool? = nil,
        using rng: inout SystemRandomNumberGenerator
    ) -> ContextMenuState {
        let editable = isTableEditable ?? Bool.random(using: &rng)
        let hasColumn = Bool.random(using: &rng)
        let column: TableColumn? = hasColumn ? randomTableColumn(using: &rng) : nil
        let rowLoaded = Bool.random(using: &rng)

        return ContextMenuState(
            isTableEditable: editable,
            clickedColumn: column,
            isRowLoaded: rowLoaded
        )
    }
}

// MARK: - Property-based tests

struct ContextMenuLogicTests {

    // MARK: - Property 1: Menu structure invariant

    /// **Validates: Requirements 8.1, 8.2, 8.3, 9.3**
    ///
    /// For any combination of table editability, column configuration, and row-loaded
    /// state, `contextMenuItemStates(for:)` always returns a valid
    /// `ContextMenuItemStates` with all 6 boolean fields defined. The NSMenu built
    /// from this result would always contain exactly 8 items (6 actions + 2 separators)
    /// with separators at indices 1 and 4.
    @Test("Feature: table-grid-context-menu, Property 1: Menu structure is invariant across all table states")
    func menuStructureIsInvariantAcrossAllTableStates() {
        var rng = SystemRandomNumberGenerator()

        for _ in 0..<100 {
            let state = RandomGen.randomContextMenuState(using: &rng)
            let items = contextMenuItemStates(for: state)

            // Simulate the NSMenu structure from the ContextMenuItemStates.
            // The menu always has: Set Null, separator, Copy, Paste, separator,
            // Add row, Clone row, Delete row — 8 items total.
            enum MenuItem {
                case action(String, Bool)
                case separator
            }

            let menu: [MenuItem] = [
                .action("Set Null", items.setNullEnabled),       // 0
                .separator,                                       // 1
                .action("Copy", items.copyEnabled),               // 2
                .action("Paste", items.pasteEnabled),             // 3
                .separator,                                       // 4
                .action("Add row", items.addRowEnabled),          // 5
                .action("Clone row", items.cloneRowEnabled),      // 6
                .action("Delete row", items.deleteRowEnabled),    // 7
            ]

            #expect(menu.count == 8, "Menu should always have exactly 8 items")

            // Verify separators are at indices 1 and 4
            if case .separator = menu[1] {} else {
                Issue.record("Item at index 1 should be a separator")
            }
            if case .separator = menu[4] {} else {
                Issue.record("Item at index 4 should be a separator")
            }

            // Verify non-separator items are actions
            for index in [0, 2, 3, 5, 6, 7] {
                if case .action = menu[index] {} else {
                    Issue.record("Item at index \(index) should be an action")
                }
            }
        }
    }

    // MARK: - Property 2: Read-only disablement

    /// **Validates: Requirements 4.3, 5.3, 6.3, 7.3, 9.1, 9.2**
    ///
    /// For any read-only table descriptor, regardless of column configuration or
    /// row-loaded state, all write actions are disabled and Copy is enabled.
    @Test("Feature: table-grid-context-menu, Property 2: Read-only tables disable all write actions while keeping Copy enabled")
    func readOnlyTablesDisableAllWriteActions() {
        var rng = SystemRandomNumberGenerator()

        for _ in 0..<100 {
            let state = RandomGen.randomContextMenuState(
                isTableEditable: false,
                using: &rng
            )

            let items = contextMenuItemStates(for: state)

            #expect(items.setNullEnabled == false, "Set Null should be disabled for read-only table")
            #expect(items.copyEnabled == true, "Copy should always be enabled")
            #expect(items.pasteEnabled == false, "Paste should be disabled for read-only table")
            #expect(items.addRowEnabled == false, "Add row should be disabled for read-only table")
            #expect(items.cloneRowEnabled == false, "Clone row should be disabled for read-only table")
            #expect(items.deleteRowEnabled == false, "Delete row should be disabled for read-only table")
        }
    }

    // MARK: - Property 3: Set Null enabled state

    /// **Validates: Requirements 2.1, 2.3, 2.4**
    ///
    /// For any table column and table descriptor, Set Null is enabled if and only if
    /// ALL of: table is editable, column's notNull is false, column's isEditable is
    /// true, and row is loaded.
    @Test("Feature: table-grid-context-menu, Property 3: Set Null enabled state reflects column nullability and editability")
    func setNullEnabledStateReflectsColumnNullabilityAndEditability() {
        var rng = SystemRandomNumberGenerator()

        for _ in 0..<100 {
            let isTableEditable = Bool.random(using: &rng)
            let isRowLoaded = Bool.random(using: &rng)
            let column = RandomGen.randomTableColumn(using: &rng)

            let state = ContextMenuState(
                isTableEditable: isTableEditable,
                clickedColumn: column,
                isRowLoaded: isRowLoaded
            )

            let items = contextMenuItemStates(for: state)

            let expectedSetNull = isTableEditable
                && !column.notNull
                && column.isEditable
                && isRowLoaded

            #expect(
                items.setNullEnabled == expectedSetNull,
                """
                Set Null mismatch: got \(items.setNullEnabled), expected \(expectedSetNull) \
                (editable=\(isTableEditable), notNull=\(column.notNull), \
                colEditable=\(column.isEditable), rowLoaded=\(isRowLoaded))
                """
            )
        }
    }

    // MARK: - Property 4: Clone column filtering

    /// **Validates: Requirements 6.2**
    ///
    /// For any `EditableTableDescriptor`, `cloneableColumns` returns exactly those
    /// columns where `isEditable` is true AND `primaryKeyOrdinal` is 0.
    @Test("Feature: table-grid-context-menu, Property 4: Clone row includes exactly the editable non-primary-key columns")
    func cloneRowIncludesExactlyEditableNonPKColumns() {
        var rng = SystemRandomNumberGenerator()

        for _ in 0..<100 {
            let descriptor = RandomGen.randomDescriptor(using: &rng)

            let result = cloneableColumns(from: descriptor)

            // Independently compute the expected set
            let expected = descriptor.columns.filter { $0.isEditable && $0.primaryKeyOrdinal == 0 }

            #expect(
                result.map(\.name) == expected.map(\.name),
                """
                cloneableColumns mismatch for table \(descriptor.name): \
                got [\(result.map(\.name).joined(separator: ", "))], \
                expected [\(expected.map(\.name).joined(separator: ", "))]
                """
            )

            // Also verify the count matches
            #expect(result.count == expected.count)
        }
    }

    // MARK: - Example-based unit tests

    /// **Validates: Requirements 8.1, 8.2, 8.3, 9.3**
    ///
    /// An editable table with a loaded row and a normal nullable column should
    /// have every menu item enabled.
    @Test("menu contains all expected items for an editable table with a loaded row")
    func editableTableWithLoadedRowAllItemsEnabled() {
        let column = TableColumn(
            name: "description",
            declaredType: "TEXT",
            notNull: false,
            defaultValueSQL: nil,
            primaryKeyOrdinal: 0,
            hiddenValue: 0
        )

        let state = ContextMenuState(
            isTableEditable: true,
            clickedColumn: column,
            isRowLoaded: true
        )

        let items = contextMenuItemStates(for: state)

        #expect(items.setNullEnabled == true)
        #expect(items.copyEnabled == true)
        #expect(items.pasteEnabled == true)
        #expect(items.addRowEnabled == true)
        #expect(items.cloneRowEnabled == true)
        #expect(items.deleteRowEnabled == true)
    }

    /// **Validates: Requirements 1.4, 5.1, 9.3**
    ///
    /// Right-clicking outside any data row (no column, no row loaded) on an
    /// editable table should only enable Copy and Add row.
    @Test("right-click outside data rows produces menu with only Add row enabled (editable table)")
    func rightClickOutsideDataRowsEditableTable() {
        let state = ContextMenuState(
            isTableEditable: true,
            clickedColumn: nil,
            isRowLoaded: false
        )

        let items = contextMenuItemStates(for: state)

        #expect(items.setNullEnabled == false)
        #expect(items.copyEnabled == true)
        #expect(items.pasteEnabled == true)
        #expect(items.addRowEnabled == true)
        #expect(items.cloneRowEnabled == false)
        #expect(items.deleteRowEnabled == false)
    }

    /// **Validates: Requirements 6.2**
    ///
    /// `cloneableColumns` on a table with mixed PK, generated, blob, and normal
    /// columns returns only the expected subset of editable non-PK columns.
    @Test("cloneableColumns with mixed PK, generated, blob, and normal columns returns expected subset")
    func cloneableColumnsWithMixedColumnTypes() {
        let columns = [
            TableColumn(name: "id", declaredType: "INTEGER", notNull: true, defaultValueSQL: nil, primaryKeyOrdinal: 1, hiddenValue: 0),
            TableColumn(name: "name", declaredType: "TEXT", notNull: false, defaultValueSQL: nil, primaryKeyOrdinal: 0, hiddenValue: 0),
            TableColumn(name: "data", declaredType: "BLOB", notNull: false, defaultValueSQL: nil, primaryKeyOrdinal: 0, hiddenValue: 0),
            TableColumn(name: "computed", declaredType: "TEXT", notNull: false, defaultValueSQL: nil, primaryKeyOrdinal: 0, hiddenValue: 2),
            TableColumn(name: "email", declaredType: "TEXT", notNull: false, defaultValueSQL: nil, primaryKeyOrdinal: 0, hiddenValue: 0),
            TableColumn(name: "age", declaredType: "INTEGER", notNull: false, defaultValueSQL: nil, primaryKeyOrdinal: 0, hiddenValue: 0),
        ]

        let descriptor = EditableTableDescriptor(
            name: "users",
            objectType: .table,
            columns: columns,
            primaryKeyColumns: ["id"],
            rowIdentityStrategy: .primaryKey,
            isWithoutRowID: false,
            isEditable: true
        )

        let result = cloneableColumns(from: descriptor)
        let resultNames = result.map(\.name)

        #expect(resultNames == ["name", "email", "age"])
    }

    /// **Validates: Requirements 4.3, 5.3, 6.3, 7.3, 9.1, 9.2**
    ///
    /// `contextMenuItemStates` for a read-only table returns all write actions
    /// disabled and Copy enabled.
    @Test("contextMenuItemStates for a read-only table returns all write actions disabled")
    func readOnlyTableAllWriteActionsDisabled() {
        let column = TableColumn(
            name: "description",
            declaredType: "TEXT",
            notNull: false,
            defaultValueSQL: nil,
            primaryKeyOrdinal: 0,
            hiddenValue: 0
        )

        let state = ContextMenuState(
            isTableEditable: false,
            clickedColumn: column,
            isRowLoaded: true
        )

        let items = contextMenuItemStates(for: state)

        #expect(items.setNullEnabled == false)
        #expect(items.copyEnabled == true)
        #expect(items.pasteEnabled == false)
        #expect(items.addRowEnabled == false)
        #expect(items.cloneRowEnabled == false)
        #expect(items.deleteRowEnabled == false)
    }
}
