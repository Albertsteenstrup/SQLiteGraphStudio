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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Button(action: onOverview) {
                        Label("All \(graph.nodes.count) tables · \(grouping.groupCount) groups", systemImage: "square.grid.2x2")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .buttonStyle(.studioRow)
                    ForEach(groups) { group in
                        Button { onGroup(group.id) } label: {
                            HStack(spacing: 8) {
                                Circle().fill(Color(studioHex: group.colorHex) ?? StudioPalette.accent).frame(width: 8, height: 8)
                                Text(group.label).lineLimit(2)
                                Spacer(minLength: 8)
                                Text("\(group.nodeIDs.count)")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12.5))
                        }
                        .buttonStyle(.studioRow)
                    }
                    if !term.isEmpty {
                        Divider().padding(.vertical, 6)
                        Text("\(matches.count) matching tables")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 2)
                        ForEach(page.ids, id: \.self) { id in
                            Button { onTable(id) } label: {
                                Label(graph.node(id: id)?.title ?? id, systemImage: "tablecells")
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .lineLimit(2)
                            }
                            .buttonStyle(.studioRow)
                        }
                    }
                }
            }
            .frame(maxHeight: 400)
            .padding(.horizontal, -8)
            if page.count > 1 {
                HStack(spacing: 0) {
                    Button { resultPage -= 1 } label: { Image(systemName: "chevron.left") }
                        .disabled(page.index == 0)
                        .help("Previous results")
                        .accessibilityLabel("Previous")
                    Text("\(page.start)–\(page.end) of \(page.total)")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                    Button { resultPage += 1 } label: { Image(systemName: "chevron.right") }
                        .disabled(page.index + 1 == page.count)
                        .help("Next results")
                        .accessibilityLabel("Next")
                }
                .buttonStyle(.studioIcon)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 340)
        // A popover follows the system appearance even when it opens from the canvas.
        .studioSurface(.adaptive)
    }
}
