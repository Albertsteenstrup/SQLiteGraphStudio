import AppKit
import SwiftUI

public struct TableGridRepresentable: NSViewRepresentable {
    public let tab: TableTabModel
    public let revision: Int
    public let requestColumnDrop: (TableColumn) -> Void

    public init(tab: TableTabModel, revision: Int, requestColumnDrop: @escaping (TableColumn) -> Void) {
        self.tab = tab
        self.revision = revision
        self.requestColumnDrop = requestColumnDrop
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(tab: tab, requestColumnDrop: requestColumnDrop)
    }

    @MainActor
    public func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    @MainActor
    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(
            tab: tab,
            revision: revision,
            requestColumnDrop: requestColumnDrop,
            scrollView: nsView
        )
    }

    @MainActor
    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var tab: TableTabModel
        private var requestColumnDrop: (TableColumn) -> Void
        private weak var tableView: NSTableView?
        private weak var scrollView: NSScrollView?
        private weak var headerView: InteractiveTableHeaderView?
        private var revision = -1
        private var headerPopover: NSPopover?
        private var hoveredColumnName: String?

        init(tab: TableTabModel, requestColumnDrop: @escaping (TableColumn) -> Void) {
            self.tab = tab
            self.requestColumnDrop = requestColumnDrop
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func makeScrollView() -> NSScrollView {
            let scrollView = NSScrollView()
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay

            let tableView = NSTableView()
            let headerView = InteractiveTableHeaderView()
            headerView.coordinator = self
            headerView.frame.size.height = 58

            tableView.headerView = headerView
            tableView.usesAlternatingRowBackgroundColors = false
            tableView.selectionHighlightStyle = .none
            tableView.backgroundColor = .clear
            tableView.gridStyleMask = []
            tableView.intercellSpacing = .zero
            tableView.rowHeight = 44
            tableView.delegate = self
            tableView.dataSource = self
            tableView.focusRingType = .none
            tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            tableView.style = .plain

            scrollView.documentView = tableView
            scrollView.contentView.postsBoundsChangedNotifications = true

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipViewBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )

            self.tableView = tableView
            self.scrollView = scrollView
            self.headerView = headerView
            syncColumns(on: tableView)
            applyHeaderState(on: tableView)

            return scrollView
        }

        func update(
            tab: TableTabModel,
            revision: Int,
            requestColumnDrop: @escaping (TableColumn) -> Void,
            scrollView: NSScrollView
        ) {
            self.tab = tab
            self.requestColumnDrop = requestColumnDrop
            self.scrollView = scrollView
            guard let tableView else { return }

            syncColumns(on: tableView)
            applyHeaderState(on: tableView)

            if revision != self.revision {
                self.revision = revision
                tableView.noteNumberOfRowsChanged()
                tableView.reloadData()
            }

            visibleRectDidChange()
        }

        public func numberOfRows(in tableView: NSTableView) -> Int {
            tab.chunk.totalRowCount
        }

        public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            true
        }

        public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            44
        }

        public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = GridRowView()
            rowView.rowIndex = row
            return rowView
        }

        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn,
                  let columnIndex = tab.descriptor.columns.firstIndex(where: { $0.name == tableColumn.identifier.rawValue })
            else {
                return nil
            }

            let identifier = NSUserInterfaceItemIdentifier("EditableCellView")
            let view = (tableView.makeView(withIdentifier: identifier, owner: nil) as? EditableTableCellView) ?? EditableTableCellView(frame: .zero)
            view.identifier = identifier

            let column = tab.descriptor.columns[columnIndex]
            let valueText = tab.displayedValue(row: row, column: columnIndex)
            let isLoaded = tab.row(at: row) != nil
            let isEditable = tab.isEditable && column.isEditable && isLoaded

            view.configure(
                value: valueText,
                editable: isEditable,
                dimmed: !isLoaded,
                commitHandler: { [weak self] newValue in
                    self?.tab.commitEdit(row: row, columnName: column.name, rawValue: newValue)
                }
            )

            return view
        }

        fileprivate func showHeaderPopover(for columnName: String, headerRect: NSRect) {
            guard let tableView,
                  let headerView,
                  let column = tab.descriptor.columns.first(where: { $0.name == columnName })
            else {
                return
            }

            restoreTableFocus()

            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.contentSize = NSSize(width: 280, height: tab.isEditable && column.canDropInSQLite ? 252 : 220)
            popover.contentViewController = NSHostingController(
                rootView: HeaderPopoverContent(
                    column: column,
                    currentSort: tab.queryState.sort,
                    currentFilter: tab.filterValue(for: column.name),
                    canDelete: tab.isEditable && column.canDropInSQLite,
                    onSortAscending: { [weak self] in
                        self?.restoreTableFocus()
                        self?.tab.applySort(SortState(columnName: column.name, direction: .ascending))
                        self?.closeHeaderPopover()
                    },
                    onSortDescending: { [weak self] in
                        self?.restoreTableFocus()
                        self?.tab.applySort(SortState(columnName: column.name, direction: .descending))
                        self?.closeHeaderPopover()
                    },
                    onClearSort: { [weak self] in
                        self?.restoreTableFocus()
                        self?.tab.applySort(nil)
                        self?.closeHeaderPopover()
                    },
                    onApplyFilter: { [weak self] value in
                        self?.restoreTableFocus()
                        self?.tab.updateFilterValue(value, for: column.name)
                        self?.closeHeaderPopover()
                    },
                    onClearFilter: { [weak self] in
                        self?.restoreTableFocus()
                        self?.tab.updateFilterValue("", for: column.name)
                        self?.closeHeaderPopover()
                    },
                    onDeleteColumn: { [weak self] in
                        self?.restoreTableFocus()
                        self?.closeHeaderPopover()
                        self?.requestColumnDrop(column)
                    }
                )
            )

            headerPopover?.close()
            headerPopover = popover
            popover.show(relativeTo: headerRect, of: headerView, preferredEdge: .maxY)

            applyHeaderState(on: tableView)
        }

        fileprivate func closeHeaderPopover() {
            headerPopover?.close()
            headerPopover = nil
            guard let tableView else { return }
            applyHeaderState(on: tableView)
        }

        fileprivate func updateHoveredColumn(_ columnName: String?) {
            hoveredColumnName = columnName
            guard let tableView else { return }
            applyHeaderState(on: tableView)
        }

        private func syncColumns(on tableView: NSTableView) {
            let currentNames = tableView.tableColumns.map(\.identifier.rawValue)
            let desiredNames = tab.descriptor.columns.map(\.name)
            guard currentNames != desiredNames else { return }

            closeHeaderPopover()

            for column in tableView.tableColumns {
                tableView.removeTableColumn(column)
            }

            for column in tab.descriptor.columns {
                let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.name))
                tableColumn.headerCell = MetadataHeaderCell(title: column.name, subtitle: column.typeLabel)
                tableColumn.title = column.name
                tableColumn.width = max(168, CGFloat(column.name.count) * 12 + 64)
                tableColumn.minWidth = 132
                tableView.addTableColumn(tableColumn)
            }
        }

        private func applyHeaderState(on tableView: NSTableView) {
            for tableColumn in tableView.tableColumns {
                guard let headerCell = tableColumn.headerCell as? MetadataHeaderCell else { continue }
                let columnName = tableColumn.identifier.rawValue
                headerCell.isSortActive = tab.queryState.sort?.columnName == columnName
                headerCell.hasFilter = !tab.filterValue(for: columnName).isEmpty
                headerCell.isHovered = hoveredColumnName == columnName
                headerCell.showsChevron = true
            }
            tableView.headerView?.needsDisplay = true
        }

        @objc private func clipViewBoundsDidChange(_ notification: Notification) {
            visibleRectDidChange()
        }

        private func visibleRectDidChange() {
            guard let tableView, let scrollView else { return }
            guard tab.chunk.totalRowCount > 0, !tab.chunk.rows.isEmpty else { return }
            let visibleRows = tableView.rows(in: scrollView.contentView.documentVisibleRect)
            guard visibleRows.location != NSNotFound, visibleRows.length > 0 else { return }
            let targetRow = visibleRows.location + max(visibleRows.length / 2, 0)
            guard targetRow < tab.chunk.totalRowCount else { return }
            tab.ensureVisible(row: targetRow)
        }

        private func restoreTableFocus() {
            guard let tableView else { return }
            tableView.window?.makeFirstResponder(tableView)
        }
    }
}

