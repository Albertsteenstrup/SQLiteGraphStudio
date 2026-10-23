import CoreGraphics
import Testing
@testable import StudioCore

@MainActor
struct GraphHoverPresentationTests {
    @Test(arguments: [CGFloat(0.005), 0.2, 0.8])
    func focusedNeighboursKeepSummaryHitTargetsAndHoverNeverRevealsFields(zoom: CGFloat) throws {
        let frames = ["root": CGRect(x: 420 - 220 * zoom, y: 350 - 118 * zoom, width: 440 * zoom, height: 236 * zoom),
                      "related": CGRect(x: 100 - 140 * zoom, y: 350 - 23 * zoom, width: 280 * zoom, height: 46 * zoom)]
        let cache = GraphInteractionGeometryCache()
        let summarySize = CGSize(width: 66, height: CGFloat(46) * 66 / 280)
        func snapshot(hovered: String?) -> GraphInteractionGeometry {
            cache.snapshot(frames: frames, viewport: CGRect(x: 0, y: 0, width: 840, height: 700), zoom: zoom,
                isLarge: true, emphasized: ["root"], primary: ["root"], contentRevision: 0,
                hoveredID: hovered, focusRootID: "root", focusSummarySizes: ["related": summarySize],
                roleForNode: { _ in .expandedNode }, descriptorForNode: { _ in Self.descriptor })
        }
        let resting = snapshot(hovered: nil)
        let hover = snapshot(hovered: "related")
        #expect(resting.markerFrames["related"]?.size == summarySize)
        let card = try #require(hover.anchorMap.nodeCards["related"])
        #expect(abs(card.frame.width - 252) < 0.000001)
        #expect(abs(card.frame.height - 41.4) < 0.000001)
        #expect(abs(card.frame.width / card.frame.height - 280 / 46) < 0.000001,
                "Connected cards must retain the normal one-row card proportions on hover")
        #expect(card.rowFrames.isEmpty)
        #expect(!hover.renderPlan.detailIDs.contains("related"))
        #expect(hover.hitCandidates(at: CGPoint(x: card.frame.minX + 2, y: card.frame.midY)).contains("related"))
        #expect(resting.frames == hover.frames, "Hover must leave saved/world geometry alone")
    }

    private static var descriptor: EditableTableDescriptor {
        EditableTableDescriptor(name: "sample", objectType: .table,
            columns: (0..<10).map { TableColumn(name: "column_\($0)", declaredType: "TEXT", notNull: false, defaultValueSQL: nil, primaryKeyOrdinal: 0, hiddenValue: 0) },
            primaryKeyColumns: [], rowIdentityStrategy: .readOnly, isWithoutRowID: false, isEditable: false)
    }

    @Test func focusedSummaryHoverDoesNotCaptureTheLargerWorldCardBounds() {
        let geometry = GraphInteractionGeometryCache().snapshot(
            frames: ["related": CGRect(x: -180, y: 327, width: 560, height: 46)],
            viewport: CGRect(x: 0, y: 0, width: 840, height: 700), zoom: 1,
            isLarge: true, emphasized: [], contentRevision: 0, hoveredID: "related",
            focusSummarySizes: ["related": CGSize(width: 66, height: CGFloat(46) * 66 / 280)],
            roleForNode: { _ in .collapsedNode }, descriptorForNode: { _ in nil })
        #expect(geometry.hitCandidates(at: CGPoint(x: 100, y: 350)) == ["related"])
        #expect(geometry.hitCandidates(at: CGPoint(x: 300, y: 350)).isEmpty)
    }

    @Test func markerHoverShowsOnlyReadableSummaryWithMatchingHitTargetsWithoutChangingLayout() throws {
        let frames = ["root": CGRect(x: 396.2, y: 299.54, width: 7.6, height: 0.92),
                      "related": CGRect(x: 100, y: 50, width: 8, height: 3),
                      "other": CGRect(x: 150, y: 50, width: 8, height: 3)]
        let cache = GraphInteractionGeometryCache()
        func snapshot(hovered: String?) -> GraphInteractionGeometry {
            cache.snapshot(frames: frames, viewport: CGRect(x: 0, y: 0, width: 800, height: 600),
                           zoom: 0.02, isLarge: true, emphasized: [], contentRevision: 0,
                           hoveredID: hovered,
                           connectedIDs: hovered == nil ? [] : ["related"],
                           roleForNode: { _ in .collapsedNode },
                           descriptorForNode: { _ in Self.descriptor })
        }
        let original = snapshot(hovered: nil)
        let hover = snapshot(hovered: "root")
        let root = try #require(hover.anchorMap.nodeCards["root"]?.frame)
        let related = try #require(hover.markerFrames["related"])
        #expect(hover.frames == original.frames)
        #expect(root.midX == frames["root"]!.midX && root.midY == frames["root"]!.midY)
        #expect(abs(root.width - 342) < 0.000001)
        #expect(abs(root.height - 41.4) < 0.000001)
        #expect(related.width > frames["related"]!.width)
        #expect(hover.renderPlan.detailIDs == ["root"])
        #expect(hover.markerFrames["root"] == nil)
        #expect(hover.markerFrames["other"] == original.markerFrames["other"])
        #expect(hover.anchorMap.nodeCards["root"]?.frame == root)
        #expect(hover.anchorMap.nodeCards["root"]?.rowFrames.isEmpty == true)
        let addedArea = CGPoint(x: (root.minX + frames["root"]!.minX) / 2, y: root.midY)
        #expect(hover.hitCandidates(at: addedArea) == ["root"])
        #expect(original.hitCandidates(at: addedArea).isEmpty)
        #expect(snapshot(hovered: "root").revision == hover.revision)
        #expect(snapshot(hovered: nil).markerFrames == original.markerFrames)
    }

    @Test(arguments: [CGFloat(0.3), 1])
    func detailHoverKeepsRowsAndHeaderAlignedWithScaledCard(zoom: CGFloat) throws {
        let descriptor = Self.descriptor
        let frame = CGRect(x: 100, y: 100, width: 440 * zoom, height: 236 * zoom)
        let snapshot = GraphInteractionGeometryCache().snapshot(
            frames: ["table": frame], viewport: CGRect(x: 0, y: 0, width: 1000, height: 800),
            zoom: zoom, isLarge: false, emphasized: [], contentRevision: 0, hoveredID: "table",
            roleForNode: { _ in .expandedNode }, descriptorForNode: { _ in descriptor }
        )
        let card = try #require(snapshot.anchorMap.nodeCards["table"])
        let first = try #require(card.rowFrames[descriptor.columns[0].name])
        let expectedScale = max(zoom, 0.9)
        #expect(abs(card.frame.width - 440 * expectedScale) < 0.000001)
        #expect(abs(first.minY - card.frame.minY - 56 * expectedScale) < 0.000001)
        #expect(abs(first.height - 24 * expectedScale) < 0.000001)
        #expect(first.minY >= card.headerFrame.maxY)
        #expect(card.columnName(at: CGPoint(x: first.midX, y: first.midY)) == descriptor.columns[0].name)
        #expect(snapshot.hitCandidates(at: CGPoint(x: card.frame.minX + 1, y: card.frame.midY)) == ["table"])
    }

    @Test func hoverSummaryStaysReadableWhenExpandedTablesFillTheBudget() {
        var frames = Dictionary(uniqueKeysWithValues: (0..<2_000).map {
            ("table_\($0)", CGRect(x: 380, y: 280, width: 35.2, height: 18.88))
        })
        frames["hovered"] = CGRect(x: 700, y: 500, width: 30.4, height: 3.68)
        let snapshot = GraphInteractionGeometryCache().snapshot(
            frames: frames, viewport: CGRect(x: 0, y: 0, width: 800, height: 600),
            zoom: 0.08, isLarge: true, emphasized: [], primary: Set(frames.keys), contentRevision: 0,
            hoveredID: "hovered",
            roleForNode: { $0 == "hovered" ? .collapsedNode : .expandedNode },
            descriptorForNode: { _ in Self.descriptor }
        )
        #expect(snapshot.renderPlan.detailIDs.contains("hovered"))
        #expect(snapshot.renderPlan.detailIDs.count == 160)
        #expect(snapshot.anchorMap.nodeCards["hovered"]?.rowFrames.isEmpty == true)
        #expect(snapshot.markerFrames["hovered"] == nil)
    }

    @Test(arguments: [CGFloat(0.005), 0.1, 0.4, 0.42, 1, 2])
    func hoverMatchesFocusedCardSizeAtEveryZoom(zoom: CGFloat) throws {
        let frames = ["root": CGRect(x: 1000 - 190 * zoom, y: 500 - 23 * zoom, width: 380 * zoom, height: 46 * zoom),
                      "related": CGRect(x: 900, y: 50, width: 380 * zoom, height: 46 * zoom),
                      "unrelated": CGRect(x: 900, y: 500, width: 380 * zoom, height: 46 * zoom)]
        let cache = GraphInteractionGeometryCache()
        func snapshot(_ hovered: String?) -> GraphInteractionGeometry {
            cache.snapshot(frames: frames, viewport: CGRect(x: 0, y: 0, width: 2000, height: 1000),
                           zoom: zoom, isLarge: true, emphasized: [], contentRevision: 0,
                           hoveredID: hovered, connectedIDs: hovered == nil ? [] : ["related"],
                           roleForNode: { _ in .collapsedNode }, descriptorForNode: { _ in nil })
        }
        let original = snapshot(nil)
        let hovered = snapshot("root")
        let focused = GraphInteractionGeometryCache().snapshot(
            frames: frames, viewport: CGRect(x: 0, y: 0, width: 2000, height: 1000),
            zoom: zoom, isLarge: true, emphasized: ["root"], contentRevision: 0,
            focusRootID: "root", roleForNode: { _ in .collapsedNode }, descriptorForNode: { _ in nil }
        )
        let root = try #require(hovered.anchorMap.nodeCards["root"]?.frame)
        #expect(root == focused.anchorMap.nodeCards["root"]?.frame)
        #expect(abs(root.width - 380 * max(zoom, 0.9)) < 0.000001)
        #expect(abs(root.height - 46 * max(zoom, 0.9)) < 0.000001)
        #expect(abs(root.midX - frames["root"]!.midX) < 0.000001)
        #expect(abs(root.midY - frames["root"]!.midY) < 0.000001)
        let relatedBefore = try #require(original.anchorMap.nodeCards["related"]?.frame)
        let relatedAfter = try #require(hovered.anchorMap.nodeCards["related"]?.frame)
        #expect(relatedAfter.width > relatedBefore.width && relatedAfter.width <= relatedBefore.width * 1.026)
        #expect(relatedAfter.height > relatedBefore.height && relatedAfter.height <= relatedBefore.height * 1.026)
        #expect(abs(relatedAfter.midX - relatedBefore.midX) < 0.000001)
        #expect(abs(relatedAfter.midY - relatedBefore.midY) < 0.000001)
        #expect(original.anchorMap.nodeCards["unrelated"]?.frame == hovered.anchorMap.nodeCards["unrelated"]?.frame)
        #expect(snapshot(nil).anchorMap.nodeCards["root"]?.frame == original.anchorMap.nodeCards["root"]?.frame)
        #expect(hovered.frames == original.frames)
    }

    @Test func summariesUseOnlyVisibleImmediateNeighborsWithoutChangingTheirTargets() {
        let frames = ["root": CGRect(x: 400, y: 300, width: 8, height: 3),
                      "neighbor": CGRect(x: 100, y: 100, width: 8, height: 3),
                      "offscreen": CGRect(x: 9000, y: 100, width: 8, height: 3),
                      "unrelated": CGRect(x: 600, y: 200, width: 8, height: 3)]
        let viewport = CGRect(x: 0, y: 0, width: 800, height: 600)
        let neighbors: Set<String> = ["neighbor", "offscreen", "filtered"]
        let ids = GraphHoverPresentation.summaryIDs(hoveredID: "root", connectedIDs: neighbors,
                                                     markerFrames: frames, viewport: viewport)
        #expect(ids == ["root", "neighbor"])
        #expect(GraphHoverPresentation.summaryIDs(hoveredID: nil, connectedIDs: neighbors,
                                                  markerFrames: frames, viewport: viewport).isEmpty)
        // An already detailed hovered card can still reveal its neighboring markers.
        #expect(GraphHoverPresentation.summaryIDs(hoveredID: "detail", connectedIDs: neighbors,
                                                  markerFrames: frames, viewport: viewport) == ["neighbor"])
    }

    @Test(arguments: [CGFloat(0.005), 0.1, 0.42, 1, 2.4])
    func hoverNearViewportCornersKeepsAllSummaryDetailsInsideCanvas(zoom: CGFloat) throws {
        let viewport = CGRect(x: 0, y: 0, width: 800, height: 600)
        for center in [CGPoint(x: 2, y: 2), CGPoint(x: 798, y: 2),
                       CGPoint(x: 2, y: 598), CGPoint(x: 798, y: 598)] {
            let frame = CGRect(x: center.x - 280 * zoom, y: center.y - 23 * zoom,
                               width: 560 * zoom, height: 46 * zoom)
            let snapshot = GraphInteractionGeometryCache().snapshot(
                frames: ["table": frame], viewport: viewport, zoom: zoom,
                isLarge: true, emphasized: [], contentRevision: 0, hoveredID: "table",
                roleForNode: { _ in .collapsedNode }, descriptorForNode: { _ in nil }
            )
            let card = try #require(snapshot.anchorMap.nodeCards["table"])
            #expect(viewport.insetBy(dx: 11.99, dy: 11.99).contains(card.frame))
            #expect(card.frame.height >= 41.4 - 0.000001)
            #expect(abs(card.frame.width / card.frame.height - 560 / 46) < 0.000001)
            #expect(card.rowFrames.isEmpty)
            #expect(snapshot.hitCandidates(at: CGPoint(x: card.frame.minX + 1, y: card.frame.midY)) == ["table"])
            #expect(snapshot.hitCandidates(at: center) == ["table"],
                    "The source marker must retain hover when the summary moves away from an edge")
            #expect(snapshot.frames["table"] == frame)
        }
    }

    @Test(arguments: [CGSize(width: 3, height: 3), CGSize(width: 18, height: 3),
                      CGSize(width: 160, height: 19), CGSize(width: 176, height: 94)])
    func summariesStayInsideOriginalNodesWithoutPopupSpace(size: CGSize) {
        let frame = CGRect(origin: CGPoint(x: 250, y: 400), size: size)
        let reference = CGSize(width: 380, height: 46)
        let summary = GraphHoverPresentation.summaryFrame(in: frame, referenceSize: reference)
        #expect(frame.insetBy(dx: -0.000001, dy: -0.000001).contains(summary))
        #expect(summary.midX == frame.midX && summary.midY == frame.midY)
        #expect(abs(summary.width / summary.height - reference.width / reference.height) < 0.000001)
    }
}
