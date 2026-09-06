import Foundation
import Testing
@testable import StudioCore

@MainActor
struct GraphStoryMetadataCacheTests {
    @Test(arguments: [false, true])
    func reloadingCorrectedStoryInvalidatesCardsWithoutMovingTables(isPostgres: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GraphStoryMetadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(isPostgres ? "catalog.postgres" : "catalog.sqlite")
        let suite = "GraphStoryMetadataCacheTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let names = isPostgres ? ["public.orders", "public.customers"] : ["orders", "customers"]
        let descriptors = names.map { name in
            EditableTableDescriptor(
                name: name, schemaName: isPostgres ? "public" : nil,
                objectName: isPostgres ? String(name.dropFirst("public.".count)) : name,
                objectType: .table,
                columns: [.init(name: "id", declaredType: "text", notNull: false,
                                defaultValueSQL: nil, primaryKeyOrdinal: 0, hiddenValue: 0)],
                primaryKeyColumns: [], rowIdentityStrategy: .readOnly,
                isWithoutRowID: false, isEditable: false
            )
        }
        let snapshot = CatalogSnapshot(descriptors: descriptors, graph: SchemaGraph(
            nodes: names.map { GraphNode(id: $0, title: $0, isEditable: false) }, edges: []
        ))
        var sidecar = SchemaSidecar(
            clusters: [.init(id: "commerce", label: "Commerce", tables: names)],
            stories: [.init(id: "checkout", title: "Old checkout", createdAt: "2026-09-05",
                            playback: [.init(text: "Old narration", tables: [names[0]], focus: "missing")])]
        )
        try SchemaSidecarStore.save(sidecar, for: url)
        let target: DatabaseTarget = isPostgres
            ? .postgres(.init(host: "localhost", database: "catalog", username: "reader", tlsMode: .disabled))
            : .sqlite(url)
        let session = AppSession(userDefaults: defaults)
        session.apply(snapshot: snapshot, target: target, documentURL: url)
        session.showStoryCardsInGraph = true
        session.selectGraphNode(names[0])
        session.graphLayout.pin(nodeID: names[0], at: CGPoint(x: 120, y: -60))
        let view = SchemaGraphView(session: session)
        let beforeKey = view.storyGraphCardsCacheToken()
        let beforeLayout = session.graphLayout.snapshot(for: session.graph)
        let beforeGrouping = session.graphGrouping
        #expect(!session.metadataDiagnostics.isEmpty)

        sidecar.stories[0].title = "Corrected checkout"
        sidecar.stories[0].playback = [.init(text: "Corrected narration", tables: [names[0]], focus: names[1])]
        try SchemaSidecarStore.save(sidecar, for: url)
        session.reloadSchemaSidecarFromDisk()

        #expect(session.metadataDiagnostics.isEmpty)
        #expect(session.schemaSidecar == sidecar)
        #expect(session.graphGrouping == beforeGrouping)
        #expect(session.stories.count == 1)
        #expect(view.storyGraphCardsCacheToken() != beforeKey)
        #expect(session.graphLayout.snapshot(for: session.graph) == beforeLayout)
        #expect(session.selectedGraphNodeID == names[0])
    }
}
