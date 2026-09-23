import CoreGraphics
import Foundation
import Testing
@testable import StudioCore

/// Covers the travelling relation signals: which way they run, how they are paced, and
/// the bounds that keep a large catalog from animating every edge at once.
struct GraphEdgePulseTests {
    // MARK: - Direction

    @Test
    func signalsTravelFromTheReferencingTableTowardTheReferencedTable() throws {
        let fixture = try RelationFixture()
        let track = fixture.track
        let rhythm = GraphEdgePulseField.rhythm(for: track.seed)

        // Sample one full traversal by cancelling the track's own phase offset.
        let heads = stride(from: 0.05, through: 0.95, by: 0.05).map { fraction -> CGFloat in
            let time = rhythm.travel * fraction - rhythm.offset
            let pulse = GraphEdgePulseField.pulse(on: track, at: time)
            return pulse?.head ?? -1
        }

        #expect(heads.allSatisfy { $0 >= 0 })
        #expect(zip(heads, heads.dropFirst()).allSatisfy { $0 < $1 })

        let points = heads.map { head in
            bezierPoint(start: track.start, control1: track.control1,
                        control2: track.control2, end: track.end, t: head)
        }
        let first = try #require(points.first)
        let last = try #require(points.last)

        // The referencing card sits left of the referenced card in the fixture, so a
        // signal that honours the foreign key moves left to right and never back.
        #expect(zip(points, points.dropFirst()).allSatisfy { $0.x < $1.x })
        #expect(first.x < fixture.postsFrame.maxX + 12)
        #expect(last.x > fixture.authorsFrame.minX - 12)
        #expect(abs(first.y - fixture.foreignKeyAnchor.y) < 4)
        #expect(abs(last.y - fixture.primaryKeyAnchor.y) < 4)
    }

    @Test
    func reversingTheForeignKeyReversesTheSignal() throws {
        let fixture = try RelationFixture()
        let mirrored = GraphEdgePulseTrack(
            edgeID: fixture.track.edgeID,
            start: fixture.track.end,
            control1: fixture.track.control2,
            control2: fixture.track.control1,
            end: fixture.track.start,
            isHighlighted: false
        )
        let rhythm = GraphEdgePulseField.rhythm(for: mirrored.seed)
        let sample = { (fraction: Double) -> CGPoint in
            let pulse = GraphEdgePulseField.pulse(on: mirrored, at: rhythm.travel * fraction - rhythm.offset)
            return bezierPoint(start: mirrored.start, control1: mirrored.control1,
                               control2: mirrored.control2, end: mirrored.end, t: pulse?.head ?? 0)
        }

        #expect(sample(0.9).x < sample(0.1).x)
    }

    // MARK: - Pacing

    @Test
    func everyRelationRestsBetweenFirings() {
        let track = makeTrack(id: "orders.customer_id->customers.id")
        let rhythm = GraphEdgePulseField.rhythm(for: track.seed)
        let samples = (0..<400).map { step in
            GraphEdgePulseField.pulse(on: track, at: rhythm.cycle * Double(step) / 400)
        }

        #expect(samples.contains { $0 != nil })
        #expect(samples.contains { $0 == nil })
    }

    @Test
    func neighbouringRelationsDoNotFireInLockstep() {
        let tracks = (0..<200).map { makeTrack(id: "table_\($0).parent_id->parents.id") }
        let heads = tracks.compactMap { GraphEdgePulseField.pulse(on: $0, at: 1_234.5)?.head }

        // Some fire and some rest at any instant, and those that fire are scattered the
        // length of their edges rather than advancing as one front.
        #expect(heads.count > tracks.count / 5)
        #expect(heads.count < tracks.count)

        let occupiedDeciles = Set(heads.map { min(9, Int($0 * 10)) })
        #expect(occupiedDeciles.count >= 8)
    }

    @Test
    func onlyAboutAThirdOfRelationsAreInMotionAtAnyInstant() {
        let tracks = (0..<400).map { makeTrack(id: "table_\($0).parent_id->parents.id") }
        let firingShares = stride(from: 0.0, through: 52.0, by: 0.13).map { time in
            Double(tracks.count { GraphEdgePulseField.pulse(on: $0, at: time) != nil }) / 400
        }

        // The rest gap is what keeps the graph from shimmering. If a future tweak to the
        // rhythm pushes the duty cycle up, the effect stops being ambient.
        #expect(firingShares.allSatisfy { $0 > 0.2 && $0 < 0.55 })
        let mean = firingShares.reduce(0, +) / Double(firingShares.count)
        #expect(mean > 0.28 && mean < 0.45)
    }

