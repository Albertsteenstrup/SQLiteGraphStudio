import Foundation
import StudioCore

@main
struct FixtureBuilderMain {
    static func main() throws {
        let arguments = CommandLine.arguments.dropFirst()
        let outputURL: URL

        if let providedPath = arguments.first {
            outputURL = URL(fileURLWithPath: providedPath, isDirectory: false)
        } else {
            outputURL = URL(fileURLWithPath: "Fixtures/sample.sqlite", isDirectory: false)
        }

        try SampleFixtureBuilder.buildFixture(at: outputURL)
        print("Wrote fixture to \(outputURL.path)")
    }
}
