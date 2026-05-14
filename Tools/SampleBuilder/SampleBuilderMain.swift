import Foundation
import StudioCore

@main
struct SampleBuilderMain {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let outputURL: URL
        let type: String

        if arguments.count >= 1 {
            outputURL = URL(fileURLWithPath: arguments[0], isDirectory: false)
        } else {
            outputURL = URL(fileURLWithPath: "Samples/small_sample.sqlite", isDirectory: false)
        }

        if arguments.count >= 2 {
            type = arguments[1]
        } else {
            type = "default"
        }

        if type == "big" {
            try BigSampleFixtureBuilder.buildFixture(at: outputURL)
        } else {
            try SampleFixtureBuilder.buildFixture(at: outputURL)
        }
        
        print("Wrote fixture to \(outputURL.path)")
    }
}
