import SwiftUI

struct RecordMappingConnectionsView: View {
    @Bindable var workspace: RecordWorkspace
    let mapping: RecordGraphMapping
    let direction: RecordDirection
    var body: some View {
        let key = RecordExpansionKey(recordID: workspace.current?.id ?? "", relationshipID: "mapping:" + mapping.id, direction: direction)
        VStack(alignment: .leading, spacing: 8) {
            Text("\(mapping.name) · \(direction == .outgoing ? "source connections" : "target connections")").font(.subheadline.bold())
            Text(mapping.isDirected ? "Mapped directed edges" : "Mapped undirected edges").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Browse mapped records") { workspace.loadMapping(mapping, direction: direction) }
                if workspace.showsGraph {
                    Button("Expand graph") { workspace.loadMapping(mapping, direction: direction, intoGraph: true) }
                        .disabled(workspace.current.flatMap { workspace.recordGraph.records[$0.id] } == nil)
                }
                if workspace.loading.contains(key) { ProgressView().controlSize(.small) }
            }.disabled(workspace.current?.identity == nil || workspace.loading.contains(key))
            if let error = workspace.errors[key] { Text(error).font(.caption).foregroundStyle(.red) }
            if let page = workspace.mappedPages[key] {
                ForEach(page.messages, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                ForEach(page.connections) { connection in
                    let other = direction == .outgoing ? connection.target : connection.source
                    Button { workspace.navigate(other) } label: {
                        HStack {
                            Text(other.label)
                            Spacer()
                            Text(connection.label ?? "Edge").font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                        }.padding(6)
                    }.buttonStyle(.plain)
                }
                HStack {
                    let offset = workspace.offsets[key, default: 0]
                    if offset > 0 {
                        Button("Previous page") { workspace.loadMapping(mapping, direction: direction, offset: max(0, offset - 5)) }
                    }
                    if page.hasMore, let next = page.nextOffset {
                        Button("Load more") { workspace.loadMapping(mapping, direction: direction, offset: next) }
                    }
                    Text(page.hasMore ? "More mapped edges available" : "End of mapped edges").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}
