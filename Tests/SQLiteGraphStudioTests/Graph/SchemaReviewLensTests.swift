import CoreGraphics
import Foundation
import GRDB
import Testing
@testable import StudioCore

/// Covers what a schema review puts in front of the reader: every change by default,
/// one table's changes once it is chosen, and names readable at overview zoom.
@MainActor
struct SchemaReviewLensTests {
    // A removed table with a removed relation to a hub, an unrelated added relation, and
    // a hub whose unchanged relations must never compete with its changes.
    private static let edges = [
        GraphEdge(id: "gone_fk:0", sourceID: "gone", targetID: "hub", sourceColumn: "hub_id", targetColumn: "id"),
        GraphEdge(id: "new_fk:0", sourceID: "fresh", targetID: "other", sourceColumn: "other_id", targetColumn: "id"),
        GraphEdge(id: "kept_fk:0", sourceID: "plain", targetID: "hub", sourceColumn: "hub_id", targetColumn: "id"),
    ]
    private static let tableKinds: [String: SchemaChangeKind] = [
        "gone": .removed, "hub": .modified, "fresh": .added, "other": .modified, "plain": .unchanged,
    ]
    private static let edgeKinds: [String: SchemaChangeKind] = [
        "gone_fk:0": .removed, "new_fk:0": .added, "kept_fk:0": .unchanged,
    ]

    private func lens(selecting selection: Set<String> = []) -> SchemaReviewLens {
        SchemaReviewLens(tableKinds: Self.tableKinds, edgeKinds: Self.edgeKinds, edges: Self.edges, selection: selection)
    }

    private func edge(_ id: String) -> GraphEdge { Self.edges.first { $0.id == id }! }

