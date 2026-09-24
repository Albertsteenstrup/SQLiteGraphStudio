import Foundation
import Testing
@testable import StudioCore

private final class SchemaSidecarRaceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var successes = 0
    private var conflicts = 0
    private var failures = 0

    func recordSuccess() {
        lock.lock()
        successes += 1
        lock.unlock()
    }

    func recordConflict() {
        lock.lock()
        conflicts += 1
        lock.unlock()
    }

    func recordFailure() {
        lock.lock()
        failures += 1
        lock.unlock()
    }

    var counts: (successes: Int, conflicts: Int, failures: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (successes, conflicts, failures)
    }
}

struct SchemaSidecarRevisionTests {
    @Test func durableNotesPreserveUnknownFieldsAndRejectStaleWrites() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("model.sqlite")
        let sidecarURL = SchemaSidecarStore.sidecarURL(for: database)
        let initial: [String: Any] = [
            "version": 1,
            "futureRoot": ["keep": true],
            "overviewTables": ["orders", "customers"],
            "tables": ["orders": ["description": "Orders", "futureTable": "keep"]],
            "notes": [["id": "n1", "text": "First note", "tableID": "orders", "futureNote": "keep"]],
        ]
        try JSONSerialization.data(withJSONObject: initial).write(to: sidecarURL)

        let before = try SchemaSidecarStore.loadSnapshot(for: database)
        #expect(before.sidecar.notes.map(\.id) == ["n1"])
        #expect(before.sidecar.overviewTables == ["orders", "customers"])
        var updated = before.sidecar
        updated.notes.append(.init(id: "n2", text: "Payment happens after validation.", tableID: "orders"))
        let currentRevision = try SchemaSidecarStore.save(updated, for: database,
                                                          expectedRevision: before.revision)
        #expect(currentRevision != before.revision)
        #expect(throws: SchemaMetadataError.self) {
            try SchemaSidecarStore.save(before.sidecar, for: database,
                                        expectedRevision: before.revision)
        }

        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: sidecarURL)) as! [String: Any]
        #expect((saved["futureRoot"] as? [String: Bool])?["keep"] == true)
        #expect(saved["overviewTables"] as? [String] == ["orders", "customers"])
        #expect((saved["tables"] as? [String: [String: Any]])?["orders"]?["futureTable"] as? String == "keep")
        let notes = saved["notes"] as! [[String: Any]]
        #expect(notes.count == 2)
        #expect(notes.first?["futureNote"] as? String == "keep")
        #expect(try SchemaSidecarStore.loadSnapshot(for: database).revision == currentRevision)
    }

    @Test func overviewTableHintsAreBoundedAndDistinct() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("model.sqlite")

        #expect(throws: SchemaMetadataError.self) {
            try SchemaSidecarStore.save(.init(overviewTables: ["orders", "orders"]), for: database)
        }
        #expect(throws: SchemaMetadataError.self) {
            try SchemaSidecarStore.save(.init(overviewTables: (0..<17).map { "table\($0)" }), for: database)
        }
        #expect(!FileManager.default.fileExists(atPath: SchemaSidecarStore.sidecarURL(for: database).path))
    }

    @Test func absentSidecarRevisionConflictsAfterAnotherWriterCreatesIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("model.sqlite")
        let absent = try SchemaSidecarStore.loadSnapshot(for: database)
        #expect(!FileManager.default.fileExists(
            atPath: SchemaSidecarStore.sidecarURL(for: database).appendingPathExtension("lock").path
        ))
        try SchemaSidecarStore.save(.init(notes: [.init(id: "n1", text: "Written first")]),
                                    for: database, expectedRevision: absent.revision)
        #expect(throws: SchemaMetadataError.self) {
            try SchemaSidecarStore.save(.init(notes: [.init(id: "n2", text: "Stale")]),
                                        for: database, expectedRevision: absent.revision)
        }
        #expect(try SchemaSidecarStore.load(for: database).notes.map(\.id) == ["n1"])
    }

    @Test func sameProcessExpectedRevisionWritersHaveExactlyOneWinner() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("model.sqlite")
        let revision = try SchemaSidecarStore.loadSnapshot(for: database).revision
        let count = 24
        let recorder = SchemaSidecarRaceRecorder()
        let ready = DispatchSemaphore(value: 0)
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()

        for index in 0..<count {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                ready.signal()
                start.wait()
                defer { group.leave() }
                let sidecar = SchemaSidecar(notes: [
                    .init(id: "writer-\(index)", text: "Writer \(index)")
                ])
                do {
                    try SchemaSidecarStore.save(sidecar, for: database, expectedRevision: revision)
                    recorder.recordSuccess()
                } catch let error as SchemaMetadataError {
                    if case .conflict = error {
                        recorder.recordConflict()
                    } else {
                        recorder.recordFailure()
                    }
                } catch {
                    recorder.recordFailure()
                }
            }
        }
        for _ in 0..<count { ready.wait() }
        for _ in 0..<count { start.signal() }
        group.wait()

        let counts = recorder.counts
        #expect(counts.successes == 1)
        #expect(counts.conflicts == count - 1)
        #expect(counts.failures == 0)
        #expect(try SchemaSidecarStore.load(for: database).notes.count == 1)
    }

    @Test func legacyMigrationRacingSavePreservesTheWinningSave() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("model.sqlite")
        let sidecarURL = SchemaSidecarStore.sidecarURL(for: database)
        // A large ignored legacy payload gives the competing save a useful
        // window to run between the loader's initial read and migration lock.
        let stories = Array(repeating: String(repeating: "legacy-story-", count: 2_048), count: 128)
        let legacy = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "stories": stories,
            "tables": ["orders": ["description": "Before save"]],
        ])
        try legacy.write(to: sidecarURL)

        let recorder = SchemaSidecarRaceRecorder()
        let ready = DispatchSemaphore(value: 0)
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            ready.signal()
            start.wait()
            defer { group.leave() }
            do {
                _ = try SchemaSidecarStore.loadSnapshot(for: database)
                recorder.recordSuccess()
            } catch {
                recorder.recordFailure()
            }
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            ready.signal()
            start.wait()
            defer { group.leave() }
            do {
                try SchemaSidecarStore.save(
                    SchemaSidecar(
                        tables: ["orders": .init(description: "Written during migration")],
                        notes: [.init(id: "concurrent", text: "Preserve this save", tableID: "orders")]
                    ),
                    for: database
                )
                recorder.recordSuccess()
            } catch {
                recorder.recordFailure()
            }
        }
        ready.wait()
        ready.wait()
        start.signal()
        start.signal()
        group.wait()

        #expect(recorder.counts.successes == 2)
        #expect(recorder.counts.failures == 0)
        let final = try SchemaSidecarStore.load(for: database)
        #expect(final.notes.map(\.id) == ["concurrent"])
        #expect(final.tables["orders"]?.description == "Written during migration")
        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: sidecarURL)) as? [String: Any]
        #expect(persisted?["stories"] == nil)
    }
}
