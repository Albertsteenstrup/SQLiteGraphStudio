import Foundation
import Testing
@testable import StudioMCP

struct MCPResourceBundleTests {
    @Test(arguments: ["SQLGraphStudio", "SQLiteGraphStudio", "StudioMCP"])
    func installedResourcesAreFoundForTheAppAndHelper(executableName: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = directory.appendingPathComponent("Graph Studio.app/Contents")
        let resources = contents.appendingPathComponent("Resources")
        let bundleURL = resources.appendingPathComponent("SQLiteGraphStudio_StudioMCP.bundle")
        let payload = bundleURL.appendingPathComponent("Resources/Probe.txt")
        try FileManager.default.createDirectory(at: payload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("packaged resource".utf8).write(to: payload)
        let executable = contents.appendingPathComponent("MacOS/" + executableName)
        let mainResources = executableName == "StudioMCP" ? executable.deletingLastPathComponent() : resources
        let bundle = try #require(MCPResourceBundle.packagedBundle(executableURL: executable, resourceURL: mainResources))
        let url = try #require(bundle.url(forResource: "Probe", withExtension: "txt", subdirectory: "Resources"))
        #expect(try String(contentsOf: url, encoding: .utf8) == "packaged resource")
        #expect(bundle.bundleURL.resolvingSymlinksInPath() == bundleURL.resolvingSymlinksInPath())
    }

    @Test func unpackagedExecutablesLeaveResourceResolutionToSwiftPM() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(MCPResourceBundle.packagedBundle(executableURL: missing.appendingPathComponent("StudioMCP"), resourceURL: missing) == nil)
        #expect(MCPResourceBundle.packagedBundle(executableURL: nil, resourceURL: nil) == nil)
    }
}
