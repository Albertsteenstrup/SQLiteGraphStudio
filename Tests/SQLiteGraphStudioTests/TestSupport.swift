import Foundation
@testable import StudioCore

enum TestSupport {
    static func temporaryDatabaseURL(named name: String = UUID().uuidString) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteGraphStudioTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("\(name).sqlite", isDirectory: false)
    }

    static func createFixture(named name: String = UUID().uuidString) throws -> URL {
        let url = temporaryDatabaseURL(named: name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try SampleFixtureBuilder.buildFixture(at: url)
        return url
    }
}