@MainActor
final class InteractiveTableHeaderView: NSTableHeaderView {
    weak var coordinator: TableGridRepresentable.Coordinator?
    private var trackingArea: NSTrackingArea?

    override var isOpaque: Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.975, alpha: 0.98).setFill()
        dirtyRect.fill()

        let separator = NSBezierPath()
        separator.move(to: CGPoint(x: dirtyRect.minX, y: dirtyRect.maxY - 0.5))
        separator.line(to: CGPoint(x: dirtyRect.maxX, y: dirtyRect.maxY - 0.5))
        NSColor(calibratedWhite: 0, alpha: 0.06).setStroke()
        separator.lineWidth = 1
        separator.stroke()

        super.draw(dirtyRect)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let tableView else { return }
        let point = convert(event.locationInWindow, from: nil)
        let columnIndex = tableView.column(at: CGPoint(x: point.x, y: 1))
        if columnIndex >= 0, tableView.tableColumns.indices.contains(columnIndex) {
            coordinator?.updateHoveredColumn(tableView.tableColumns[columnIndex].identifier.rawValue)
        } else {
            coordinator?.updateHoveredColumn(nil)
        }
    }

    override func mouseExited(with event: NSEvent) {
        coordinator?.updateHoveredColumn(nil)
    }

    override func mouseDown(with event: NSEvent) {
        guard let tableView else {
            super.mouseDown(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let columnIndex = tableView.column(at: CGPoint(x: point.x, y: 1))
        guard columnIndex >= 0,
              tableView.tableColumns.indices.contains(columnIndex),
              let headerCell = tableView.tableColumns[columnIndex].headerCell as? MetadataHeaderCell
        else {
            super.mouseDown(with: event)
            return
        }

        let headerRect = self.headerRect(ofColumn: columnIndex)
        if headerCell.chevronRect(for: headerRect).contains(point) {
            coordinator?.showHeaderPopover(for: tableView.tableColumns[columnIndex].identifier.rawValue, headerRect: headerRect)
            return
        }

        super.mouseDown(with: event)
    }
}

@MainActor
final class GridRowView: NSTableRowView {
    var rowIndex = 0

    override var isEmphasized: Bool {
        get { false }
        set { }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        let fillColor: NSColor
        if isSelected {
            fillColor = NSColor(calibratedWhite: 0.9, alpha: 0.98)
        } else if rowIndex.isMultiple(of: 2) {
            fillColor = NSColor(calibratedWhite: 0, alpha: 0.018)
        } else {
            fillColor = .clear
        }
        fillColor.setFill()
        dirtyRect.fill()

        let separator = NSBezierPath()
        separator.move(to: CGPoint(x: bounds.minX, y: bounds.maxY - 0.5))
        separator.line(to: CGPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
        NSColor(calibratedWhite: 0, alpha: 0.05).setStroke()
        separator.lineWidth = 1
        separator.stroke()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.9, alpha: 0.98).setFill()
        dirtyRect.fill()
    }
}

@MainActor
final class MetadataHeaderCell: NSTableHeaderCell {
    private let subtitle: String
    var isSortActive = false
    var hasFilter = false
    var isHovered = false
    var showsChevron = true

    init(title: String, subtitle: String) {
        self.subtitle = subtitle
        super.init(textCell: title)
        lineBreakMode = .byTruncatingTail
        alignment = .left
    }

    required init(coder: NSCoder) {
        self.subtitle = ""
        super.init(coder: coder)
    }

    func chevronRect(for cellFrame: NSRect) -> NSRect {
        NSRect(x: cellFrame.maxX - 32, y: cellFrame.midY - 10, width: 20, height: 20)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        if isSortActive || hasFilter || isHovered {
            let highlightRect = cellFrame.insetBy(dx: 4, dy: 4)
            let highlightPath = NSBezierPath(roundedRect: highlightRect, xRadius: 14, yRadius: 14)
            NSColor(calibratedWhite: 0, alpha: isSortActive || hasFilter ? 0.045 : 0.024).setFill()
            highlightPath.fill()
        }

        let textRect = cellFrame.insetBy(dx: 16, dy: 8)
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.96),
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        let chevronRect = chevronRect(for: cellFrame)
        let availableWidth = max(60, (showsChevron ? chevronRect.minX : cellFrame.maxX - 12) - textRect.minX - 8)

        stringValue.draw(
            in: NSRect(x: textRect.minX, y: textRect.minY + 24, width: availableWidth, height: 18),
            withAttributes: titleAttributes
        )
        subtitle.draw(
            in: NSRect(x: textRect.minX, y: textRect.minY + 6, width: availableWidth, height: 12),
            withAttributes: subtitleAttributes
        )

        if showsChevron, (isHovered || isSortActive || hasFilter) {
            let buttonPath = NSBezierPath(roundedRect: chevronRect, xRadius: 8, yRadius: 8)
            let buttonFillAlpha = isSortActive || hasFilter ? 0.08 : 0.04
            NSColor(calibratedWhite: 0, alpha: buttonFillAlpha).setFill()
            buttonPath.fill()

            if let image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) {
                let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
                let tinted = image.withSymbolConfiguration(configuration) ?? image
                tinted.isTemplate = true
                let tint = isSortActive || hasFilter
                    ? NSColor.labelColor.withAlphaComponent(0.92)
                    : NSColor.secondaryLabelColor
                tint.set()
                tinted.draw(
                    in: NSRect(
                        x: chevronRect.minX + 4,
                        y: chevronRect.minY + 4,
                        width: 12,
                        height: 12
                    )
                )
            }
        }

        if hasFilter {
            let indicatorAnchorX = showsChevron ? chevronRect.minX - 9 : cellFrame.maxX - 14
            let indicatorRect = NSRect(x: indicatorAnchorX, y: chevronRect.midY - 2, width: 4, height: 4)
            let indicatorPath = NSBezierPath(ovalIn: indicatorRect)
            NSColor.labelColor.withAlphaComponent(0.84).setFill()
            indicatorPath.fill()
        }

        let divider = NSBezierPath()
        divider.move(to: CGPoint(x: cellFrame.maxX - 0.5, y: cellFrame.minY + 10))
        divider.line(to: CGPoint(x: cellFrame.maxX - 0.5, y: cellFrame.maxY - 10))
        NSColor(calibratedWhite: 0, alpha: 0.05).setStroke()
        divider.lineWidth = 1
        divider.stroke()
    }
}

