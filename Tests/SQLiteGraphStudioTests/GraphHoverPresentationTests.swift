import CoreGraphics
import Testing
@testable import StudioCore

@MainActor
struct GraphHoverPresentationTests {
    private static var descriptor: EditableTableDescriptor {
        EditableTableDescriptor(name: "sample", objectType: .table,
            columns: (0..<10).map { TableColumn(name: "column_\($0)", declaredType: "TEXT", notNull: false, defaultValueSQL: nil, primaryKeyOrdinal: 0, hiddenValue: 0) },
            primaryKeyColumns: [], rowIdentityStrategy: .readOnly, isWithoutRowID: false, isEditable: false)
    }

    @Test func markerHoverKeepsCenterAndMatchesHitTargetsWithoutChangingLayout() throws {
        let frames = ["root": CGRect(x: 50, y: 50, width: 8, height: 3),
                      "related": CGRect(x: 100, y: 50, width: 8, height: 3),
                      "other": CGRect(x: 150, y: 50, width: 8, height: 3)]
        let cache = GraphInteractionGeometryCache()
        func snapshot(hovered: String?) -> GraphInteractionGeometry {
            cache.snapshot(frames: frames, viewport: CGRect(x: 0, y: 0, width: 800, height: 600),
                           zoom: 0.02, isLarge: true, emphasized: [], contentRevision: 0,
                           hoveredID: hovered, connectedIDs: hovered == nil ? [] : ["related"],
                           roleForNode: { _ in .expandedNode }, descriptorForNode: { _ in Self.descriptor })
        }
        let original = snapshot(hovered: nil)
        let hover = snapshot(hovered: "root")
        let root = try #require(hover.markerFrames["root"])
        let related = try #require(hover.markerFrames["related"])
        #expect(hover.frames == original.frames)
        #expect(root.midX == frames["root"]!.midX && root.midY == frames["root"]!.midY)
        #expect(root.width > related.width && related.width > frames["related"]!.width)
        #expect(hover.markerFrames["other"] == original.markerFrames["other"])
        #expect(hover.anchorMap.nodeCards["root"]?.frame == root)
        #expect(hover.anchorMap.nodeCards["root"]?.rowFrames.isEmpty == true)
        let addedArea = CGPoint(x: root.minX + 0.1, y: root.midY)
        #expect(hover.hitCandidates(at: addedArea) == ["root"])
        #expect(original.hitCandidates(at: addedArea).isEmpty)
        #expect(snapshot(hovered: "root").revision == hover.revision)
        #expect(snapshot(hovered: nil).markerFrames == original.markerFrames)
    }

    @Test func detailHoverKeepsRowsAndHeaderAlignedWithScaledCard() throws {
        let descriptor = Self.descriptor
        let frame = CGRect(x: 100, y: 100, width: 440, height: 236)
        let snapshot = GraphInteractionGeometryCache().snapshot(
            frames: ["table": frame], viewport: CGRect(x: 0, y: 0, width: 1000, height: 800),
            zoom: 1, isLarge: false, emphasized: [], contentRevision: 0, hoveredID: "table",
            roleForNode: { _ in .expandedNode }, descriptorForNode: { _ in descriptor }
        )
        let card = try #require(snapshot.anchorMap.nodeCards["table"])
        let first = try #require(card.rowFrames[descriptor.columns[0].name])
        #expect(card.frame.width == frame.width * GraphHoverPresentation.detailScale)
        #expect(first.minY >= card.headerFrame.maxY)
        #expect(card.columnName(at: CGPoint(x: first.midX, y: first.midY)) == descriptor.columns[0].name)
        #expect(snapshot.hitCandidates(at: CGPoint(x: card.frame.minX + 1, y: card.frame.midY)) == ["table"])
    }

    @Test(arguments: [CGSize(width: 320, height: 420), CGSize(width: 800, height: 600), CGSize(width: 1400, height: 900)])
    func crowdedPreviewAvoidsPointerAndOtherLabels(viewportSize: CGSize) throws {
        let viewport = CGRect(origin: .zero, size: viewportSize)
        var frames: [String: CGRect] = [:]
        for i in 0..<90 {
            frames["n\(i)"] = CGRect(x: viewport.midX + CGFloat(i % 3) * 10,
                                     y: viewport.midY + CGFloat(i / 3) * 3, width: 4, height: 3)
        }
        let neighbors = Set(frames.keys)
        let preview = GraphHoverPresentation.preview(hoveredID: "n0", neighborIDs: neighbors, frames: frames, viewport: viewport)
        #expect(preview.labels.first?.id == "n0")
        #expect(preview.additionalTableCount + preview.labels.count == frames.count)
        for (index, label) in preview.labels.enumerated() {
            #expect(viewport.contains(label.frame))
            #expect(!label.frame.intersects(frames["n0"]!))
            for other in preview.labels.dropFirst(index + 1) {
                #expect(!label.frame.intersects(other.frame))
            }
        }
        #expect(preview.labels == GraphHoverPresentation.preview(hoveredID: "n0", neighborIDs: neighbors, frames: frames, viewport: viewport).labels)
    }

    @Test func annotationsAvoidGraphControlsAndMinimap() {
        let viewport = CGRect(x: 0, y: 0, width: 900, height: 650)
        let controls = CGRect(x: 0, y: 0, width: 900, height: 80)
        let minimap = CGRect(x: 0, y: 470, width: 180, height: 180)
        let frames = ["root": CGRect(x: 180, y: 80, width: 40, height: 4),
                      "related": CGRect(x: 100, y: 520, width: 40, height: 4)]
        let preview = GraphHoverPresentation.preview(hoveredID: "root", neighborIDs: ["related"], frames: frames,
                                                     viewport: viewport, excluding: [controls, minimap])
        #expect(preview.labels.count == 2)
        for label in preview.labels {
            #expect(!controls.intersects(label.frame))
            #expect(!minimap.intersects(label.frame))
        }
    }

    @Test func previewContainsOnlyImmediateScopedNeighborsAndReportsOffscreenTables() {
        let frames = ["root": CGRect(x: 400, y: 300, width: 8, height: 3),
                      "neighbor": CGRect(x: 100, y: 100, width: 8, height: 3),
                      "offscreen": CGRect(x: 9000, y: 100, width: 8, height: 3),
                      "unrelated": CGRect(x: 600, y: 200, width: 8, height: 3)]
        let preview = GraphHoverPresentation.preview(hoveredID: "root", neighborIDs: ["root", "neighbor", "offscreen", "filtered"],
                                                     frames: frames, viewport: CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(Set(preview.labels.map(\.id)) == ["root", "neighbor"])
        #expect(preview.additionalTableCount == 1)
        #expect(GraphHoverPresentation.preview(hoveredID: nil, neighborIDs: [], frames: frames, viewport: .zero).labels.isEmpty)
    }
}
