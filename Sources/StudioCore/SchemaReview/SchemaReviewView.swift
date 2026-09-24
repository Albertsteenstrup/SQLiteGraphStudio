import SwiftUI

extension SchemaChangeKind {
    var tint: Color { self == .removed ? .red : .blue }
    var symbol: String { self == .removed ? "−" : self == .added ? "+" : self == .modified ? "~" : "" }
}

struct SchemaChangeBadge: View {
    let change: SchemaTableChange
    var body: some View {
        if change.kind != .unchanged {
            HStack(spacing: 5) {
                if change.kind == .added || change.kind == .removed { Text(change.kind.label).foregroundStyle(change.kind.tint) }
                else {
                    if !change.added.isEmpty { Text("+\(change.added.count)").foregroundStyle(.blue) }
                    if !change.removed.isEmpty { Text("−\(change.removed.count)").foregroundStyle(.red) }
                    if !change.modified.isEmpty { Text("~\(change.modified.count)").foregroundStyle(.blue) }
                    if change.relationChanged { Text("↔").foregroundStyle(.blue) }
                    if change.badge.isEmpty { Text("Changed").foregroundStyle(.blue) }
                }
            }
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .fixedSize()
                .foregroundStyle(change.kind.tint)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.background, in: RoundedRectangle(cornerRadius: 5))
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(change.kind.tint, style: StrokeStyle(lineWidth: 1, dash: change.kind == .removed ? [3, 2] : [])) }
                .help("\(change.kind.label): \(change.added.count) fields added, \(change.removed.count) removed, \(change.modified.count) modified\(change.relationChanged ? "; relations changed" : "")")
        }
    }
}

/// An inner change border stays distinct from the existing outer group colour.
struct SchemaChangeBorder: View {
    let change: SchemaTableChange
    var body: some View {
        if change.kind != .unchanged {
            RoundedRectangle(cornerRadius: 13).inset(by: 5)
                .stroke(.background, lineWidth: 5)
                .overlay {
                    RoundedRectangle(cornerRadius: 13).inset(by: 5)
                        .stroke(change.kind.tint, style: StrokeStyle(lineWidth: 2, dash: change.kind == .removed ? [6, 4] : []))
                }
                .allowsHitTesting(false)
        }
    }
}

struct SchemaReviewWorkspaceView: View {
    @Bindable var session: AppSession
    let review: SchemaReviewDocument
    @State private var onlyChanges = true
    @State private var search = ""

    /// Whole-table removals and additions lead, because they carry the most consequence
    /// for the code that reads them; edits follow, then everything unchanged.
    nonisolated private static let kindOrder: [SchemaChangeKind] = [.removed, .added, .modified, .unchanged]

    /// The review's tables in reading order, built once per update.
    ///
    /// `SchemaTableChange.kind` compares whole before/after tables, so it is computed once
    /// per table here rather than inside a sort comparator or in each part of the panel;
    /// a catalog of thousands of tables would otherwise stall every step and keystroke.
    private struct TableOrder {
        let all: [SchemaTableChange]
        let changed: [SchemaTableChange]
        let kinds: [String: SchemaChangeKind]

        init(_ changes: [String: SchemaTableChange]) {
            let kinds = changes.mapValues(\.kind)
            let rank = { (id: String) in kindOrder.firstIndex(of: kinds[id] ?? .unchanged) ?? 0 }
            all = changes.values.sorted { lhs, rhs in
                let lhsRank = rank(lhs.id), rhsRank = rank(rhs.id)
                return lhsRank == rhsRank ? lhs.id < rhs.id : lhsRank < rhsRank
            }
            changed = all.filter { kinds[$0.id] != .unchanged }
            self.kinds = kinds
        }

        func kind(_ change: SchemaTableChange) -> SchemaChangeKind { kinds[change.id] ?? .unchanged }
    }

    private var selected: SchemaTableChange? { session.selectedGraphNodeID.flatMap { session.schemaReviewChanges[$0] } }
    private var historicalArtifact: HistoricalExplanationArtifact? { session.historicalExplanationArtifact }
    private var isHistoricalExplanation: Bool { historicalArtifact != nil }