private struct HeaderPopoverContent: View {
    let column: TableColumn
    let currentSort: SortState?
    let canDelete: Bool
    let onSortAscending: () -> Void
    let onSortDescending: () -> Void
    let onClearSort: () -> Void
    let onApplyFilter: (String) -> Void
    let onClearFilter: () -> Void
    let onDeleteColumn: () -> Void

    @State private var filterText: String

    init(
        column: TableColumn,
        currentSort: SortState?,
        currentFilter: String,
        canDelete: Bool,
        onSortAscending: @escaping () -> Void,
        onSortDescending: @escaping () -> Void,
        onClearSort: @escaping () -> Void,
        onApplyFilter: @escaping (String) -> Void,
        onClearFilter: @escaping () -> Void,
        onDeleteColumn: @escaping () -> Void
    ) {
        self.column = column
        self.currentSort = currentSort
        self.canDelete = canDelete
        self.onSortAscending = onSortAscending
        self.onSortDescending = onSortDescending
        self.onClearSort = onClearSort
        self.onApplyFilter = onApplyFilter
        self.onClearFilter = onClearFilter
        self.onDeleteColumn = onDeleteColumn
        _filterText = State(initialValue: currentFilter)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(column.name)
                    .font(.headline)
                    .foregroundStyle(StudioPalette.primaryText)
                Text(column.typeLabel)
                    .font(.caption)
                    .foregroundStyle(StudioPalette.secondaryText)
            }

