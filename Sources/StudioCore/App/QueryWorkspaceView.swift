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

                            Text("Read-only query mode for `SELECT`, `WITH`, `PRAGMA`, and `EXPLAIN`.")
                                .font(.caption)
                                .foregroundStyle(StudioPalette.secondaryText)

                            Text(activeQuery.isSaved ? "Saved with this database" : "Unsaved query")
                                .font(.caption2)
                                .foregroundStyle(StudioPalette.secondaryText)
                        }

                        Spacer()

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

                        Button {
                            session.queryWorkspace.run()
                        } label: {
                            Label("Run Query", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .tint(StudioPalette.accent)

                        if activeQuery.isRunning {
                            ProgressView()
                                .controlSize(.small)
                                .tint(StudioPalette.accent)
                        }
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

                    QueryResultsView(result: activeQuery.result)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    Button {
                        session.queryWorkspace.selectQuery(id: query.id)
                    } label: {
                        HStack(spacing: 8) {
                            if query.isSaved {
                                Image(systemName: "bookmark.fill")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(StudioPalette.secondaryText)
                            }

                            Text(query.title)
                                .lineLimit(1)
                                .foregroundStyle(StudioPalette.primaryText)

                            Button {
                                session.queryWorkspace.closeQuery(id: query.id)
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
                                .fill(session.queryWorkspace.activeQueryID == query.id ? StudioPalette.selectionSurfaceTop : StudioPalette.headerSurface.opacity(0.84))
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(session.queryWorkspace.activeQueryID == query.id ? StudioPalette.border : StudioPalette.borderSoft)
                        }
                    }
                    .buttonStyle(.plain)
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

private struct QueryResultsView: View {
    let result: QueryResult

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
                QueryResultsGridRepresentable(result: result)
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

    func makeCoordinator() -> Coordinator {
        Coordinator(result: result)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(result: result, scrollView: nsView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var result: QueryResult
        private weak var tableView: NSTableView?

        init(result: QueryResult) {
            self.result = result
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

            let tableView = NSTableView()
            let headerView = QueryResultsHeaderView()
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
            self.tableView = tableView
            syncColumns(on: tableView)
            return scrollView
        }

        func update(result: QueryResult, scrollView: NSScrollView) {
            self.result = result
            guard let tableView else { return }
            syncColumns(on: tableView)
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
                  let columnIndex = result.columns.firstIndex(where: { $0.name == tableColumn.identifier.rawValue })
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
            let currentNames = tableView.tableColumns.map(\.identifier.rawValue)
            let desiredNames = result.columns.map(\.name)
            guard currentNames != desiredNames else { return }

            for column in tableView.tableColumns {
                tableView.removeTableColumn(column)
            }

            for column in result.columns {
                let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.name))
                let headerCell = MetadataHeaderCell(title: column.name, subtitle: column.typeLabel)
                headerCell.showsChevron = false
                tableColumn.headerCell = headerCell
                tableColumn.title = column.name
                tableColumn.width = max(168, CGFloat(column.name.count) * 12 + 64)
                tableColumn.minWidth = 132
                tableView.addTableColumn(tableColumn)
            }
        }
    }
}

@MainActor
private final class QueryResultsHeaderView: NSTableHeaderView {
    override var isOpaque: Bool {
        true
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
}

@MainActor
private final class QueryResultCellView: NSTableCellView {
    private let field = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
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
