import Foundation
import GRDB
import Testing
@testable import StudioCore

struct RecordSQLiteCancellationTests {
    @Test func cancellingHeavyRecordReadReleasesBackendForNextRead() async throws {
        let url = TestSupport.temporaryDatabaseURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE quick(key INTEGER PRIMARY KEY);
                INSERT INTO quick VALUES(7);
                CREATE VIEW heavy AS WITH RECURSIVE numbers(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM numbers WHERE n<100000000) SELECT sum(n) AS total FROM numbers;
                """)
        }
        let service = DatabaseService()
        try await service.open(url: url)
        let heavyColumn = TableColumn(name: "total", declaredType: "INTEGER", notNull: false, defaultValueSQL: nil, primaryKeyOrdinal: 0, hiddenValue: 0)
        let heavy = TableDescriptor(name: "heavy", objectType: .view, columns: [heavyColumn], primaryKeyColumns: [], rowIdentityStrategy: .readOnly, isWithoutRowID: false, isEditable: false)
        let quickColumn = TableColumn(name: "key", declaredType: "INTEGER", notNull: true, defaultValueSQL: nil, primaryKeyOrdinal: 1, hiddenValue: 0)
        let quick = TableDescriptor(name: "quick", objectType: .table, columns: [quickColumn], primaryKeyColumns: ["key"], rowIdentityStrategy: .primaryKey, isWithoutRowID: false, isEditable: true)
        let slow = Task { try await service.fetchRecords(descriptor: heavy, predicates: []) }
        try await Task.sleep(for: .milliseconds(100))
        let cancelledAt = ContinuousClock.now
        slow.cancel()
        let next = try await service.fetchRecords(descriptor: quick, predicates: [])
        #expect(next.records.first?.values == [.integer(7)])
        #expect(cancelledAt.duration(to: .now) < .seconds(2))
        await #expect(throws: (any Error).self) { try await slow.value }
        await service.close()
    }
}
