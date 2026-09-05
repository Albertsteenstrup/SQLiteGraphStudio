import SwiftUI

struct RecordGraphView: View {
    @Bindable var workspace: RecordWorkspace
    @State private var positions: [String: CGPoint] = [:]
    @State private var transform = GraphViewportTransform.identity
    @State private var dragPan: CGSize?
    @State private var magnifyStart: CGFloat?
    @State private var viewport = CGSize.zero
    @State private var nodeDragOrigins: [String: CGPoint] = [:]

    var body: some View {
        let graph = workspace.recordGraph.graph
        VStack(spacing: 8) {
            HStack {
                Text("Actual records").font(.headline)
                Text("\(graph.nodes.count)/\(workspace.recordGraph.limits.nodes) nodes · \(graph.edges.count)/\(workspace.recordGraph.limits.edges) edges")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Fit") { fit(graph) }
            }.padding([.horizontal, .top], 12)
            if let message = workspace.recordGraph.limitMessage { Text(message).font(.caption).foregroundStyle(.orange).padding(.horizontal, 12) }
            Text("Expand a relationship in the inspector. Click a node to inspect it; drag nodes or the canvas to arrange the graph.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
            GeometryReader { geo in
                ZStack {
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture().onChanged { value in
                            if dragPan == nil { dragPan = transform.pan }
                            transform.pan = CGSize(width: dragPan!.width + value.translation.width, height: dragPan!.height + value.translation.height)
                        }.onEnded { _ in dragPan = nil })
                    Canvas { context, _ in
                        for edge in graph.edges {
                            guard let start = positions[edge.sourceID], let end = positions[edge.targetID] else { continue }
                            let a = transform.point(for: start, in: geo.size), b = transform.point(for: end, in: geo.size)
                            let siblings = graph.edges.filter { $0.sourceID == edge.sourceID && $0.targetID == edge.targetID }
                            let lane = CGFloat(siblings.firstIndex(where: { $0.id == edge.id }) ?? 0)
                            var path = Path()
                            let control: CGPoint
                            if edge.sourceID == edge.targetID {
                                path.move(to: CGPoint(x: a.x - 35, y: a.y - 15))
                                control = CGPoint(x: a.x, y: a.y - 85 - lane * 15)
                                path.addCurve(to: CGPoint(x: a.x + 35, y: a.y - 15), control1: CGPoint(x: a.x - 110, y: control.y), control2: CGPoint(x: a.x + 110, y: control.y))
                            } else {
                                path.move(to: a)
                                let dx = b.x - a.x, dy = b.y - a.y, length = max(1, hypot(dx, dy))
                                let bend = 24 + lane * 32
                                control = CGPoint(x: (a.x + b.x) / 2 - dy / length * bend, y: (a.y + b.y) / 2 + dx / length * bend)
                                path.addQuadCurve(to: b, control: control)
                            }
                            context.stroke(path, with: .color(.secondary.opacity(0.55)), lineWidth: 1.5)
                            if edge.sourceID != edge.targetID && !workspace.recordGraph.undirectedEdgeIDs.contains(edge.id) {
                                let center = CGPoint(x: (a.x + 2 * control.x + b.x) / 4, y: (a.y + 2 * control.y + b.y) / 4)
                                let angle = atan2(b.y - a.y, b.x - a.x)
                                var arrow = Path()
                                arrow.move(to: CGPoint(x: center.x - 8 * cos(angle - 0.5), y: center.y - 8 * sin(angle - 0.5)))
                                arrow.addLine(to: center)
                                arrow.addLine(to: CGPoint(x: center.x - 8 * cos(angle + 0.5), y: center.y - 8 * sin(angle + 0.5)))
                                context.stroke(arrow, with: .color(.secondary), lineWidth: 2)
                            }
                            context.draw(Text(edge.targetColumn.isEmpty ? edge.sourceColumn : "\(edge.sourceColumn) → \(edge.targetColumn)").font(.system(size: 9)).foregroundStyle(.secondary), at: control)
                        }
                    }.allowsHitTesting(false)
                    ForEach(graph.nodes) { node in
                        let position = transform.point(for: positions[node.id] ?? .zero, in: geo.size)
                        Button {
                            if let record = workspace.recordGraph.records[node.id] { workspace.navigate(record) }
                        } label: {
                            VStack(spacing: 3) {
                                Text(node.title).font(.subheadline.bold()).lineLimit(1)
                                Text(workspace.recordGraph.records[node.id]?.table?.displayName ?? "Record").font(.caption2).lineLimit(1)
                                if workspace.recordGraph.root?.id == node.id { Text("ROOT").font(.system(size: 8, weight: .bold)) }
                            }.padding(10).frame(width: 155)
                            .background(workspace.current?.id == node.id ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(workspace.current?.id == node.id ? Color.accentColor : .secondary.opacity(0.4)))
                        }.buttonStyle(.plain).position(position)
                        .simultaneousGesture(DragGesture(minimumDistance: 5).onChanged { value in
                            let origin = nodeDragOrigins[node.id] ?? positions[node.id] ?? .zero
                            nodeDragOrigins[node.id] = origin
                            let p = CGPoint(x: origin.x + value.translation.width / transform.zoom, y: origin.y + value.translation.height / transform.zoom)
                            positions[node.id] = p
                            workspace.recordGraph.layout.pin(nodeID: node.id, at: p)
                        }.onEnded { _ in nodeDragOrigins[node.id] = nil })
                        .contextMenu {
                            Button("Use as root") {
                                if let record = workspace.recordGraph.records[node.id] { workspace.navigate(record); workspace.showConnections() }
                            }
                        }
                    }
                }
                .clipped().background(.quaternary.opacity(0.1))
                .simultaneousGesture(MagnificationGesture().onChanged { value in
                    if magnifyStart == nil { magnifyStart = transform.zoom }
                    transform.zoom = min(2.5, max(0.08, magnifyStart! * value))
                }.onEnded { _ in magnifyStart = nil })
                .onAppear { viewport = geo.size; arrange(graph) }
                .onChange(of: geo.size) { _, size in viewport = size }
                .onChange(of: graph) { _, value in arrange(value) }
            }
            if !workspace.recordGraph.branches.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(workspace.recordGraph.branches.keys.sorted { String(describing: $0) < String(describing: $1) }, id: \.self) { key in
                            if let branch = workspace.recordGraph.branches[key] {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(workspace.recordGraph.records[key.recordID]?.label ?? "Record") · \(key.direction.rawValue)").font(.caption.bold())
                                    if let message = branch.message { Text(message).font(.caption2).foregroundStyle(.orange) }
                                    HStack {
                                        Button("Collapse branch") { workspace.recordGraph.collapse(key) }
                                        if branch.hasMore, let offset = branch.nextOffset {
                                            Button("Load more") {
                                                guard let source = workspace.recordGraph.records[key.recordID] else { return }
                                                workspace.navigate(source)
                                                if let relation = workspace.relationships.first(where: { $0.id == key.relationshipID }) {
                                                    workspace.load(relation, direction: key.direction, offset: offset, intoGraph: true)
                                                } else if let mapping = workspace.mappings.first(where: { "mapping:" + $0.id == key.relationshipID }) {
                                                    workspace.loadMapping(mapping, direction: key.direction, offset: offset, intoGraph: true)
                                                }
                                            }
                                        } else { Text("Page complete").font(.caption2) }
                                    }
                                }.padding(8).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }.padding(8)
                }.frame(maxHeight: 100)
            }
            Text("Explored relationships only · depth ≤ \(workspace.recordGraph.limits.depth) · queries \(workspace.recordGraph.queriesUsed)/\(workspace.recordGraph.limits.queries)")
                .font(.caption2).foregroundStyle(.secondary).padding(.bottom, 8)
        }
    }

    private func arrange(_ graph: SchemaGraph) {
        workspace.recordGraph.layout.reset(for: graph)
        for _ in 0..<24 { workspace.recordGraph.layout.step(graph: graph) }
        positions = workspace.recordGraph.layout.allPositions(for: graph)
        fit(graph)
    }
    private func fit(_ graph: SchemaGraph) {
        let bounds = graph.nodes.compactMap { positions[$0.id] }.reduce(CGRect.null) { rect, p in
            rect.union(CGRect(x: p.x - 100, y: p.y - 65, width: 200, height: 130))
        }
        transform = .fit(contentBounds: bounds, in: viewport, padding: 80, minZoom: 0.08, maxZoom: 1)
    }
}