    var body: some View {
        let order = TableOrder(session.schemaReviewChanges)
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    // The producing agent and session lead when the review names them;
                    // the review's own title then reads as its subject.
                    if let author = review.author {
                        SchemaReviewAuthorLabel(author: author).font(.title3.bold())
                    }
                    HStack(spacing: 8) {
                        Text(review.title)
                            .font(review.author == nil ? .title3.bold() : .callout.weight(.medium))
                            .foregroundStyle(review.author == nil ? .primary : .secondary)
                            .lineLimit(1)
                        if review.proposal != nil {
                            Text("Proposed · not applied").font(.caption.bold()).fixedSize()
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.blue.opacity(0.1), in: Capsule())
                        }
                    }
                        Text(isHistoricalExplanation ? "Historical capture · \(review.headRef)" : "\(review.baseRef) → \(review.headRef)")
                            .font(.caption.monospaced()).lineLimit(1).textSelection(.enabled)
                }
                Spacer()
                if isHistoricalExplanation {
                    Text("\(order.all.count) captured \(order.all.count == 1 ? "table" : "tables")").font(.callout)
                    Label("Offline snapshot", systemImage: "clock.arrow.circlepath").foregroundStyle(.secondary)
                } else {
                    changeSummary(order).font(.callout)
                    Label("Added / changed", systemImage: "plus.square").foregroundStyle(.blue)
                    Label("Removed", systemImage: "minus.square").foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 16)
            GeometryReader { geometry in
              HStack(spacing: 0) {
                // Cards and labels are positioned freely inside the graph; without a clip
                // they would paint over, and take clicks meant for, the panel beside it.
                SchemaGraphView(session: session)
                    .frame(width: geometry.size.width * 0.56)
                    .clipped()
                    .contentShape(Rectangle())
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(isHistoricalExplanation ? "Captured tables" : "Tables").font(.headline)
                        Spacer()
                        if !isHistoricalExplanation { Toggle("Changes only", isOn: $onlyChanges).toggleStyle(.checkbox) }
                    }
                    TextField("Find a table", text: $search).textFieldStyle(.roundedBorder)
                    tableList(order).frame(minHeight: 100, idealHeight: 170, maxHeight: 220)
                    Divider()
                    if let historicalArtifact {
                        HistoricalExplanationDetailsView(artifact: historicalArtifact, selectedTable: selected?.table,
                                                        replayView: session.historicalReplayView,
                                                        currentLeftPane: session.leftPane.kind,
                                                        currentRightPane: session.rightPane.kind)
                    } else if let selected {
                        focusBar(for: selected, changed: order.changed)
                        SchemaReviewTableDetail(change: selected, relations: review.relationChanges, isPreview: review.proposal != nil)
                    } else { allChangesSummary(order.changed) }
                }
                .padding(16)
                .frame(width: geometry.size.width * 0.44 - 1)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
              }
            }
            HStack {
                Text(isHistoricalExplanation
                    ? "Historical schema and explicitly saved rows · no live source or queries · values may be truncated"
                    : review.proposal == nil ? "Schema comparison · no row data · solid blue = added/changed · dashed red = removed · unchanged relations appear when zoomed in"
                    : "Preview · no SQL executed · updates automatically")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = session.schemaPreviewReloadError {
                    Label("Preview update failed", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red).help(error)
                }
                Spacer()
                if !review.notes.isEmpty {
                    Menu("Review notes") { ForEach(Array(review.notes.enumerated()), id: \.offset) { _, note in Text(note) } }
                }
            }.padding(.horizontal, 16)
        }
        .padding(.vertical, 16)
        .onAppear { if isHistoricalExplanation { onlyChanges = false } }
        .task(id: review.proposal == nil ? nil : session.databaseURL) {
            guard review.proposal != nil else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                session.refreshSchemaPreviewIfChanged()
            }
        }
    }

    @ViewBuilder
    private func changeSummary(_ order: TableOrder) -> some View {
        let counts = Dictionary(grouping: order.changed, by: order.kind).mapValues(\.count)
        if counts.isEmpty {
            Text("No changed tables")
        } else {
            HStack(spacing: 10) {
                ForEach(Self.kindOrder.filter { counts[$0] != nil }, id: \.self) { kind in
                    Text("\(counts[kind] ?? 0) \(kind.label.lowercased())").foregroundStyle(kind.tint)
                }
            }
            .fixedSize()
        }
    }

    private func tableList(_ order: TableOrder) -> some View {
        let visible = (onlyChanges ? order.changed : order.all).filter { search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) }
        let sections = Dictionary(grouping: visible, by: order.kind)
        let kinds = Self.kindOrder.filter { sections[$0] != nil }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                    ForEach(kinds, id: \.self) { kind in
                        let rows = sections[kind] ?? []
                        Section {
                            ForEach(rows) { change in row(for: change, kind: kind) }
                        } header: {
                            Text("\(kind.label) · \(rows.count)")
                                .font(.caption.bold()).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color(nsColor: .windowBackgroundColor))
                        }
                    }
                }
            }
            .onChange(of: session.selectedGraphNodeID) { _, id in
                // Choosing in the graph or stepping through changes keeps the list in step.
                guard let id else { return }
                withAnimation(.snappy(duration: 0.18)) { proxy.scrollTo(id) }
            }
        }
    }

    private func row(for change: SchemaTableChange, kind: SchemaChangeKind) -> some View {
        let isSelected = selected?.id == change.id
        return Button {
            // Choosing the table already in focus again returns to every change.
            if isSelected { session.clearGraphSelection() } else { session.revealGraphNode(change.id) }
        } label: {
            HStack {
                Text(change.table.displayName).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                SchemaChangeBadge(change: change)
            }
            .padding(8)
            .background(isSelected ? Color.accentColor.opacity(0.12) : kind == .unchanged ? .clear : kind.tint.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(kind == .removed ? 0.7 : 1)
        }
        .buttonStyle(.plain)
        .id(change.id)
        .help(isSelected ? "Show all changes" : "Show only this table's changes")
    }

    /// Stepping through changes one at a time, the way a code diff is read hunk by hunk.
    private func focusBar(for selected: SchemaTableChange, changed: [SchemaTableChange]) -> some View {
        let index = changed.firstIndex { $0.id == selected.id }
        let previous = index.flatMap { $0 > 0 ? changed[$0 - 1] : nil }
        let next = index.map { $0 + 1 < changed.count ? changed[$0 + 1] : nil } ?? changed.first
        return HStack(spacing: 6) {
            Button { previous.map { session.revealGraphNode($0.id) } } label: { Image(systemName: "chevron.up") }
                .disabled(previous == nil)
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .help("Previous change (⌥⌘↑)")
            Button { next.map { session.revealGraphNode($0.id) } } label: { Image(systemName: "chevron.down") }
                .disabled(next == nil)
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .help("Next change (⌥⌘↓)")
            Text(index.map { "Change \($0 + 1) of \(changed.count)" } ?? "Unchanged table")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Button("Show All Changes") { session.clearGraphSelection() }
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func allChangesSummary(_ changed: [SchemaTableChange]) -> some View {
        if let first = changed.first {
            VStack(alignment: .leading, spacing: 8) {
                Text("Showing all \(changed.count) changed \(changed.count == 1 ? "table" : "tables")").font(.headline)
                Text("Choose a table to see only its changes in the graph and compare its fields here.")
                    .foregroundStyle(.secondary)
                Button("Review First Change") { session.revealGraphNode(first.id) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    .help("Start with \(first.table.displayName) (⌥⌘↓)")
            }
        } else {
            Text("No schema changes. Select a table to see its fields.").foregroundStyle(.secondary)
        }
    }
}

private struct HistoricalExplanationDetailsView: View {
    let artifact: HistoricalExplanationArtifact
    let selectedTable: SchemaReviewSnapshot.Table?
    let replayView: HistoricalExplanationArtifact.CapturedReplayView?
    let currentLeftPane: PaneContentKind
    let currentRightPane: PaneContentKind

    private var tablePages: [HistoricalExplanationArtifact.CapturedTablePage] {
        selectedTable.map { table in artifact.tablePages.filter { $0.tableID == table.id } } ?? []
    }

    private var replayPane: PaneContentKind? {
        guard let replayView else { return nil }
        let right = replayView.rightPane.flatMap(PaneContentKind.init(rawValue:))
        let left = replayView.leftPane.flatMap(PaneContentKind.init(rawValue:))
        if let right, right != .schema { return right }
        if let left, left != .schema { return left }
        if !replayView.tablePages.isEmpty && replayView.queryResults.isEmpty { return .tables }
        if replayView.tablePages.isEmpty && !replayView.queryResults.isEmpty { return .query }
        return right ?? left ?? (currentRightPane == .schema ? currentLeftPane : currentRightPane)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(selectedTable?.displayName ?? "Saved explanation")
                    .font(.headline).textSelection(.enabled)
                Text("Captured \(artifact.capturedAt.formatted(date: .abbreviated, time: .shortened)) · historical data")
                    .font(.caption).foregroundStyle(.secondary)
                if let replayView {
                    historicalReplayContent(replayView)
                } else {
                    if let selectedTable {
                        Text("Fields").font(.subheadline.bold())
                        ForEach(selectedTable.columns) { column in
                            HStack(alignment: .top, spacing: 8) {
                                Text(column.name).font(.caption.monospaced())
                                Spacer(minLength: 4)
                                Text(column.description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if !tablePages.isEmpty {
                            ForEach(Array(tablePages.enumerated()), id: \.offset) { _, tablePage in
                                CapturedExplanationRows(label: "Saved table rows from row \(tablePage.displayedOffset + 1)",
                                    columns: tablePage.columns, rows: tablePage.rows, omittedRows: tablePage.omittedRows)
                            }
                        } else {
                            Text("No table rows were included for this table.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !artifact.queryResults.isEmpty {
                        Divider()
                        Text("Captured query results").font(.subheadline.bold())
                        ForEach(artifact.queryResults, id: \.resultID) { result in
                            CapturedExplanationRows(label: "Result · rows from \(result.displayedOffset + 1)",
                                columns: result.columns, rows: result.rows, omittedRows: result.omittedRows)
                        }
                    }
                    if !artifact.points.isEmpty {
                        Divider()
                        Text("Explanation captions").font(.subheadline.bold())
                        ForEach(artifact.points, id: \.id) { point in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(point.caption).font(.caption)
                                if let narration = point.narration, !narration.isEmpty {
                                    Text(narration).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func historicalReplayContent(_ view: HistoricalExplanationArtifact.CapturedReplayView) -> some View {
        Text(view.caption).font(.subheadline.weight(.medium)).textSelection(.enabled)
        Text("Showing only rows saved for this explanation step. The original source is not contacted.")
            .font(.caption).foregroundStyle(.secondary)

        switch replayPane {
        case .some(.schema):
            if let selectedTable {
                Text("Fields · \(selectedTable.displayName)").font(.subheadline.bold())
                ForEach(selectedTable.columns) { column in
                    HStack(alignment: .top, spacing: 8) {
                        Text(column.name).font(.caption.monospaced())
                        Spacer(minLength: 4)
                        Text(column.description).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("No table is selected for this step.").font(.caption).foregroundStyle(.secondary)
            }
        case .some(.tables):
            Text("Captured table rows").font(.subheadline.bold())
            if view.tablePages.isEmpty {
                Text("No table rows were included for this step.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(view.tablePages.enumerated()), id: \.offset) { _, page in
                    let name = artifact.schema.tables.first(where: { $0.id == page.tableID })?.displayName ?? page.tableID
                    CapturedExplanationRows(label: "\(name) · rows from \(page.displayedOffset + 1)",
                        columns: page.columns, rows: page.rows, omittedRows: page.omittedRows)
                }
            }
        case .some(.query):
            Text("Captured query results").font(.subheadline.bold())
            if view.queryResults.isEmpty {
                Text("No query rows were included for this step.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(view.queryResults, id: \.resultID) { result in
                    CapturedExplanationRows(label: "Result · rows from \(result.displayedOffset + 1)",
                        columns: result.columns, rows: result.rows, omittedRows: result.omittedRows)
                }
            }
        case .none:
            if view.tablePages.isEmpty && view.queryResults.isEmpty {
                Text("No table or query rows were included for this step.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(view.tablePages.enumerated()), id: \.offset) { _, page in
                    let name = artifact.schema.tables.first(where: { $0.id == page.tableID })?.displayName ?? page.tableID
                    CapturedExplanationRows(label: "\(name) · rows from \(page.displayedOffset + 1)",
                        columns: page.columns, rows: page.rows, omittedRows: page.omittedRows)
                }
                ForEach(view.queryResults, id: \.resultID) { result in
                    CapturedExplanationRows(label: "Result · rows from \(result.displayedOffset + 1)",
                        columns: result.columns, rows: result.rows, omittedRows: result.omittedRows)
                }
            }
        }
    }
}

private struct CapturedExplanationRows: View {
    let label: String
    let columns: [HistoricalExplanationArtifact.CapturedColumn]
    let rows: [HistoricalExplanationArtifact.CapturedRow]
    let omittedRows: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption.bold())
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 2) {
                    row(columns.map(\.name), header: true)
                    ForEach(Array(rows.prefix(50)), id: \.ordinal) { item in
                        row(item.values.map(display), header: false)
                    }
                }
            }
            if omittedRows > 0 {
                Text("\(omittedRows) additional rows were not captured.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ values: [String], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value).font(header ? .caption2.bold().monospaced() : .caption2.monospaced())
                    .lineLimit(2).frame(width: 110, alignment: .leading)
            }
        }
    }

    private func display(_ cell: HistoricalExplanationArtifact.CapturedCell) -> String {
        if let value = cell.value { return cell.truncated ? String(value.prefix(120)) + "…" : value }
        if cell.type == "null" { return "NULL" }
        if cell.type == "blob" { return "<\(cell.byteCount ?? 0) bytes>" }
        if cell.type == "redacted" { return "Redacted" }
        return "—"
    }
}

private struct SchemaReviewTableDetail: View {
    let change: SchemaTableChange
    let relations: [SchemaReviewDocument.RelationChange]
    let isPreview: Bool
    private var fields: [String] { (change.after?.columns.map(\.name) ?? []) + change.removed.map(\.name) }
    private var metadataKeys: [String] { Set(change.before?.metadata.keys.map { $0 } ?? []).union(change.after?.metadata.keys.map { $0 } ?? []).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(change.table.displayName).font(.headline).textSelection(.enabled); Spacer(); SchemaChangeBadge(change: change) }
            ScrollView(.horizontal) {
              VStack(alignment: .leading, spacing: 0) {
                fieldRow("Field", before: isPreview ? "Captured" : "Before", after: isPreview ? "Proposed" : "After", kind: .unchanged).fontWeight(.semibold).background(.background)
                ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(fields, id: \.self) { name in
                            let kind = change.columnKind(name)
                            fieldRow(kind.symbol + " " + name,
                                     before: change.before?.columns.first { $0.name == name }?.description ?? "—",
                                     after: change.after?.columns.first { $0.name == name }?.description ?? "—", kind: kind)
                        }
                    }
                    if change.before?.kind != change.after?.kind {
                        Text("Object: \(change.before?.kind ?? "—") → \(change.after?.kind ?? "—")").font(.caption)
                    }
                    let changedRelations = relations.filter { $0.kind != .unchanged && ($0.relation.source == change.id || $0.relation.target == change.id) }
                    if !changedRelations.isEmpty {
                        Text("Relations").font(.headline)
                        ForEach(changedRelations, id: \.graphID) { item in
                            Text("\(item.kind.symbol) \(item.relation.source) (\(item.relation.sourceColumns.joined(separator: ", "))) → \(item.relation.target) (\(item.relation.targetColumns.joined(separator: ", ")))\n\(item.relation.definition)")
                                .font(.caption.monospaced()).foregroundStyle(item.kind.tint).textSelection(.enabled)
                        }
                    }
                    ForEach(isPreview ? [] : metadataKeys.filter { change.before?.metadata[$0] != change.after?.metadata[$0] }, id: \.self) { key in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(metadataTitle(key)).font(.caption.bold())
                            if let value = change.before?.metadata[key] { Text("− " + value).foregroundStyle(.red) }
                            if let value = change.after?.metadata[key] { Text("+ " + value).foregroundStyle(.blue) }
                        }.font(.caption.monospaced()).textSelection(.enabled)
                    }
                }.frame(width: 640, alignment: .leading)
                }
              }
            }
        }
        .id(change.id)
    }

    private func fieldRow(_ name: String, before: String, after: String, kind: SchemaChangeKind) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(name).frame(width: 132, alignment: .leading)
            Text(before).frame(width: 230, alignment: .leading)
            Text(after).frame(width: 230, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .foregroundStyle(kind == .unchanged ? Color.primary : kind.tint)
        .background(kind == .unchanged ? Color.clear : kind.tint.opacity(0.07))
    }
    private func metadataTitle(_ key: String) -> String {
        if key.hasPrefix("constraint:"), key.count == 75 { return "Constraint" }
        if key == "withoutRowID" { return "Without row ID" }
        return key.replacingOccurrences(of: ":", with: ": ")
    }
}
