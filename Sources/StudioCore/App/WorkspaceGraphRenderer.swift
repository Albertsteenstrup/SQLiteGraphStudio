import AppKit
import CoreFoundation
import Foundation
import SwiftUI

/// A dedicated embedded surface, using the same native graph as the review
/// renderer. It renders already loaded workspace facts, without capturing an
/// app window or opening another database connection.
@MainActor
public final class WorkspaceGraphRenderer {
    public struct Frame {
        public let image: Data
        public let mimeType: String
        public let width: Int
        public let height: Int
    }

    private let session: AppSession
    private let hosting: NSHostingView<AnyView>
    private let window: NSWindow
    private let defaultsFile: URL
    private var sourceRevision: String?
    private var sourceInstructionRevision: Int?
    private var sourceGraphRevision: Int?
    private var sourceLayout: GraphLayoutSnapshot?
    private var fullModelLayout: GraphLayoutSnapshot?
    private var fullModelLayoutIsAuthored = false
    private var detailScope: (visible: Set<String>?, expanded: Set<String>, selected: Set<String>,
                              zoom: CGFloat, pan: CGSize, layout: GraphLayoutSnapshot)?
    public private(set) var revision = 0
    public var selection: [String] { session.selectedGraphNodeIDs.sorted() }
    public var expandedTables: [String] { session.expandedGraphNodeIDs.sorted() }
    public var zoom: CGFloat { session.graphZoom }
    public var pan: CGSize { session.graphPan }
    public var minimumZoom: CGFloat { session.graph.nodes.count > GraphLayoutModel.largeGraphOverviewThreshold ? 0.005 : 0.12 }
    public var size: CGSize { hosting.bounds.size }
    public var contextMode: Bool { detailScope != nil || !session.graphContextTableIDs.isEmpty }
    public var highlightedTables: [String] { session.graphContextTableIDs.sorted() }
    public var visibleTables: [String] { session.graphVisibleTableIDs.sorted() }
    public var nodes: [[String: Any]] {
        return session.automationGraphNodeFrames.keys.sorted().compactMap { id in
            guard let frame = session.automationGraphNodeFrames[id], frame.intersects(hosting.bounds) else { return nil }
            let center = session.graphLayout.position(for: id)
            return ["table_id": id, "x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height,
                    "center_x": center.x, "center_y": center.y]
        }
    }