    @Test
    func rhythmDependsOnRelationIdentityAndNotOnTheProcess() {
        // A process-seeded hash would reshuffle every rhythm on relaunch, so the seed is
        // pinned to a known FNV-1a value.
        #expect(GraphEdgePulseField.seed(forEdgeID: "posts.author_id->authors.id") == 16_655_517_485_434_222_199)
        #expect(GraphEdgePulseField.seed(forEdgeID: "posts.author_id->authors.id")
                == GraphEdgePulseField.seed(forEdgeID: "posts.author_id" + "->authors.id"))
    }

    @Test
    func aRelationKeepsItsPhaseWhenGeometryOrHighlightingChanges() {
        let settled = makeTrack(id: "invoices.account_id->accounts.id")
        let panned = GraphEdgePulseTrack(
            edgeID: settled.edgeID,
            start: CGPoint(x: -900, y: 400),
            control1: CGPoint(x: -700, y: 400),
            control2: CGPoint(x: -300, y: 120),
            end: CGPoint(x: -100, y: 120),
            isHighlighted: true
        )

        // An edge that scrolls out of view and back, or gains a highlight, resumes the
        // phase it would have had rather than restarting its travel.
        for time in stride(from: 0.0, through: 30.0, by: 0.37) {
            #expect(GraphEdgePulseField.pulse(on: settled, at: time)?.head
                    == GraphEdgePulseField.pulse(on: panned, at: time)?.head)
        }
    }

    // MARK: - Shape

    @Test
    func theWakeTrailsBehindTheHeadAndStaysOnTheEdge() {
        let tracks = (0..<40).map { makeTrack(id: "edge_\($0)") }
        for track in tracks {
            let rhythm = GraphEdgePulseField.rhythm(for: track.seed)
            for step in 0..<200 {
                guard let pulse = GraphEdgePulseField.pulse(on: track, at: rhythm.cycle * Double(step) / 200) else { continue }
                #expect(pulse.tail >= 0)
                #expect(pulse.tail < pulse.head)
                #expect(pulse.head <= 1)
                #expect(pulse.intensity > 0)
                #expect(pulse.intensity <= 1)
            }
        }
    }

    @Test
    func signalsFadeInAtTheSourceAndOutAtTheTarget() {
        #expect(GraphEdgePulseField.envelope(at: 0) == 0)
        #expect(GraphEdgePulseField.envelope(at: 1) == 0)
        #expect(GraphEdgePulseField.envelope(at: 0.5) == 1)
        #expect(GraphEdgePulseField.envelope(at: 0.05) < GraphEdgePulseField.envelope(at: 0.3))
        #expect(GraphEdgePulseField.envelope(at: 0.95) < GraphEdgePulseField.envelope(at: 0.7))
        // Nothing pops into existence flush against a card edge.
        #expect(GraphEdgePulseField.envelope(at: -0.1) == 0)
        #expect(GraphEdgePulseField.envelope(at: 1.1) == 0)
    }

    @Test
    func nonFiniteClockReadingsDrawNothing() {
        let track = makeTrack(id: "sessions.user_id->users.id")
        #expect(GraphEdgePulseField.pulse(on: track, at: .nan) == nil)
        #expect(GraphEdgePulseField.pulse(on: track, at: .infinity) == nil)
    }

    // MARK: - Selection

    @Test
    func preparationStaysBoundedForLargeCatalogs() {
        let candidates = (0..<6_000).map { makeTrack(id: "edge_\($0)") }
        let selected = GraphEdgePulseField.select(from: candidates)

        #expect(selected.count == GraphEdgePulseField.trackLimit)
        #expect(Set(selected.map(\.edgeID)).count == selected.count)
    }

    @Test
    func smallGraphsAnimateEveryRelation() {
        let candidates = (0..<24).map { makeTrack(id: "edge_\($0)") }
        #expect(GraphEdgePulseField.select(from: candidates).count == 24)
    }

    @Test
    func highlightedRelationsAlwaysKeepTheirSignal() {
        let highlighted = (0..<12).map { makeTrack(id: "hot_\($0)", isHighlighted: true) }
        let rest = (0..<4_000).map { makeTrack(id: "cold_\($0)") }
        let selected = GraphEdgePulseField.select(from: rest + highlighted)
        let selectedIDs = Set(selected.map(\.edgeID))

        #expect(selected.count == GraphEdgePulseField.trackLimit)
        #expect(highlighted.allSatisfy { selectedIDs.contains($0.edgeID) })
    }

    @Test
    func moreHighlightedRelationsThanTheBudgetStayBounded() {
        let highlighted = (0..<500).map { makeTrack(id: "hot_\($0)", isHighlighted: true) }
        let selected = GraphEdgePulseField.select(from: highlighted)

        #expect(selected.count == GraphEdgePulseField.trackLimit)
        #expect(selected.allSatisfy { $0.isHighlighted })
    }

    @Test
    func theCappedSampleSpreadsAcrossTheWholeGraph() {
        let candidates = (0..<6_000).map { makeTrack(id: "edge_\($0)") }
        let selected = GraphEdgePulseField.select(from: candidates)
        let positions = selected.compactMap { track in
            candidates.firstIndex { $0.edgeID == track.edgeID }
        }

        // An even stride, not the first screenful of edges in graph order.
        #expect((positions.min() ?? 0) < 50)
        #expect((positions.max() ?? 0) > 5_900)
        #expect(positions == positions.sorted())
    }

    @Test
    func relationsTooShortToReadAreNotAnimated() {
        let readable = makeTrack(id: "long", start: .zero, end: CGPoint(x: 400, y: 0))
        let cramped = makeTrack(id: "short", start: .zero, end: CGPoint(x: 9, y: 4))
        let selected = GraphEdgePulseField.select(from: [readable, cramped])

        #expect(selected.map(\.edgeID) == ["long"])
    }

    @Test
    func anEmptyOrZeroBudgetPreparesNothing() {
        #expect(GraphEdgePulseField.select(from: []).isEmpty)
        #expect(GraphEdgePulseField.select(from: [makeTrack(id: "edge")], limit: 0).isEmpty)
    }
}

