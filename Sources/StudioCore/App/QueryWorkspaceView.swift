import AppKit
import Observation
import SwiftUI

public struct QueryWorkspaceView: View {
    @Bindable private var session: AppSession

    public init(session: AppSession) {
        self.session = session
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            queryTabStrip

            if let activeQuery = session.queryWorkspace.activeQuery {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField(
                                "Query Title",
                                text: Binding(
                                    get: { session.queryWorkspace.activeQuery?.title ?? "" },
                                    set: { session.queryWorkspace.updateActiveTitle($0) }
                                )
                            )
                            .textFieldStyle(.plain)
                            .font(.headline)
                            .foregroundStyle(StudioPalette.primaryText)
                        }

                        Spacer()

                        if !session.queryWorkspace.history.isEmpty {
                            Menu {
                                ForEach(session.queryWorkspace.history) { entry in
                                    Menu(entry.title) {
                                        Button("Open") {
                                            session.queryWorkspace.createQuery(
                                                title: entry.title,
                                                sqlText: entry.sqlText,
                                                activate: true,
                                                runImmediately: false,
                                                isSaved: false
                                            )
                                        }
                                        Button("Remove", role: .destructive) {
                                            session.queryWorkspace.removeHistoryEntry(id: entry.id)
                                        }
                                    }
                                }
                                Divider()
                                Button("Clear History", role: .destructive) {
                                    session.queryWorkspace.clearHistory()
                                }
                            } label: {
                                Label("History", systemImage: "clock.arrow.circlepath")
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(StudioPalette.accent)
                            .help("Query history")
                        }

                        Button {
                            session.queryWorkspace.setActiveQuerySaved(!activeQuery.isSaved)
                        } label: {
                            Label(
                                activeQuery.isSaved ? "Saved" : "Save Query",
                                systemImage: activeQuery.isSaved ? "bookmark.fill" : "bookmark"
                            )
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(StudioPalette.accent)
                        .help(activeQuery.isSaved ? "Unsave query" : "Save query")

                        Button {
                            session.queryWorkspace.explain()
                        } label: {
                            Label("Explain", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(StudioPalette.accent)
                        .help("Explain query plan")

                        Button {
                            session.queryWorkspace.run()
                        } label: {
                            Label("Run Query", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .tint(StudioPalette.accent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Run Query (Command-Enter)")

                        Menu {
                            Picker("Query timeout", selection: $session.queryWorkspace.timeoutSeconds) {
                                ForEach([5.0, 15.0, 30.0, 60.0, 120.0], id: \.self) { seconds in
                                    Text("\(Int(seconds)) seconds").tag(seconds)
                                }
                            }
                        } label: {
                            Label("\(Int(session.queryWorkspace.timeoutSeconds))s", systemImage: "timer")
                        }
                        .help("Maximum query execution time")

                        if activeQuery.isRunning {
                            Button("Stop", systemImage: "stop.fill") {
                                session.queryWorkspace.stop()
                            }
                            .buttonStyle(.bordered)
                            .keyboardShortcut(".", modifiers: .command)
                            .help("Stop query (Command-Period)")
                            ProgressView()
                                .controlSize(.small)
                                .tint(StudioPalette.accent)
                        }

                        Menu {
                            Text(session.queryExportScopeLabel)
                            Button("Export CSV") {
                                session.exportActiveQueryResult(format: .csv)
                            }
                            Button("Export JSON") {
                                session.exportActiveQueryResult(format: .json)
                            }
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(StudioPalette.accent)
                        .help("Export query results")
                        .disabled(session.exportProgress?.isRunning == true)
                    }

                    TextEditor(
                        text: Binding(
                            get: { session.queryWorkspace.activeQuery?.sqlText ?? "" },
                            set: { session.queryWorkspace.updateActiveSQL($0) }
                        )
                    )
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(StudioPalette.primaryText)
                    .padding(14)
                    .scrollContentBackground(.hidden)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(StudioPalette.editorSurface)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(StudioPalette.borderSoft)
                    }
                    .frame(minHeight: 150)

                    if let errorMessage = activeQuery.errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(Color.red.opacity(0.92))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Picker(
                            "Output",
                            selection: Binding(
                                get: { session.queryWorkspace.activeQuery?.selectedOutput ?? .results },
                                set: { session.queryWorkspace.selectActiveOutput($0) }
                            )
                        ) {
                            Text("Results").tag(QueryOutputKind.results)
                            Text("Plan").tag(QueryOutputKind.plan)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)

                        switch activeQuery.selectedOutput {
                        case .results:
                            QueryResultsView(
                                result: activeQuery.result,
                                columnDescription: { session.descriptionForQueryResultColumn($0) },
                                inspectRow: { session.inspectQueryRecord(result: activeQuery.result, row: $0) }
                            )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        case .plan:
                            QueryPlanView(plan: activeQuery.explainPlan)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "terminal")
                        .font(.system(size: 30))
                        .foregroundStyle(StudioPalette.secondaryText)
                    Text("Create a query to inspect tables and views.")
                        .foregroundStyle(StudioPalette.secondaryText)
                    Button {
                        session.queryWorkspace.createQuery()
                    } label: {
                        Label("New Query", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(StudioPalette.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
    }

    private var queryTabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(session.queryWorkspace.queries) { query in
                    QueryTabView(
                        query: query,
                        isActive: session.queryWorkspace.activeQueryID == query.id,
                        onSelect: { session.queryWorkspace.selectQuery(id: query.id) },
                        onClose: { session.queryWorkspace.closeQuery(id: query.id) },
                        onRename: { session.queryWorkspace.updateTitle($0, for: query.id) }
                    )
                }

                Button {
                    session.queryWorkspace.createQuery()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(StudioPalette.primaryText)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(StudioPalette.headerSurface.opacity(0.84))
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(StudioPalette.borderSoft)
                        }
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 4)
        }
    }
}

private struct QueryTabView: View {
    let query: QueryDocument
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void

    @State private var isEditing = false
    @State private var editingTitle = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if query.isSaved {
                Image(systemName: "bookmark.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(StudioPalette.secondaryText)
            }

            if isEditing {
                TextField("", text: $editingTitle)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(StudioPalette.primaryText)
                    .focused($fieldFocused)
                    .frame(minWidth: 60)
                    .onSubmit { commitRename() }
                    .onExitCommand { cancelRename() }
            } else {
                Text(query.title)
                    .lineLimit(1)
                    .foregroundStyle(StudioPalette.primaryText)
            }

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.bold())
                    .foregroundStyle(StudioPalette.secondaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isActive ? StudioPalette.selectionSurfaceTop : StudioPalette.headerSurface.opacity(0.84))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isActive ? StudioPalette.border : StudioPalette.borderSoft)
        }
        .onTapGesture { onSelect() }
        .onTapGesture(count: 2) { startEditing() }
    }

    private func startEditing() {
        editingTitle = query.title
        isEditing = true
        fieldFocused = true
    }

    private func commitRename() {
        let trimmed = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            onRename(trimmed)
        }
        isEditing = false
    }

    private func cancelRename() {
        isEditing = false
    }
}

private struct QueryPlanView: View {
    let plan: [ExplainPlanRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Explain Plan")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudioPalette.primaryText)
                Spacer()
                Text("\(plan.count.formatted()) steps")
                    .font(.caption)
                    .foregroundStyle(StudioPalette.secondaryText)
            }

            if plan.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.system(size: 28))
                        .foregroundStyle(StudioPalette.secondaryText)
                    Text("Run Explain to inspect the database's query plan.")
                        .foregroundStyle(StudioPalette.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(StudioPalette.gridSurface)
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(plan) { row in
                            HStack(spacing: 12) {
                                Text("\(row.id)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(StudioPalette.secondaryText)
                                    .frame(width: 36, alignment: .trailing)
                                Text(row.detail)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(StudioPalette.primaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)

                            Divider()
                                .overlay(StudioPalette.divider)
                        }
                    }
                }
                .background(StudioPalette.gridSurface)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(StudioPalette.borderSoft)
                }
            }
        }
    }
}

