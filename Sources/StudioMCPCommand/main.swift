import Foundation
import Darwin
import StudioMCP

@main
enum StudioMCPCommand {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "setup" {
            runSetup(Array(arguments.dropFirst()))
            return
        }

        if arguments == ["--version"] || arguments == ["-v"] {
            print("SQLite Graph Studio MCP \(MCPServer.serverVersion)")
            return
        }

        let server = MCPServer(dispatcher: LocalMCPToolDispatcher())
        do {
            try MCPStdioRunner(server: server).run()
        } catch {
            writeStandardError("SQLite Graph Studio MCP stopped: \(error.localizedDescription)\n")
            exit(EXIT_FAILURE)
        }
    }

    private static func runSetup(_ rawArguments: [String]) {
        let clients: [MCPSetupClient]
        if rawArguments.isEmpty || rawArguments == ["all"] {
            clients = MCPSetupClient.allCases
        } else if rawArguments == ["--help"] || rawArguments == ["-h"] {
            print("Usage: StudioMCP setup [all|codex|claude]")
            return
        } else if rawArguments.count == 1, let client = MCPSetupClient(rawValue: rawArguments[0]) {
            clients = [client]
        } else {
            writeStandardError("Usage: StudioMCP setup [all|codex|claude]\n")
            exit(EXIT_FAILURE)
        }

        let executablePath = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let report = MCPSetupInstaller.setup(clients: clients, executablePath: executablePath)
        report.outputLines.forEach { print($0) }
        if report.hasFailures {
            exit(EXIT_FAILURE)
        }
    }

    private static func writeStandardError(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        try? FileHandle.standardError.write(contentsOf: data)
    }
}