// MARK: - Fixtures

/// A `posts.author_id → authors.id` relation laid out as two expanded cards, so the
/// track under test is built from the same anchors the graph canvas uses.
private struct RelationFixture {
    let postsFrame: CGRect
    let authorsFrame: CGRect
    let foreignKeyAnchor: CGPoint
    let primaryKeyAnchor: CGPoint
    let track: GraphEdgePulseTrack

    init() throws {
        let posts = makeDescriptor(name: "posts", columns: [
            makeColumn(name: "id", type: "INTEGER", primaryKeyOrdinal: 1),
            makeColumn(name: "author_id", type: "INTEGER"),
        ])
        let authors = makeDescriptor(name: "authors", columns: [
            makeColumn(name: "id", type: "INTEGER", primaryKeyOrdinal: 1),
            makeColumn(name: "name", type: "TEXT"),
        ])
        postsFrame = CGRect(
            x: 40, y: 60,
            width: GraphCardLayout.expandedWidth,
            height: GraphCardLayout.nodeSize(title: "posts", descriptor: posts, style: .expanded).height
        )
        authorsFrame = CGRect(
            x: 640, y: 30,
            width: GraphCardLayout.expandedWidth,
            height: GraphCardLayout.nodeSize(title: "authors", descriptor: authors, style: .expanded).height
        )

        let edge = GraphEdge(
            id: "posts.author_id->authors.id",
            sourceID: "posts",
            targetID: "authors",
            sourceColumn: "author_id",
            targetColumn: "id"
        )
        let anchorMap = GraphAnchorMap(nodeCards: [
            "posts": GraphCardGeometry(tableID: "posts", frame: postsFrame, role: .expandedNode, descriptor: posts),
            "authors": GraphCardGeometry(tableID: "authors", frame: authorsFrame, role: .expandedNode, descriptor: authors),
        ])
        let anchors = try #require(anchorMap.edgeAnchors(for: edge))
        foreignKeyAnchor = anchors.source
        primaryKeyAnchor = anchors.target

        // Mirrors the control points the canvas derives for this curve.
        let horizontalDelta = anchors.target.x - anchors.source.x
        let controlOffset = max(32, abs(horizontalDelta) * 0.34)
        track = GraphEdgePulseTrack(
            edgeID: edge.id,
            start: anchors.source,
            control1: CGPoint(x: anchors.source.x + controlOffset, y: anchors.source.y),
            control2: CGPoint(x: anchors.target.x - controlOffset, y: anchors.target.y),
            end: anchors.target,
            isHighlighted: false
        )
    }
}

private func makeTrack(
    id: String,
    start: CGPoint = .zero,
    end: CGPoint = CGPoint(x: 320, y: 140),
    isHighlighted: Bool = false
) -> GraphEdgePulseTrack {
    GraphEdgePulseTrack(
        edgeID: id,
        start: start,
        control1: CGPoint(x: start.x + 80, y: start.y),
        control2: CGPoint(x: end.x - 80, y: end.y),
        end: end,
        isHighlighted: isHighlighted
    )
}

private func makeDescriptor(name: String, columns: [TableColumn]) -> EditableTableDescriptor {
    EditableTableDescriptor(
        name: name,
        objectType: .table,
        columns: columns,
        primaryKeyColumns: columns.filter { $0.primaryKeyOrdinal > 0 }.map(\.name),
        rowIdentityStrategy: .primaryKey,
        isWithoutRowID: false,
        isEditable: true
    )
}

private func makeColumn(name: String, type: String, primaryKeyOrdinal: Int = 0) -> TableColumn {
    TableColumn(
        name: name,
        declaredType: type,
        notNull: false,
        defaultValueSQL: nil,
        primaryKeyOrdinal: primaryKeyOrdinal,
        hiddenValue: 0
    )
}