            VStack(alignment: .leading, spacing: 8) {
                Button(action: onSortAscending) {
                    rowLabel("Sort ascending", systemImage: "arrow.up")
                }
                .buttonStyle(.plain)

                Button(action: onSortDescending) {
                    rowLabel("Sort descending", systemImage: "arrow.down")
                }
                .buttonStyle(.plain)

                Button(action: onClearSort) {
                    rowLabel("Clear sort", systemImage: currentSort?.columnName == column.name ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Filter")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioPalette.secondaryText)

                TextField("Contains text", text: $filterText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        onApplyFilter(filterText)
                    }

                HStack {
                    Button("Apply") {
                        onApplyFilter(filterText)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StudioPalette.accent)

                    Button("Clear") {
                        filterText = ""
                        onClearFilter()
                    }
                    .buttonStyle(.bordered)
                    .tint(StudioPalette.accent)
                }
            }

            if canDelete {
                Divider()
                    .overlay(StudioPalette.divider)

                Button(role: .destructive) {
                    onDeleteColumn()
                } label: {
                    rowLabel("Delete column", systemImage: "trash")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StudioPalette.cardSurfaceTop)
        )
    }

    private func rowLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(StudioPalette.primaryText)
            Text(title)
                .foregroundStyle(StudioPalette.primaryText)
            Spacer()
        }
        .font(.subheadline.weight(.medium))
        .padding(.vertical, 2)
    }
}

