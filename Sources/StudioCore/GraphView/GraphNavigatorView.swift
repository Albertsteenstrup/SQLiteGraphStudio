import SwiftUI

/// Search spans the complete catalog, even when the canvas shows one group or page.
struct GraphNavigatorView: View {
    let graph: SchemaGraph
    let grouping: GraphGrouping
    let onGroup: (String) -> Void
    let onTable: (String) -> Void
    let onOverview: () -> Void
    @State private var query = ""
    @State private var resultPage = 0

    private var matchingNodes: [GraphNode] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        return graph.nodes.filter { $0.id.localizedCaseInsensitiveContains(term) || $0.title.localizedCaseInsensitiveContains(term) }
    }

    var body: some View {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = grouping.groups.filter { term.isEmpty || $0.label.localizedCaseInsensitiveContains(term) }
        let matches = matchingNodes
        let page = GraphExploration.page(matches.map(\.id), index: resultPage)
        VStack(alignment: .leading, spacing: 12) {
            TextField("Find any table or group", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("graph-search")
                .onChange(of: query) { _, _ in resultPage = 0 }
            Button("All \(graph.nodes.count) tables · \(grouping.groupCount) groups", action: onOverview)
                .buttonStyle(.plain)
                .font(.subheadline.weight(.semibold))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(groups) { group in
                        Button { onGroup(group.id) } label: {
                            HStack(spacing: 8) {
                                Circle().fill(Color(studioHex: group.colorHex) ?? StudioPalette.accent).frame(width: 8, height: 8)
                                Text(group.label).lineLimit(2)
                                Spacer(minLength: 8)
                                Text("\(group.nodeIDs.count)").foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if !term.isEmpty {
                        Divider().padding(.vertical, 4)
                        Text("\(matches.count) matching tables").font(.caption).foregroundStyle(.secondary)
                        ForEach(page.ids, id: \.self) { id in
                            Button { onTable(id) } label: {
                                Label(id, systemImage: "tablecells")
                                    .font(.system(.body, design: .monospaced))
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 7)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxHeight: 400)
            if page.count > 1 {
                HStack {
                    Button("Previous") { resultPage -= 1 }.disabled(page.index == 0)
                    Text("\(page.start)–\(page.end) of \(page.total)").font(.caption)
                    Button("Next") { resultPage += 1 }.disabled(page.index + 1 == page.count)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
