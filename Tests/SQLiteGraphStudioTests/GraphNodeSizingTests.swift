import CoreGraphics
import Foundation
import GRDB
import Testing
@testable import StudioCore

@MainActor
struct GraphNodeSizingTests {
    private func table(_ name: String, fields: Int = 8, rows: Int? = nil) -> TableSummary {
        TableSummary(name: name, objectType: .table, isEditable: true, columnCount: fields, rowCount: rows)
    }

    @Test func fieldsRowsAndRelationsUseTheirOwnCountsAndUnknownIsNotZero() throws {
        let tables = [table("a", fields: 2, rows: 0), table("b", fields: 20, rows: 1_000_000), table("c", fields: 8)]
        let fields = GraphNodeSizeProfile(metric: .fields, tables: tables, rowCounts: [:], relationCounts: ["a": 10, "b": 1])
        let rows = GraphNodeSizeProfile(metric: .rows, tables: tables, rowCounts: [:], relationCounts: [:])
        let relations = GraphNodeSizeProfile(metric: .relations, tables: tables, rowCounts: [:], relationCounts: ["a": 10, "b": 1])
        #expect(fields.areas["a"]! < fields.areas["c"]! && fields.areas["c"]! < fields.areas["b"]!)
        #expect(rows.areas["a"] == 0.12)
        #expect(rows.areas["b"] == 1)
        #expect(rows.areas["c"] == nil && rows.unknownIDs == ["c"])
        #expect(relations.areas["a"]! > relations.areas["b"]! && relations.areas["b"]! > relations.areas["c"]!)
        #expect(relations.unknownIDs.isEmpty)
        let counted = GraphNodeSizeProfile(metric: .rows, tables: tables, rowCounts: ["c": 0, "b": 10], relationCounts: [:])
        #expect(counted.unknownIDs.isEmpty)
        #expect(counted.areas["c"] == counted.areas["a"])
        #expect(counted.areas["b"] == 1)
    }

    @Test func logarithmicCompressionHandlesZeroOutliersAndMissingMetadata() {
        let tables = [table("zero", rows: 0), table("one", rows: 1), table("many", rows: 10_000),
                      table("huge", rows: Int.max), table("negative", rows: -1), table("unknown")]
        let profile = GraphNodeSizeProfile(metric: .rows, tables: tables, rowCounts: [:], relationCounts: [:])
        #expect(profile.unknownIDs == ["negative", "unknown"])
        #expect(profile.areas.values.allSatisfy { $0.isFinite && (0.12...1).contains($0) })
        #expect(profile.areas["one"]! < profile.areas["many"]!)
        #expect(profile.areas["many"]! > 0.2) // Still visible beside a 64-bit outlier.
        let empty = GraphNodeSizeProfile(metric: .rows, tables: [], rowCounts: [:], relationCounts: [:])
        #expect(empty.areas.isEmpty && empty.unknownIDs.isEmpty)
    }

    @Test func zoomInRestoresOriginalSizesAndZoomOutStrengthensDifferences() {
        let tables = [table("small", fields: 1), table("large", fields: 100)]
        let profile = GraphNodeSizeProfile(metric: .fields, tables: tables, rowCounts: [:], relationCounts: [:])
        var previousRatio: CGFloat = 1
        for zoom: CGFloat in [0.42, 0.38, 0.3, 0.2, 0.1, 0.08] {
            let frame = CGRect(x: 200, y: 200, width: 380 * zoom, height: 46 * zoom)
            let small = profile.markerFrame(for: "small", frame: frame, zoom: zoom)
            let large = profile.markerFrame(for: "large", frame: frame, zoom: zoom)
            #expect(abs(small.midX - frame.midX) < 0.000001 && abs(small.midY - frame.midY) < 0.000001)
            #expect(abs(large.midX - frame.midX) < 0.000001 && abs(large.midY - frame.midY) < 0.000001)
            #expect(frame.contains(small) && frame.contains(large))
            let ratio = large.width / small.width
            #expect(ratio >= previousRatio)
            previousRatio = ratio
        }
        let frame = CGRect(x: 20, y: 20, width: 150, height: 30)
        #expect(profile.markerFrame(for: "small", frame: frame, zoom: 0.42) == frame)
        #expect(profile.markerFrame(for: "small", frame: frame, zoom: 1) == frame)
        #expect(GraphNodeSizeProfile.uniform.markerFrame(for: "small", frame: frame, zoom: 0.1) == frame)
        #expect(GraphNodeSizeProfile.emphasis(at: .nan) == 0)
    }