@MainActor
private final class EditableTableCellView: NSTableCellView {
    private let field = EditableTextField(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)

        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(
        value: String,
        editable: Bool,
        dimmed: Bool,
        commitHandler: @escaping (String) -> Void
    ) {
        field.originalValue = value == "…" ? "" : value
        field.stringValue = value
        field.isEditable = editable
        field.textColor = dimmed ? NSColor.secondaryLabelColor : NSColor.labelColor
        field.commitHandler = commitHandler
    }
}

@MainActor
private final class EditableTextField: NSTextField, NSTextFieldDelegate {
    var commitHandler: ((String) -> Void)?
    var originalValue = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        lineBreakMode = .byTruncatingTail
        backgroundColor = .clear
        font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textColor = .labelColor
        usesSingleLineMode = true
        isSelectable = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder, let editor = currentEditor() as? NSTextView {
            editor.drawsBackground = false
            editor.backgroundColor = .clear
            editor.insertionPointColor = NSColor.labelColor
            editor.textColor = textColor
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(calibratedWhite: 0, alpha: 0.08),
                .foregroundColor: NSColor.labelColor,
            ]
        }
        return didBecomeFirstResponder
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        let movement = notification.userInfo?["NSTextMovement"] as? Int
        if movement == NSCancelTextMovement {
            stringValue = originalValue
            return
        }

        guard isEditable else { return }
        guard stringValue != originalValue else { return }
        commitHandler?(stringValue)
        originalValue = stringValue
    }
}