    public init() throws {
        defaultsFile = FileManager.default.temporaryDirectory.appendingPathComponent("embedded-graph-\(UUID().uuidString).plist")
        guard let defaults = UserDefaults(suiteName: defaultsFile.path) else { throw RenderError.unavailable }
        session = AppSession(userDefaults: defaults)
        session.rendersOffscreen = true
        hosting = NSHostingView(rootView: AnyView(SchemaGraphView(session: session)
            .background(Color(nsColor: .windowBackgroundColor))
            .transaction { transaction in
                transaction.disablesAnimations = true
                transaction.animation = nil
            }))
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 960, height: 440),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
    }

    public func close() {
        window.contentView = nil
        window.close()
        UserDefaults.standard.removePersistentDomain(forName: defaultsFile.path)
        try? FileManager.default.removeItem(at: defaultsFile)
    }

    public func synchronize(from source: AppSession, revision next: String, width: Int, height: Int) {
        window.appearance = NSApp?.effectiveAppearance
        let resized = hosting.bounds.size != CGSize(width: width, height: height)
        // Native metric clearance increments its sizing and render revisions
        // together. It invalidates frames without replacing reader inspection.
        let instructionRevision = source.automationViewRevision &- source.graphNodeSizingLayoutRevision
        let followsInstruction = sourceInstructionRevision != instructionRevision || sourceRevision == nil
        if resized { window.setContentSize(CGSize(width: width, height: height)) }
        if sourceRevision != next {
            let nextSourceLayout = source.graphLayout.snapshot(for: source.graph)
            let entersAuthoredContext = followsInstruction && !source.graphContextTableIDs.isEmpty
                && session.graphContextTableIDs.isEmpty
                && (session.automationVisibleTableIDs != nil || session.graphVisibleTableIDs.count < session.graph.nodes.count)
            let modelChanged = sourceGraphRevision != source.graphRevision || session.databaseTarget != source.databaseTarget
                || (followsInstruction && session.graphGrouping != source.graphGrouping)
            let contextLayout = followsInstruction && !modelChanged && !session.graphContextTableIDs.isEmpty
                && !source.graphContextTableIDs.isEmpty && nextSourceLayout == sourceLayout
                ? session.graphLayout.snapshot(for: session.graph) : nil
            if modelChanged {
                fullModelLayout = nil
                fullModelLayoutIsAuthored = false
            }
            // A scoped tour may compact just its subjects in the source layout.
            // Keep the first complete authored map before copying later detail.
            if !fullModelLayoutIsAuthored, !entersAuthoredContext || modelChanged,
               source.graphVisibleTableIDs.count == source.graph.nodes.count,
               !source.graph.nodes.isEmpty {
                fullModelLayout = nextSourceLayout
                fullModelLayoutIsAuthored = true
            }
            if followsInstruction { detailScope = nil }
            session.synchronizeEmbeddedGraph(from: source, followsInstruction: followsInstruction)
            if fullModelLayout == nil { fullModelLayout = makeFullModelLayout() }
            // An agent can insert the same broader-picture step as the reader.
            // Apply the baseline only on entry, allowing subsequent authored
            // arrangements and camera instructions in context to take effect.
            if entersAuthoredContext, let fullModelLayout { restoreInspectionLayout(fullModelLayout) }
            else if let contextLayout { restoreInspectionLayout(contextLayout) }
            if followsInstruction {
                let fits = source.automationViewportIntent?.fitVisibleTables != false
                if !fits {
                    session.graphZoom = source.graphZoom
                    session.graphPan = source.graphPan
                }
                session.requestAutomationViewport(fitVisibleTables: fits, transitionMilliseconds: 0)
            }
            sourceRevision = next
            sourceInstructionRevision = instructionRevision
            sourceGraphRevision = source.graphRevision
            sourceLayout = nextSourceLayout
            revision &+= 1
        }
        if resized && !followsInstruction {
            session.requestAutomationViewport(fitVisibleTables: true, transitionMilliseconds: 0)
            revision &+= 1
        }
    }

    /// A direct detail open has no authored overview yet. Generate a grouped
    /// complete layout once; a later authored complete map replaces this fallback.
    private func makeFullModelLayout() -> GraphLayoutSnapshot {
        let layout = GraphLayoutModel()
        layout.setClusterHints(session.graphGrouping.nodeToGroup)
        let presentation: GraphPresentationMode = session.showAllGraphTableCards ? .allCards : .compact
        layout.reset(for: session.graph, presentation: presentation, descriptorLookup: session.descriptor(named:))
        if session.graph.nodes.count <= GraphLayoutModel.largeGraphOverviewThreshold {
            let expanded = session.showAllGraphTableCards
            let nodesByID = Dictionary(uniqueKeysWithValues: session.graph.nodes.map { ($0.id, $0) })
            layout.stabilize(graph: session.graph, presentation: presentation,
                descriptorLookup: session.descriptor(named:), nodeSizeLookup: { id in
                    GraphCardLayout.nodeSize(title: nodesByID[id]?.title ?? id,
                        descriptor: self.session.descriptor(named: id), style: expanded ? .expanded : .collapsed)
                }, maxIterations: 140)
        }
        if session.graphNodeSizeMetric != .uniform, !session.isSchemaReviewFullModelView {
            // Reserve metric footprints once for a generated map, before it
            // becomes the stable baseline. Later inspection restores it exactly.
            let graph = session.graph
            let cardSizes = Dictionary(uniqueKeysWithValues: graph.nodes.map { node in
                (node.id, GraphCardLayout.nodeSize(title: node.title, descriptor: session.descriptor(named: node.id),
                    style: session.showAllGraphTableCards ? .expanded : .collapsed))
            })
            let largeOverview = graph.nodes.count > GraphLayoutModel.largeGraphOverviewThreshold
            let viewport = hosting.bounds.size
            let insets = largeOverview ? min(68, viewport.height * 0.25) + min(100, viewport.height * 0.25) : 0
            _ = GraphViewportTransform.fit(contentBoundsAtZoom: { proposedZoom in
                let reservedSizes = Dictionary(uniqueKeysWithValues: cardSizes.map { id, size in
                    (id, self.session.graphNodeSizeProfile.layoutSize(for: id, cardSize: size, minimumZoom: proposedZoom))
                })
                layout.resizeNodes(for: graph, sizes: reservedSizes)
                return graph.nodes.reduce(CGRect.null) { bounds, node in
                    let center = layout.position(for: node.id), size = reservedSizes[node.id]!
                    return bounds.union(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                               width: size.width, height: size.height))
                }
            }, initialZoom: session.graphZoom,
               in: CGSize(width: viewport.width, height: max(100, viewport.height - insets)),
               padding: largeOverview ? 36 : 120, minZoom: largeOverview ? 0.005 : 0.45)
        }
        return layout.snapshot(for: session.graph)
    }

    /// Snapshot restoration normally repairs large-graph overlaps. A deliberately
    /// compact detail can overlap hidden tables, so restore its exact inspection
    /// positions and pin set after rebuilding the layout's graph bookkeeping.
    private func restoreInspectionLayout(_ snapshot: GraphLayoutSnapshot) {
        session.restoreAutomationGraphLayout(snapshot)
        let ids = Set(session.graph.nodes.map(\.id))
        for (id, point) in snapshot.positions where ids.contains(id) && point.x.isFinite && point.y.isFinite {
            session.graphLayout.pin(nodeID: id, at: point)
        }
        session.graphLayout.clearPinnedState()
        for (id, point) in snapshot.pinnedPositions where ids.contains(id) && point.x.isFinite && point.y.isFinite {
            session.graphLayout.pin(nodeID: id, at: point)
        }
    }

    /// Input uses the native graph's own hit testing and camera transform. The
    /// browser previews pan/zoom immediately, then replaces it with this frame.
    public static func validate(_ action: [String: Any]) throws {
        let allowed: Set<String>
        switch action["type"] as? String {
        case "click":
            allowed = ["type", "x", "y"]
            guard action["x"] != nil, action["y"] != nil else { throw RenderError.invalidAction }
        case "transform": allowed = ["type", "scale", "tx", "ty"]
        case "fit": allowed = ["type"]
        case "select", "expand": allowed = ["type", "table_id"]
        case "move": allowed = ["type", "table_id", "x", "y"]
        case "context": allowed = ["type"]
        default: throw RenderError.invalidAction
        }
        guard Set(action.keys).isSubset(of: allowed) else { throw RenderError.invalidAction }
        if allowed.contains("table_id") {
            guard let id = action["table_id"] as? String, !id.isEmpty else { throw RenderError.invalidAction }
        }
        if action["type"] as? String == "move", action["x"] == nil || action["y"] == nil { throw RenderError.invalidAction }
        for key in allowed.subtracting(["type", "table_id"]) where action[key] != nil {
            guard let value = action[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, abs(value.doubleValue) <= 1_000_000 else { throw RenderError.invalidAction }
            if key == "scale", !(value.doubleValue > 0 && value.doubleValue <= 1_000) { throw RenderError.invalidAction }
        }
    }

    public func apply(_ action: [String: Any]) throws {
        try Self.validate(action)
        if let id = action["table_id"] as? String, session.graph.node(id: id) == nil { throw RenderError.invalidAction }
        func number(_ key: String, default fallback: Double = 0) throws -> CGFloat {
            guard let raw = action[key] else { return CGFloat(fallback) }
            guard let value = raw as? NSNumber, value.doubleValue.isFinite,
                  abs(value.doubleValue) <= 1_000_000 else { throw RenderError.invalidAction }
            return CGFloat(value.doubleValue)
        }
        switch action["type"] as? String {
        case "click":
            session.requestGraphTap(at: CGPoint(x: try number("x"), y: try number("y")), keepsChosenTable: true)
        case "transform":
            let scale = try number("scale", default: 1)
            guard scale > 0 else { throw RenderError.invalidAction }
            let current = GraphViewportTransform(zoom: session.graphZoom, pan: session.graphPan)
            let shift = CGSize(width: try number("tx"), height: try number("ty"))
            let transform: GraphViewportTransform
            if abs(scale - 1) < 0.000_001 {
                transform = GraphViewportTransform(zoom: current.zoom, pan: CGSize(
                    width: current.pan.width + shift.width, height: current.pan.height + shift.height))
            } else {
                let anchor = CGPoint(x: shift.width / (1 - scale), y: shift.height / (1 - scale))
                transform = current.magnified(by: scale - 1, at: anchor, in: size, minZoom: minimumZoom)
            }
            session.graphZoom = transform.zoom
            session.graphPan = transform.pan
            session.requestAutomationFocusReset()
            session.requestAutomationViewport(fitVisibleTables: false, transitionMilliseconds: 0)
        case "fit":
            session.requestAutomationFocusReset()
            session.requestAutomationViewport(fitVisibleTables: true, transitionMilliseconds: 0)
        case "select":
            session.setGraphSelection([action["table_id"] as! String])
        case "expand":
            let id = action["table_id"] as! String
            if session.expandedGraphNodeIDs.contains(id) { session.expandedGraphNodeIDs.remove(id) }
            else { session.expandedGraphNodeIDs.insert(id) }
            session.setGraphSelection([id])
            session.requestAutomationFocusReset()
            session.requestAutomationViewport(fitVisibleTables: false, transitionMilliseconds: 0)
        case "move":
            let id = action["table_id"] as! String
            session.requestAutomationFocusReset()
            session.graphLayout.pin(nodeID: id, at: CGPoint(x: try number("x"), y: try number("y")))
            session.setGraphSelection([id])
            session.requestAutomationViewport(fitVisibleTables: false, transitionMilliseconds: 0)
        case "context":
            session.requestAutomationFocusReset()
            if let previous = detailScope {
                session.graphContextTableIDs = []
                session.setAutomationVisibleTableIDs(previous.visible)
                session.expandedGraphNodeIDs = previous.expanded
                session.setGraphSelection(previous.selected)
                restoreInspectionLayout(previous.layout)
                session.graphZoom = previous.zoom
                session.graphPan = previous.pan
                session.requestAutomationViewport(fitVisibleTables: false, transitionMilliseconds: 0)
                detailScope = nil
            } else if !session.graphContextTableIDs.isEmpty {
                let subjects = session.graphContextTableIDs
                session.graphContextTableIDs = []
                session.setAutomationVisibleTableIDs(subjects)
                session.requestAutomationViewport(fitVisibleTables: true, transitionMilliseconds: 0)
            } else {
                let visible = session.graphVisibleTableIDs
                let subjects = visible.count == session.graph.nodes.count && !session.selectedGraphNodeIDs.isEmpty
                    ? session.selectedGraphNodeIDs : visible
                detailScope = (session.automationVisibleTableIDs, session.expandedGraphNodeIDs,
                               session.selectedGraphNodeIDs, zoom, pan, session.graphLayout.snapshot(for: session.graph))
                session.graphContextTableIDs = subjects
                session.setAutomationVisibleTableIDs(nil)
                session.expandedGraphNodeIDs = []
                session.clearGraphSelection()
                if let fullModelLayout { restoreInspectionLayout(fullModelLayout) }
                session.requestAutomationViewport(fitVisibleTables: true, transitionMilliseconds: 0)
            }
        default: throw RenderError.invalidAction
        }
        session.markAutomationViewChanged()
        revision &+= 1
    }

    public func render() async throws -> Frame {
        let requestedRevision = revision
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let bounds = hosting.bounds
        let width = Int((bounds.width * 2).rounded()), height = Int((bounds.height * 2).rounded())
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw RenderError.unavailable }
        bitmap.size = bounds.size
        repeat {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            hosting.layer?.displayIfNeeded()
            // Resolve camera/layout first. Repeated large bitmap captures while
            // SwiftUI is applying a command block the bridge and its input queue.
            if session.automationViewportCommand == nil { hosting.cacheDisplay(in: bounds, to: bitmap) }
            try await Task.sleep(for: .milliseconds(10))
            guard revision == requestedRevision else { throw RenderError.superseded }
            if session.automationViewportCommand == nil,
               session.automationRenderedViewRevision == session.automationViewRevision { break }
        } while ContinuousClock.now < deadline
        guard session.automationViewportCommand == nil,
              session.automationRenderedViewRevision == session.automationViewRevision else { throw RenderError.unavailable }
        // The Canvas receipt can arrive after the earlier bitmap was captured.
        // Capture the settled SwiftUI cards as well as their current hit geometry.
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        hosting.cacheDisplay(in: bounds, to: bitmap)
        if let image = bitmap.representation(using: .png, properties: [:]), image.count <= 2_000_000 {
            return Frame(image: image, mimeType: "image/png", width: width, height: height)
        }
        for quality in [0.98, 0.94] {
            if let image = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]), image.count <= 2_000_000 {
                return Frame(image: image, mimeType: "image/jpeg", width: width, height: height)
            }
        }
        throw RenderError.unavailable
    }

    public enum RenderError: Error { case unavailable, invalidAction, superseded }
}