    @Test func renderingHoverAnchorsAndHitTargetsShareSizedMarkerGeometry() throws {
        let tables = [table("a", rows: 0), table("b", rows: 1_000)]
        let frames = ["a": CGRect(x: 50, y: 50, width: 76, height: 9.2), "b": CGRect(x: 150, y: 50, width: 76, height: 9.2)]
        let profile = GraphNodeSizeProfile(metric: .rows, tables: tables, rowCounts: [:], relationCounts: [:])
        let cache = GraphInteractionGeometryCache()
        func snapshot(_ profile: GraphNodeSizeProfile, hovered: String? = nil) -> GraphInteractionGeometry {
            cache.snapshot(frames: frames, viewport: CGRect(x: 0, y: 0, width: 800, height: 600),
                           zoom: 0.2, isLarge: true, emphasized: [], contentRevision: 0, hoveredID: hovered,
                           nodeSizing: profile, roleForNode: { _ in .collapsedNode }, descriptorForNode: { _ in nil })
        }
        let original = snapshot(.uniform)
        let sized = snapshot(profile)
        #expect(sized.revision != original.revision)
        #expect(sized.frames == original.frames)
        let mark = try #require(sized.markerFrames["a"])
        #expect(sized.anchorMap.nodeCards["a"]?.frame == mark)
        #expect(sized.hitCandidates(at: CGPoint(x: mark.midX, y: mark.midY)) == ["a"])
        #expect(sized.hitCandidates(at: CGPoint(x: 51, y: 51)).isEmpty)
        #expect(snapshot(profile).revision == sized.revision)
        let hovered = snapshot(profile, hovered: "a")
        let enlarged = try #require(hovered.markerFrames["a"])
        #expect(enlarged.width > mark.width)
        #expect(hovered.hitCandidates(at: CGPoint(x: enlarged.minX + 0.1, y: enlarged.midY)) == ["a"])
        let detail = cache.snapshot(frames: frames, viewport: CGRect(x: 0, y: 0, width: 800, height: 600),
                                    zoom: 1, isLarge: false, emphasized: [], contentRevision: 0, nodeSizing: profile,
                                    roleForNode: { _ in .collapsedNode }, descriptorForNode: { _ in nil })
        #expect(detail.markerFrames.isEmpty)
        #expect(detail.anchorMap.nodeCards["a"]?.frame == frames["a"])
    }

    @Test func preferenceSurvivesRelaunchAndInvalidStoredValueFallsBackToUniform() throws {
        let suite = "GraphNodeSizingTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = AppSession(userDefaults: defaults)
        #expect(session.graphNodeSizeMetric == .uniform)
        session.graphNodeSizeMetric = .fields
        let restored = AppSession(userDefaults: defaults)
        #expect(restored.graphNodeSizeMetric == .fields)
        restored.tables = [table("a", fields: 5), table("b", fields: 10)]
        #expect(restored.graphNodeSizeProfile.areas["a"]! < restored.graphNodeSizeProfile.areas["b"]!)
        defaults.set("invalid", forKey: "SQLiteGraphStudio.graph-node-size-metric")
        #expect(AppSession(userDefaults: defaults).graphNodeSizeMetric == .uniform)
    }

    @Test func filteringPreservesFullSchemaScaleAndClosingClearsOldCounts() async throws {
        let url = TestSupport.temporaryDatabaseURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let database = try DatabaseQueue(path: url.path)
        try await database.write { db in
            try db.execute(sql: """
                CREATE TABLE parent(a INTEGER, b INTEGER, PRIMARY KEY(a,b));
                CREATE TABLE child(id INTEGER PRIMARY KEY, a INTEGER, b INTEGER, parent_id INTEGER REFERENCES child(id),
                                   FOREIGN KEY(a,b) REFERENCES parent(a,b));
                CREATE TABLE isolated(id INTEGER PRIMARY KEY);
                INSERT INTO parent VALUES(1,1);
                INSERT INTO child VALUES(1,1,1,NULL);
                """)
        }
        try database.close()
        let suite = "GraphNodeSizingTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = AppSession(userDefaults: defaults)
        await session.openDatabase(url: url)
        #expect(session.presentedError == nil)
        session.graphNodeSizeMetric = .relations
        #expect(session.graphRelationCounts == ["parent": 1, "child": 2])
        let original = session.graphNodeSizeProfile
        #expect(await session.applyGraphFilter(.init(maximumRelations: 1)))
        #expect(session.graphVisibleTableIDs == ["parent", "isolated"])
        #expect(session.graphNodeSizeProfile == original)
        session.clearGraphFilter()
        #expect(session.graphNodeSizeProfile == original)
        session.graphNodeSizeMetric = .rows
        #expect(await session.applyGraphFilter(.init(maximumRows: 0)))
        #expect(session.graphVisibleTableIDs == ["isolated"])
        #expect(session.graphNodeSizeProfile.areas["isolated"] == 0.12)
        #expect(session.graphNodeSizeProfile.areas["child"] == 1)
        await session.closeAndWait()
        #expect(session.graphNodeSizeProfile.areas.isEmpty)
        #expect(session.graphNodeSizeProfile.unknownIDs.isEmpty)
        #expect(session.graphNodeSizeMetric == .rows)
    }
}
