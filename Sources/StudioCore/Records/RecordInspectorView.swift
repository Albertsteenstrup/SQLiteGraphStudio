import AppKit
import SwiftUI

public struct RecordExplorationView: View {
    @Bindable var session: AppSession
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { session.records.back() } label: { Image(systemName: "chevron.left") }
                    .disabled(!session.records.canGoBack).help("Back to the previous record or originating view")
                Button { session.records.forward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!session.records.canGoForward).help("Forward")
                VStack(alignment: .leading) {
                    Text(session.records.showsGraph ? "Record graph" : "Record inspector").font(.headline)
                    Text("From \(session.records.originLabel)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !session.records.loading.isEmpty {
                    ProgressView().controlSize(.small)
                    Button("Cancel requests") { session.records.cancel() }
                }
                if session.records.recordGraph.root != nil {
                    Toggle("Record graph", isOn: Binding(get: { session.records.showsGraph }, set: { session.records.showsGraph = $0 })).toggleStyle(.switch)
                }
                Button("Return to origin") { session.records.cancel(); session.records.isPresented = false }
                    .keyboardShortcut(.escape, modifiers: [])
            }.padding(16)
            Divider()
            if let notice = session.records.notice { Text(notice).foregroundStyle(.orange).padding(8) }
            if let record = session.records.current {
                if session.records.showsGraph {
                    HSplitView {
                        RecordGraphView(workspace: session.records).frame(minWidth: 420)
                        RecordInspectorView(session: session, record: record).frame(minWidth: 360, idealWidth: 440, maxWidth: 560)
                    }
                } else {
                    RecordInspectorView(session: session, record: record)
                }
            } else {
                ContentUnavailableView("No record selected", systemImage: "tablecells", description: Text("Right-click a loaded table or query row and choose Inspect Record."))
            }
        }
        .frame(minWidth: 960, idealWidth: 1160, minHeight: 660, idealHeight: 800)
    }
}