private struct QueryResultsView: View {
    let result: QueryResult
    let columnDescription: (String) -> String?
    let inspectRow: (QueryResultRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Results")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudioPalette.primaryText)
                Spacer()
                Text("\(result.rows.count.formatted()) rows")
                    .font(.caption)
                    .foregroundStyle(StudioPalette.secondaryText)
                if result.isTruncated {
                    Text("Showing first \(result.rowLimit.formatted()) rows")
                        .font(.caption)
                        .foregroundStyle(StudioPalette.secondaryText)
                }
            }

            if result.columns.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.system(size: 28))
                        .foregroundStyle(StudioPalette.secondaryText)
                    Text("Run a read-only query to inspect result rows here.")
                        .foregroundStyle(StudioPalette.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(StudioPalette.gridSurface)
                )
            } else {
                QueryResultsGridRepresentable(
                    result: result,
                    columnDescription: columnDescription,
                    inspectRow: inspectRow
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(StudioPalette.gridSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(StudioPalette.borderSoft)
                    }
            }
        }
    }
}

private struct QueryResultsGridRepresentable: NSViewRepresentable {
    let result: QueryResult
    let columnDescription: (String) -> String?
    let inspectRow: (QueryResultRow) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(result: result, columnDescription: columnDescription, inspectRow: inspectRow)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(
            result: result,
            columnDescription: columnDescription,
            scrollView: nsView,
            inspectRow: inspectRow
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var result: QueryResult
        private var renderedColumns: [QueryResultColumn] = []
        private var columnDescription: (String) -> String?
        private var inspectRow: (QueryResultRow) -> Void
        private weak var tableView: NSTableView?
        private weak var headerView: QueryResultsHeaderView?

        init(result: QueryResult, columnDescription: @escaping (String) -> String?, inspectRow: @escaping (QueryResultRow) -> Void) {
            self.result = result
            self.inspectRow = inspectRow
            self.columnDescription = columnDescription
        }

        func makeScrollView() -> NSScrollView {
            let scrollView = NSScrollView()
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = true
            scrollView.backgroundColor = NSColor(calibratedWhite: 0.985, alpha: 1)
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay

            let tableView = CopyOnlyQueryTableView()
            tableView.keyHandler = { [weak self] event in
                self?.handleKeyEvent(event) ?? false
            }
            tableView.contextMenuHandler = { [weak self] event in
                self?.buildContextMenu(for: event)
            }
            let headerView = QueryResultsHeaderView()
            headerView.frame.size.height = 58
            headerView.descriptionForColumn = columnDescription

            tableView.headerView = headerView
            tableView.usesAlternatingRowBackgroundColors = false
            tableView.selectionHighlightStyle = .none
            tableView.allowsMultipleSelection = true
            tableView.allowsColumnSelection = true
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
            self.tableView = tableView
            self.headerView = headerView
            syncColumns(on: tableView)
            return scrollView
        }

        func update(
            result: QueryResult,
            columnDescription: @escaping (String) -> String?,
            scrollView: NSScrollView,
            inspectRow: @escaping (QueryResultRow) -> Void
        ) {
            self.result = result
            self.inspectRow = inspectRow
            self.columnDescription = columnDescription
            headerView?.descriptionForColumn = columnDescription
            guard let tableView else { return }
            syncColumns(on: tableView)
            applyHeaderDescriptions(on: tableView)
            tableView.noteNumberOfRowsChanged()
            tableView.reloadData()
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            result.rows.count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            44
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = GridRowView()
            rowView.rowIndex = row
            return rowView
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn,
                  let columnIndex = result.columns.firstIndex(where: { String($0.id) == tableColumn.identifier.rawValue })
            else {
                return nil
            }

            let identifier = NSUserInterfaceItemIdentifier("QueryResultCellView")
            let view = (tableView.makeView(withIdentifier: identifier, owner: nil) as? QueryResultCellView) ?? QueryResultCellView(frame: .zero)
            view.identifier = identifier
            let value = result.rows[row].values[columnIndex]
            view.configure(value: value.displayText, dimmed: value == .null)
            return view
        }

        private func syncColumns(on tableView: NSTableView) {
            guard renderedColumns != result.columns else { return }
            renderedColumns = result.columns

            for column in tableView.tableColumns {
                tableView.removeTableColumn(column)
            }

            for column in result.columns {
                let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(column.id)))
                let headerCell = MetadataHeaderCell(title: column.name, subtitle: column.typeLabel)
                headerCell.showsChevron = false
                headerCell.hasDescription = columnDescription(column.name) != nil
                tableColumn.headerCell = headerCell
                tableColumn.headerToolTip = nil
                tableColumn.title = column.name
                tableColumn.width = max(168, CGFloat(column.name.count) * 12 + 64)
                tableColumn.minWidth = 132
                tableView.addTableColumn(tableColumn)
            }
        }

        private func applyHeaderDescriptions(on tableView: NSTableView) {
            for tableColumn in tableView.tableColumns {
                tableColumn.headerToolTip = nil
                guard let headerCell = tableColumn.headerCell as? MetadataHeaderCell else { continue }
                headerCell.hasDescription = columnDescription(tableColumn.title) != nil
            }
            headerView?.rebuildDescriptionToolTips()
            tableView.headerView?.needsDisplay = true
        }

        private func handleKeyEvent(_ event: NSEvent) -> Bool {
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "c"
            else {
                return false
            }

            copySelection()
            return true
        }

        func buildContextMenu(for event: NSEvent) -> NSMenu? {
            guard let tableView else { return nil }

            let point = tableView.convert(event.locationInWindow, from: nil)
            let clickedRow = tableView.row(at: point)
            let clickedColumnIndex = tableView.column(at: point)

            let menu = NSMenu()
            let inspectItem = NSMenuItem(title: "Inspect Record…", action: #selector(contextMenuInspect(_:)), keyEquivalent: "")
            inspectItem.target = self
            inspectItem.representedObject = clickedRow
            inspectItem.isEnabled = result.rows.indices.contains(clickedRow)
            menu.addItem(inspectItem)
            menu.addItem(.separator())

            // Copy cell value
            let copyCellItem = NSMenuItem(title: "Copy Cell", action: #selector(contextMenuCopyCell(_:)), keyEquivalent: "")
            copyCellItem.target = self
            copyCellItem.representedObject = [clickedRow, clickedColumnIndex] as [Int]
            copyCellItem.isEnabled = clickedRow >= 0 && result.rows.indices.contains(clickedRow)
                && clickedColumnIndex >= 0 && result.columns.indices.contains(clickedColumnIndex)
            menu.addItem(copyCellItem)

            menu.addItem(NSMenuItem.separator())

            // Copy selected rows
            let copyRowsItem = NSMenuItem(title: "Copy", action: #selector(contextMenuCopyRows(_:)), keyEquivalent: "")
            copyRowsItem.target = self
            copyRowsItem.isEnabled = true
            menu.addItem(copyRowsItem)

            return menu
        }

        @objc func contextMenuInspect(_ sender: NSMenuItem) {
            guard let row = sender.representedObject as? Int, result.rows.indices.contains(row) else { return }
            inspectRow(result.rows[row])
        }

        @objc func contextMenuCopyCell(_ sender: NSMenuItem) {
            guard let indices = sender.representedObject as? [Int],
                  indices.count == 2
            else { return }
            let row = indices[0]
            guard let tableView, tableView.tableColumns.indices.contains(indices[1]),
                  let col = Int(tableView.tableColumns[indices[1]].identifier.rawValue) else { return }
            guard result.rows.indices.contains(row),
                  result.columns.indices.contains(col)
            else { return }
            let text = ResultSerialization.exactText(result.rows[row].values[col])
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        @objc func contextMenuCopyRows(_ sender: Any?) {
            copySelection()
        }

        private func copySelection() {
            guard let tableView else { return }
            let selectedRows = tableView.selectedRowIndexes
            guard !selectedRows.isEmpty else { return }
            let visualColumns = tableView.selectedColumnIndexes.isEmpty
                ? IndexSet(integersIn: tableView.tableColumns.indices)
                : tableView.selectedColumnIndexes
            let selectedColumns = visualColumns.compactMap { Int(tableView.tableColumns[$0].identifier.rawValue) }

            var lines: [String] = []
            let header = selectedColumns.compactMap { index in
                result.columns.indices.contains(index) ? result.columns[index].name : nil
            }
            lines.append(header.joined(separator: "\t"))

            for rowIndex in selectedRows {
                guard result.rows.indices.contains(rowIndex) else { continue }
                let row = result.rows[rowIndex]
                let values = selectedColumns.compactMap { columnIndex in
                    row.values.indices.contains(columnIndex) ? ResultSerialization.exactText(row.values[columnIndex]) : nil
                }
                lines.append(values.joined(separator: "\t"))
            }

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        }
    }
}

@MainActor
private final class CopyOnlyQueryTableView: NSTableView {
    var keyHandler: ((NSEvent) -> Bool)?
    var contextMenuHandler: ((NSEvent) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuHandler?(event)
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true {
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class QueryResultsHeaderView: NSTableHeaderView {
    var descriptionForColumn: ((String) -> String?)?
    private var trackingArea: NSTrackingArea?
    private let descriptionHoverController = HeaderDescriptionHoverController()

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
        rebuildDescriptionToolTips()
    }

    func rebuildDescriptionToolTips() {
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let tableView else { return }
        for columnIndex in tableView.tableColumns.indices {
            let tableColumn = tableView.tableColumns[columnIndex]
            guard descriptionForColumn?(tableColumn.title) != nil,
                  let headerCell = tableColumn.headerCell as? MetadataHeaderCell,
                  headerCell.hasDescription
            else {
                continue
            }
            addCursorRect(headerCell.titleToolTipRect(for: headerRect(ofColumn: columnIndex)), cursor: .pointingHand)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            descriptionHoverController.clear()
        }
        super.viewWillMove(toWindow: newWindow)
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
        let point = convert(event.locationInWindow, from: nil)
        if let hit = descriptionHit(at: point) {
            descriptionHoverController.show(text: hit.description, key: hit.key, relativeTo: hit.rect, of: self)
        } else {
            descriptionHoverController.clear()
        }
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        descriptionHoverController.clear()
        super.mouseExited(with: event)
    }

    private func descriptionHit(at point: NSPoint) -> (key: String, description: String, rect: NSRect)? {
        guard let tableView else { return nil }
        let columnIndex = tableView.column(at: CGPoint(x: point.x, y: 1))
        guard columnIndex >= 0,
              tableView.tableColumns.indices.contains(columnIndex)
        else {
            return nil
        }

        let tableColumn = tableView.tableColumns[columnIndex]
        let columnName = tableColumn.title
        guard let description = descriptionForColumn?(columnName),
              let headerCell = tableColumn.headerCell as? MetadataHeaderCell,
              headerCell.hasDescription
        else {
            return nil
        }

        let titleRect = headerCell.titleToolTipRect(for: headerRect(ofColumn: columnIndex))
        guard titleRect.contains(point) else { return nil }
        return (key: columnName, description: description, rect: titleRect)
    }
}

@MainActor
private final class QueryResultCellView: NSTableCellView {
    private let field = QueryResultLabel(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.isSelectable = false
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

    func configure(value: String, dimmed: Bool) {
        field.stringValue = value
        field.textColor = dimmed ? NSColor.secondaryLabelColor : NSColor.labelColor
    }
}

/// A non-selectable, non-editable label that suppresses the system context menu
/// so right-clicks bubble up to the table view's custom menu.
@MainActor
private final class QueryResultLabel: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = false
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}