    @Test func withNothingChosenEveryChangeIsTheSubject() {
        let lens = lens()
        #expect(!lens.isFocused)
        for id in ["gone", "hub", "fresh", "other"] { #expect(lens.emphasis(forTable: id) == .subject) }
        #expect(lens.emphasis(forTable: "plain") == .context)
        #expect(lens.emphasis(for: edge("gone_fk:0")) == .subject)
        #expect(lens.emphasis(for: edge("new_fk:0")) == .subject)
        #expect(lens.emphasis(for: edge("kept_fk:0")) == .context)
    }

    @Test func choosingATableIsolatesItsOwnChanges() {
        let lens = lens(selecting: ["gone"])
        #expect(lens.isFocused)
        // The chosen table, its changed relation, and the table at the far end stay in front.
        #expect(lens.emphasis(forTable: "gone") == .subject)
        #expect(lens.emphasis(forTable: "hub") == .subject)
        #expect(lens.emphasis(for: edge("gone_fk:0")) == .subject)
        // Changes elsewhere fade but stay on the canvas.
        #expect(lens.emphasis(forTable: "fresh") == .faded)
        #expect(lens.emphasis(for: edge("new_fk:0")) == .faded)
        #expect(lens.emphasis(for: edge("kept_fk:0")) == .context)
        #expect(lens.labelOrder == ["gone", "hub"])
    }

    @Test func choosingAnUnchangedTableKeepsEveryChangeInView() {
        let lens = lens(selecting: ["plain"])
        #expect(!lens.isFocused)
        #expect(lens.emphasis(for: edge("new_fk:0")) == .subject)
    }

    @Test func hoverReachesOnlyTablesJoinedByAChangedRelation() {
        let lens = lens()
        // The hub has an unchanged neighbour too; only the changed one answers the pointer.
        #expect(lens.changedNeighbors(of: "hub") == ["gone"])
        #expect(lens.changedNeighbors(of: "plain").isEmpty)
    }

    @Test func wholeTableAdditionsAndRemovalsClaimLabelSpaceFirst() {
        #expect(lens().labelOrder == ["fresh", "gone", "hub", "other"])
    }

    // MARK: - Labels

    private func candidate(_ id: String, x: CGFloat, y: CGFloat = 100, width: CGFloat = 80,
                           pinned: Bool = false) -> GraphNameLabelLayout.Candidate {
        .init(id: id, anchor: CGRect(x: x, y: y, width: 60, height: 6),
              size: CGSize(width: width, height: GraphNameLabelLayout.height), isPinned: pinned)
    }

    @Test func labelsSitOverTheirTableAndGiveWayInsteadOfStacking() {
        let viewport = CGRect(x: 0, y: 0, width: 800, height: 600)
        let placed = GraphNameLabelLayout.place([
            candidate("first", x: 100),
            candidate("second", x: 110),
            candidate("third", x: 120),
            candidate("apart", x: 500),
        ], in: viewport)
        let frames = Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0.frame) })
        #expect(frames["first"]?.midY == 103)
        // Crowded names move just above or below their table; beyond that they drop.
        #expect(frames["second"].map { $0.maxY < 100 } == true)
        #expect(frames["third"].map { $0.minY > 106 } == true)
        #expect(frames["apart"] != nil)
        for (index, lhs) in placed.enumerated() {
            for rhs in placed.dropFirst(index + 1) { #expect(!lhs.frame.intersects(rhs.frame)) }
        }

        let crowded = GraphNameLabelLayout.place((0..<6).map { candidate("t\($0)", x: 100 + CGFloat($0)) }, in: viewport)
        #expect(crowded.count == 3)
    }

    @Test func theTableUnderThePointerIsAlwaysNamed() {
        let viewport = CGRect(x: 0, y: 0, width: 800, height: 600)
        let placed = GraphNameLabelLayout.place(
            (0..<4).map { candidate("t\($0)", x: 100) } + [candidate("hovered", x: 100, pinned: true)],
            in: viewport
        )
        // Pinned labels claim space first, whatever order they arrive in.
        #expect(placed.first?.id == "hovered")
        #expect(placed.first?.frame.midY == 103)
    }

    @Test func labelsStayInsideTheViewport() {
        let viewport = CGRect(x: 0, y: 0, width: 300, height: 200)
        let placed = GraphNameLabelLayout.place([
            candidate("edge", x: 280, y: 100, width: 120),
            candidate("pinnedCorner", x: 290, y: 195, width: 120, pinned: true),
        ], in: viewport)
        #expect(placed.allSatisfy { viewport.contains($0.frame) })
        #expect(placed.contains { $0.id == "pinnedCorner" })
    }

    @Test func longNamesKeepTheirBeginningAndEnd() {
        let measure: (String) -> CGFloat = { CGFloat($0.count) }
        #expect(GraphNameLabelLayout.fittedTitle("short", maximumWidth: 20, measure: measure) == "short")
        let fitted = GraphNameLabelLayout.fittedTitle("field_research_source_attempt_evidence", maximumWidth: 21, measure: measure)
        #expect(fitted.count == 21)
        #expect(fitted.hasPrefix("field_rese") && fitted.hasSuffix("evidence") && fitted.contains("…"))
    }

    // MARK: - Reveal

    @Test func revealLeavesAVisibleTableAlone() {
        let current = GraphViewportTransform(zoom: 0.2, pan: .zero)
        let bounds = CGRect(x: -100, y: -20, width: 200, height: 40)
        #expect(GraphViewportTransform.reveal(contentBounds: bounds, in: CGSize(width: 800, height: 600), from: current) == nil)
    }

    @Test func revealPansAtTheReadersZoomAndNeverZoomsIn() throws {
        let current = GraphViewportTransform(zoom: 0.2, pan: .zero)
        let viewport = CGSize(width: 800, height: 600)
        let offscreen = CGRect(x: 5_000, y: 0, width: 200, height: 40)
        let panned = try #require(GraphViewportTransform.reveal(contentBounds: offscreen, in: viewport, from: current))
        #expect(panned.zoom == 0.2)
        let rect = panned.rect(for: offscreen, in: viewport)
        #expect(abs(rect.midX - 400) < 0.001 && abs(rect.midY - 300) < 0.001)

        // Only as far out as needed to fit the table and the far ends of its changes.
        let spread = CGRect(x: -6_000, y: 0, width: 12_000, height: 40)
        let zoomedOut = try #require(GraphViewportTransform.reveal(contentBounds: spread, in: viewport, from: current))
        #expect(zoomedOut.zoom < 0.2)
        #expect(CGRect(origin: .zero, size: viewport).contains(zoomedOut.rect(for: spread, in: viewport)))
    }

    // MARK: - Session

    private func openReview() async throws -> (AppSession, cleanup: @MainActor () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("schema-review-lens-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func fixture(_ sql: String, at url: URL) throws {
            let database = try DatabaseQueue(path: url.path)
            try database.write { try $0.execute(sql: sql) }
            try database.close()
        }
        func capture(_ sql: String, name: String) async throws -> SchemaReviewSnapshot {
            let url = root.appendingPathComponent(name)
            try fixture(sql, at: url)
            return try await SchemaReviewCapture.snapshot(document: url)
        }
        let before = try await capture("""
            CREATE TABLE hub(id INTEGER PRIMARY KEY);
            CREATE TABLE gone(id INTEGER PRIMARY KEY, hub_id INTEGER REFERENCES hub(id));
            """, name: "before.sqlite")
        let after = try await capture("""
            CREATE TABLE hub(id INTEGER PRIMARY KEY);
            CREATE TABLE fresh(id INTEGER PRIMARY KEY);
            """, name: "after.sqlite")
        let url = root.appendingPathComponent("change.sgreview")
        try SchemaReviewDocument(title: "Lens", baseRef: "a", headRef: "b", before: before, after: after).write(to: url)
        let suite = "SchemaReviewLensTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        let session = AppSession(userDefaults: defaults)
        await session.openDocument(url: url)
        return (session, {
            session.closeDatabase()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        })
    }

    @Test func aReviewOpensOnEveryChangeAndRevealsTheChosenTable() async throws {
        let (session, cleanup) = try await openReview(); defer { cleanup() }
        #expect(session.presentedError == nil && session.schemaReview != nil)
        // Nothing is pre-chosen, so the graph opens showing every change.
        #expect(session.selectedGraphNodeID == nil && session.selectedGraphNodeIDs.isEmpty)
        #expect(session.schemaReviewChanges["gone"]?.kind == .removed)

        session.revealGraphNode("gone")
        #expect(session.selectedGraphNodeID == "gone")
        let first = try #require(session.graphRevealRequest)
        #expect(first.tableID == "gone")
        // Choosing the same table again still asks for it to be shown.
        session.revealGraphNode("gone")
        #expect(session.graphRevealRequest?.id != first.id)

        session.revealGraphNode("missing")
        #expect(session.selectedGraphNodeID == "gone")

        let revision = session.schemaReviewRevision
        session.closeDatabase()
        #expect(session.graphRevealRequest == nil && session.schemaReviewRevision != revision)
    }
}
