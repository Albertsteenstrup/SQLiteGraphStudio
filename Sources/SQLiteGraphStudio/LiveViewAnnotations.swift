import Foundation
import Observation
import StudioCore
import SwiftUI

enum LiveViewAnnotationInputError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

/// Temporary explanation notes. An anchor identifies an existing schema object;
/// it does not add a relationship to the database graph.
struct LiveViewAnnotation: Identifiable, Equatable {
    struct Anchor: Equatable {
        let tableID: String
        let columnID: String?

        var label: String {
            columnID.map { "\(tableID).\($0)" } ?? tableID
        }
    }

    let id: String
    let text: String
    let anchors: [Anchor]
    let evidenceRefs: [String]

    var payload: [String: Any] {
        [
            "id": id,
            "text": text,
            "anchors": anchors.map { anchor in
                var value: [String: Any] = ["table_id": anchor.tableID]
                if let columnID = anchor.columnID { value["column_id"] = columnID }
                return value
            },
            "evidence_refs": evidenceRefs,
        ]
    }

    static func parse(
        _ entries: [[String: Any]],
        validTableIDs: Set<String>,
        columnsByTable: [String: Set<String>]
    ) throws -> [Self] {
        guard entries.count <= 20 else {
            throw LiveViewAnnotationInputError.invalid("A view can contain at most 20 temporary notes.")
        }
        var seen = Set<String>()
        return try entries.map { item in
            let id = ((item["id"] as? String) ?? UUID().uuidString).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id.count <= 128, seen.insert(id).inserted else {
                throw LiveViewAnnotationInputError.invalid("Every note needs a unique ID of at most 128 characters.")
            }
            let text = ((item["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 700 else {
                throw LiveViewAnnotationInputError.invalid("Each note needs plain text of at most 700 characters.")
            }
            guard item["anchors"] == nil || item["anchors"] is [[String: Any]] else {
                throw LiveViewAnnotationInputError.invalid("Note anchors must be a list of schema objects.")
            }
            let rawAnchors = item["anchors"] as? [[String: Any]] ?? []
            guard rawAnchors.count <= 4 else {
                throw LiveViewAnnotationInputError.invalid("A note can identify at most four schema objects.")
            }
            let anchors = try rawAnchors.map { raw -> Anchor in
                guard let tableID = raw["table_id"] as? String, validTableIDs.contains(tableID) else {
                    throw LiveViewAnnotationInputError.invalid("A note anchor names a table outside this workspace.")
                }
                let columnID = raw["column_id"] as? String
                if let columnID, columnsByTable[tableID]?.contains(columnID) != true {
                    throw LiveViewAnnotationInputError.invalid("A note anchor names a field outside its table.")
                }
                guard Set(raw.keys).isSubset(of: ["table_id", "column_id"]) else {
                    throw LiveViewAnnotationInputError.invalid("Notes can anchor to real tables or fields only; they cannot create graph relations.")
                }
                return Anchor(tableID: tableID, columnID: columnID)
            }
            guard Set(anchors.map(\.label)).count == anchors.count else {
                throw LiveViewAnnotationInputError.invalid("Note anchors must identify different schema objects.")
            }
            guard item["evidence_refs"] == nil || item["evidence_refs"] is [String] else {
                throw LiveViewAnnotationInputError.invalid("Evidence references must be a list of strings.")
            }
            let evidenceRefs = item["evidence_refs"] as? [String] ?? []
            guard evidenceRefs.count <= 8,
                  evidenceRefs.allSatisfy({ !$0.isEmpty && $0.count <= 300 }) else {
                throw LiveViewAnnotationInputError.invalid("A note can cite up to eight short evidence references.")
            }
            return LiveViewAnnotation(id: id, text: text, anchors: anchors, evidenceRefs: evidenceRefs)
        }
    }
}

@MainActor
@Observable
final class LiveViewAnnotationStore {
    private(set) var byWorkspace: [UUID: [LiveViewAnnotation]] = [:]

    func annotations(in workspaceID: UUID?) -> [LiveViewAnnotation] {
        guard let workspaceID else { return [] }
        return byWorkspace[workspaceID] ?? []
    }

    func replace(_ annotations: [LiveViewAnnotation], in workspaceID: UUID) {
        byWorkspace[workspaceID] = annotations
    }

    func add(_ annotations: [LiveViewAnnotation], in workspaceID: UUID) {
        var current = byWorkspace[workspaceID] ?? []
        for annotation in annotations {
            if let index = current.firstIndex(where: { $0.id == annotation.id }) {
                current[index] = annotation
            } else {
                current.append(annotation)
            }
        }
        byWorkspace[workspaceID] = current
    }

    func clear(_ ids: Set<String>?, in workspaceID: UUID) {
        if let ids {
            byWorkspace[workspaceID]?.removeAll { ids.contains($0.id) }
        } else {
            byWorkspace.removeValue(forKey: workspaceID)
        }
    }
}

/// Keeps annotations readable above the graph and data panes. Selecting an
/// anchor focuses its real table, while explanatory text remains plain text.
@MainActor
struct LiveViewAnnotationOverlay: View {
    let store: LiveViewAnnotationStore
    let workspaces: WorkspaceTabController
    @State private var isExpanded = false

    var body: some View {
        let temporary = store.annotations(in: workspaces.activeTabID)
        let saved = savedAnnotations()
        if !temporary.isEmpty || !saved.isEmpty {
            VStack(alignment: .trailing, spacing: 8) {
                if isExpanded {
                    expandedNotes(temporary: temporary, saved: saved)
                } else {
                    notesToggle(temporaryCount: temporary.count, savedCount: saved.count)
                }
            }
            .animation(.snappy(duration: 0.18), value: isExpanded)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Explanation notes")
            .onChange(of: temporary.isEmpty, initial: true) { _, isEmpty in
                // Open a new live explanation automatically, while keeping saved
                // notes tucked away until the user asks to see them.
                isExpanded = !isEmpty
            }
            .onChange(of: workspaces.activeTabID) { _, _ in
                isExpanded = !temporary.isEmpty
            }
        }
    }

    private func notesToggle(temporaryCount: Int, savedCount: Int) -> some View {
        let count = temporaryCount + savedCount
        let title = temporaryCount > 0 ? "Explanation notes" : "Saved notes"
        return Button {
            isExpanded = true
        } label: {
            Label("\(title) · \(count)", systemImage: "text.bubble")
                .font(.callout)
        }
        .buttonStyle(.bordered)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("Show explanation notes")
        .accessibilityValue("\(count) notes")
        .accessibilityIdentifier("liveViewAnnotationToggle")
    }

    private func expandedNotes(temporary: [LiveViewAnnotation], saved: [LiveViewAnnotation]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Explanation notes")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button {
                    isExpanded = false
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .help("Collapse explanation notes")
                .accessibilityLabel("Hide explanation notes")
                .accessibilityIdentifier("liveViewAnnotationToggle")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !temporary.isEmpty {
                        Text("Current explanation")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(temporary) { noteCard($0) }
                    }
                    if !saved.isEmpty {
                        Text("Saved notes")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(saved) { noteCard($0) }
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 340)
        .frame(maxHeight: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 6)
    }

    private func savedAnnotations() -> [LiveViewAnnotation] {
        guard let session = workspaces.activeSession else { return [] }
        let knownTables = Set(session.graph.nodes.map(\.id))
        let notes = session.schemaSidecar.notes
        let selected = session.selectedGraphNodeID
        let prioritized: [SchemaSidecar.Note]
        if let selected {
            let relevant = notes.filter { note in
                note.tableID == selected || session.graph.edges.contains { edge in
                    edge.id == note.relationID && (edge.sourceID == selected || edge.targetID == selected)
                }
            }
            prioritized = relevant + notes.filter { note in !relevant.contains(where: { $0.id == note.id }) }
        } else {
            prioritized = notes
        }
        return prioritized.map { note in
            var anchors: [LiveViewAnnotation.Anchor] = []
            if let tableID = note.tableID, knownTables.contains(tableID) {
                anchors.append(.init(tableID: tableID, columnID: note.columnName))
            }
            if let relationID = note.relationID,
               let edge = session.graph.edges.first(where: { $0.id == relationID }) {
                for tableID in [edge.sourceID, edge.targetID] where knownTables.contains(tableID) &&
                    !anchors.contains(where: { $0.tableID == tableID }) {
                    anchors.append(.init(tableID: tableID, columnID: nil))
                }
            }
            return LiveViewAnnotation(id: note.id, text: note.text, anchors: anchors, evidenceRefs: [])
        }
    }

    @ViewBuilder
    private func noteCard(_ annotation: LiveViewAnnotation) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(annotation.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if !annotation.anchors.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(annotation.anchors, id: \.label) { anchor in
                            Button(anchor.label) { focus(anchor) }
                                .buttonStyle(.borderless)
                                .font(.caption.monospaced())
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            if !annotation.evidenceRefs.isEmpty {
                Text("Evidence: " + annotation.evidenceRefs.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func focus(_ anchor: LiveViewAnnotation.Anchor) {
        guard let session = workspaces.activeSession else { return }
        if anchor.columnID != nil {
            session.expandedGraphNodeIDs.insert(anchor.tableID)
        }
        session.selectGraphNode(anchor.tableID)
        session.ensurePaneVisible(.schema, preferredSide: .left)
        session.markAutomationViewChanged()
    }
}
