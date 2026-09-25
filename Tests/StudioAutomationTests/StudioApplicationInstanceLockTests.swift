import Foundation
import Testing
@testable import SQLiteGraphStudio

@Suite(.serialized)
struct StudioApplicationInstanceLockTests {
    @Test
    func onlyOneProcessCanOwnTheUserWideApplicationLock() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sgs-instance-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var first: StudioApplicationInstanceLock? = try StudioApplicationInstanceLock.acquire(directory: directory)
        #expect(first != nil)
        #expect(try StudioApplicationInstanceLock.acquire(directory: directory) == nil)
        first = nil
        #expect(try StudioApplicationInstanceLock.acquire(directory: directory) != nil)
    }
}