private struct RecordInspectorView: View {
    @Bindable var session: AppSession
    let record: RecordSnapshot
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(record.label).font(.title2.bold()).textSelection(.enabled)
                    Text(record.table?.displayName ?? "Query result snapshot").font(.subheadline).foregroundStyle(.secondary)
                    if let identity = record.identity {
                        Text(identity.locator.map { "\($0.columnName) = \(RecordValuePresentation.summary($0.value))" }.joined(separator: " · "))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Button("Show connections", systemImage: "point.3.connected.trianglepath.dotted") { session.records.showConnections() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Text(record.partialCellRead == nil
                             ? "Loaded values only. No proven unique locator is available; record graph and identity-dependent navigation are unavailable."
                             : "This is a bounded slice of one cell. Other fields and record identity were not loaded.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let table = record.descriptor?.name, let description = session.tableDescription(for: table) {
                        Text(description).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text("Values").font(.headline)
                ForEach(Array(record.columns.enumerated()), id: \.offset) { index, column in
                    if record.values.indices.contains(index) {
                        let sliceNavigation = session.gridCellSliceNavigation(for: record)
                        RecordValueView(column: column, value: record.values[index],
                                        description: record.descriptor.flatMap { session.columnDescription(for: $0.name, column: column.name) },
                                        partialRead: record.partialCellRead,
                                        sliceNavigation: sliceNavigation,
                                        onPreviousSlice: { _ = session.navigateGridCellSlice(for: record, direction: .previous) },
                                        onNextSlice: { _ = session.navigateGridCellSlice(for: record, direction: .next) },
                                        withReadSnapshot: { operation in
                                            try await session.withGridCellReadSnapshot(for: record, operation: operation)
                                        },
                                        onShowSlice: { read in session.showGridCellSlice(for: record, read: read) })
                            .id(record.partialCellRead == nil ? "\(record.id):\(index)" : "slice:\(session.records.originLabel):\(index)")
                    }
                }
                Divider()
                Text("Relationships").font(.headline)
                if record.partialCellRead != nil {
                    Text("Connections are unavailable for a cell slice because the row key was not loaded.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if record.table == nil {
                    Text("Query provenance is unverified. Values remain inspectable without inferring a source table.").font(.caption).foregroundStyle(.secondary)
                } else {
                    relationshipSection(.outgoing)
                    relationshipSection(.incoming)
                    ForEach(session.records.mappingValidationMessages, id: \.self) { message in
                        Text(message).font(.caption).foregroundStyle(.orange)
                    }
                    ForEach(session.records.mappings.filter { $0.nodeTable == record.table }) { mapping in
                        RecordMappingConnectionsView(workspace: session.records, mapping: mapping, direction: .outgoing)
                        RecordMappingConnectionsView(workspace: session.records, mapping: mapping, direction: .incoming)
                    }
                }
            }.padding(20)
        }.id(record.partialCellRead == nil ? record.id : "slice:\(session.records.originLabel)")
    }

    private func relationshipSection(_ direction: RecordDirection) -> some View {
        let relationships = session.records.relationships.filter {
            direction == .outgoing ? $0.sourceTable == record.table : $0.targetTable == record.table
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text(direction == .outgoing ? "Outgoing foreign keys" : "Incoming references").font(.subheadline.bold())
            if relationships.isEmpty { Text("No catalog relationships").font(.caption).foregroundStyle(.secondary) }
            ForEach(relationships) { relationship in
                RecordRelationshipView(workspace: session.records, relationship: relationship, direction: direction)
            }
        }
    }
}

private struct RecordRelationshipView: View {
    @Bindable var workspace: RecordWorkspace
    let relationship: RecordRelationship
    let direction: RecordDirection
    var body: some View {
        let key = workspace.key(relationship, direction)
        VStack(alignment: .leading, spacing: 8) {
            Text(direction == .outgoing ? relationship.targetTable.displayName : relationship.sourceTable.displayName).font(.subheadline.bold())
            Text("\(relationship.sourceColumns.joined(separator: ", ")) → \(relationship.targetColumns.joined(separator: ", "))")
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            HStack {
                Button("Browse records") { workspace.load(relationship, direction: direction) }
                if workspace.showsGraph {
                    Button("Expand graph") { workspace.load(relationship, direction: direction, intoGraph: true) }
                        .disabled(workspace.current?.identity == nil || workspace.current.flatMap { workspace.recordGraph.records[$0.id] } == nil)
                }
                if let key, workspace.loading.contains(key) { ProgressView().controlSize(.small) }
            }.disabled(key.map { workspace.loading.contains($0) } ?? true)
            if let key {
                if let error = workspace.errors[key] { Text(error).font(.caption).foregroundStyle(.red) }
                if let page = workspace.pages[key] {
                    switch page.status {
                    case .nullReference: Text("NULL relationship — no target is referenced.").font(.caption)
                    case .missingReference: Text("Referenced record was not found.").font(.caption)
                    case .unavailable: Text("Related table is unavailable or inaccessible.").font(.caption)
                    case .loaded:
                        if page.records.isEmpty { Text("No related records on this page.").font(.caption) }
                    }
                    ForEach(Array(page.records.enumerated()), id: \.offset) { _, related in
                        Button { workspace.navigate(related) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(related.label).lineLimit(2)
                                    Text(related.identity?.locator.map { "\($0.columnName)=\(RecordValuePresentation.summary($0.value))" }.joined(separator: ", ") ?? "Loaded row · no unique locator")
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer(); Image(systemName: "chevron.right")
                            }.padding(6)
                        }.buttonStyle(.plain)
                    }
                    HStack {
                        let offset = workspace.offsets[key, default: 0]
                        if offset > 0 {
                            Button("Previous page") { workspace.load(relationship, direction: direction, offset: max(0, offset - 25)) }
                        }
                        if page.hasMore, let next = page.nextOffset {
                            Button("Load more") { workspace.load(relationship, direction: direction, offset: next) }
                        }
                        Text(page.hasMore ? "More records available" : "End of related records").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct RecordValueView: View {
    typealias FullCellOperation = @MainActor @Sendable (BoundedCellSnapshotReader) async throws -> String
    typealias FullCellOperationRunner = @MainActor @Sendable (@escaping FullCellOperation) async throws -> String

    let column: QueryResultColumn
    let value: SQLiteValue
    let description: String?
    let partialRead: BoundedCellRead?
    let sliceNavigation: GridCellSliceNavigationState?
    let onPreviousSlice: () -> Void
    let onNextSlice: () -> Void
    let withReadSnapshot: FullCellOperationRunner
    let onShowSlice: (BoundedCellRead) -> Void
    @State private var expanded = false
    @State private var pretty = false
    @State private var content: String?
    @State private var copied = false
    @State private var searchText = ""
    @State private var lastFoundOffset: Int?
    @State private var operationStatus: String?
    @State private var operationTask: Task<Void, Never>?
    @State private var isOperating = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(column.name).font(.subheadline.bold()).textSelection(.enabled)
                Text(column.typeLabel).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copied" : (partialRead == nil ? "Copy exact value" : "Copy shown slice")) {
                    Task {
                        let value = value
                        let raw = await Task.detached { RecordValuePresentation.raw(value) }.value
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(raw, forType: .string)
                        copied = true
                    }
                }.font(.caption)
            }
            if let description { Text(description).font(.caption).foregroundStyle(.secondary) }
            if let partialRead {
                HStack(spacing: 10) {
                    Text(partialReadDescription(partialRead)).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let sliceNavigation {
                        Button("Previous slice", systemImage: "chevron.left") { onPreviousSlice() }
                            .disabled(!sliceNavigation.canReadPrevious || sliceNavigation.isLoading)
                        Button("Next slice", systemImage: "chevron.right") { onNextSlice() }
                            .disabled(!sliceNavigation.canReadNext || sliceNavigation.isLoading)
                        if sliceNavigation.isLoading { ProgressView().controlSize(.small) }
                    }
                }
                Text(RecordValuePresentation.summary(value)).font(.system(.callout, design: .monospaced)).lineLimit(5).textSelection(.enabled)
                if sliceNavigation != nil {
                    if !partialRead.isBinary && !partialRead.isNull {
                        HStack(spacing: 8) {
                            TextField("Find text in value", text: $searchText)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Find text in \(column.name)")
                            Button("Find next") { findNext(in: partialRead) }
                                .disabled(searchText.isEmpty || isOperating)
                        }
                    }
                    HStack(spacing: 8) {
                        Button("Copy full value") { copyFullValue() }
                            .disabled(isOperating || partialRead.isNull)
                        Button("Save full value…") { saveFullValue() }
                            .disabled(isOperating || partialRead.isNull)
                        if isOperating {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { operationTask?.cancel() }
                        }
                    }.font(.caption)
                    if let operationStatus {
                        Text(operationStatus).font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel(operationStatus)
                    }
                }
            } else if expanded {
                HStack {
                    Button("Collapse value") { expanded = false }
                    Toggle("Format JSON", isOn: $pretty).toggleStyle(.checkbox)
                    Text("Copy uses the raw value").font(.caption2).foregroundStyle(.secondary)
                }
                if let content { RecordTextView(text: content).frame(height: 220) }
                else { ProgressView("Loading full value…") }
            } else {
                Text(RecordValuePresentation.summary(value)).font(.system(.callout, design: .monospaced)).lineLimit(5).textSelection(.enabled)
                Button("Read full value") { expanded = true }.font(.caption)
            }
        }
        .padding(12).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
        .task(id: "\(expanded)-\(pretty)") {
            guard expanded else { content = nil; return }
            content = nil
            let value = value
            let raw = await Task.detached { RecordValuePresentation.raw(value) }.value
            let result = pretty ? await RecordValuePresentation.formattedJSON(raw) : raw
            guard !Task.isCancelled else { return }
            content = result
        }
        .onDisappear { operationTask?.cancel() }
        .onChange(of: searchText) { _, _ in lastFoundOffset = nil }
    }

    private func startOperation(_ work: @escaping () async throws -> String) {
        operationTask?.cancel()
        isOperating = true
        operationStatus = nil
        operationTask = Task { @MainActor in
            defer { isOperating = false; operationTask = nil }
            do { operationStatus = try await work() }
            catch is CancellationError { operationStatus = "Cancelled." }
            catch { operationStatus = error.localizedDescription }
        }
    }

    private func findNext(in current: BoundedCellRead) {
        let needle = searchText
        let next = min(current.totalLength ?? 0, (lastFoundOffset ?? -1) + 1)
        startOperation {
            var foundOffset: Int?
            var foundSlice: BoundedCellRead?
            let status = try await withReadSnapshot { reader in
                var result = try await BoundedCellOperations.findText(needle, startingAt: next) { offset, length in
                    try await reader.read(offset: offset, length: length)
                }
                if result == nil && next > 0 {
                    result = try await BoundedCellOperations.findText(needle) { offset, length in
                        try await reader.read(offset: offset, length: length)
                    }
                }
                guard let result else { return "No match in this value." }
                guard let matchSlice = try await reader.read(offset: result) else {
                    throw BoundedCellOperations.Failure.changedValue
                }
                foundOffset = result
                foundSlice = matchSlice
                return "Match at character \(result + 1)."
            }
            if let foundOffset, let foundSlice {
                lastFoundOffset = foundOffset
                onShowSlice(foundSlice)
            }
            return status
        }
    }

    private func copyFullValue() {
        startOperation {
            try await withReadSnapshot { reader in
                let exact = try await BoundedCellOperations.collectForClipboard { offset, length in
                    try await reader.read(offset: offset, length: length)
                }
                try Task.checkCancellation()
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                switch exact {
                case .text(let text):
                    guard pasteboard.setString(text, forType: .string) else { throw CocoaError(.fileWriteUnknown) }
                    return "Copied the complete text value (\(text.unicodeScalars.count) characters)."
                case .binary(let data):
                    guard pasteboard.setData(data, forType: NSPasteboard.PasteboardType("public.data")) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    return "Copied the complete binary value (\(data.count) bytes)."
                }
            }
        }
    }

    private func saveFullValue() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(column.name).\(partialRead?.isBinary == true ? "bin" : "txt")"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        startOperation {
            try await withReadSnapshot { reader in
                let bytes = try await BoundedCellOperations.saveToFile(at: destination) { offset, length in
                    try await reader.read(offset: offset, length: length)
                }
                return "Saved the complete value (\(bytes) bytes) to \(destination.lastPathComponent)."
            }
        }
    }

    private func partialReadDescription(_ read: BoundedCellRead) -> String {
        if read.isNull { return "The value is NULL." }
        guard let totalLength = read.totalLength else { return "Showing a bounded value slice." }
        let end = read.offset + read.returnedLength
        let range = read.returnedLength == 0 ? "No content at offset \(read.offset)."
            : "Showing \(read.offset + 1)–\(end) of \(totalLength) \(read.offsetUnit)."
        if read.hasMore { return range + " More content follows." }
        return range
    }
}

/// Native text storage lays out visible fragments instead of a huge SwiftUI Text tree.
private struct RecordTextView: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let view = NSTextView()
        view.isEditable = false; view.isSelectable = true
        view.isRichText = false; view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.layoutManager?.allowsNonContiguousLayout = true
        view.isVerticallyResizable = true; view.isHorizontallyResizable = true
        view.textContainer?.containerSize = NSSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.minSize = .zero; view.maxSize = NSSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }
}
