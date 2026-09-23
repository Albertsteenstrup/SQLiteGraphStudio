import CryptoKit
import Foundation
import XCTest
@testable import StudioMCP

final class MCPSetupInstallerTests: XCTestCase {
    func testClientCommandsPreserveExecutableArgumentAndSupportProjectScope() {
        let path = "/Applications/SQLiteGraphStudio.app/Contents/MacOS/StudioMCP"
        XCTAssertEqual(MCPSetupInstaller.addArguments(for: .codex, executablePath: path), [
            "mcp", "add", "sqlite-graph-studio", "--", path,
        ])
        XCTAssertEqual(MCPSetupInstaller.addArguments(for: .claude, executablePath: path), [
            "mcp", "add", "--scope", "user", "--transport", "stdio", "sqlite-graph-studio", "--", path,
        ])
        XCTAssertEqual(MCPSetupInstaller.addArguments(for: .claude, executablePath: path, scope: .project), [
            "mcp", "add", "--scope", "project", "--transport", "stdio", "sqlite-graph-studio", "--", path,
        ])
        XCTAssertTrue(MCPSetupInstaller.addArguments(for: .codex, executablePath: path, scope: .project).isEmpty)
    }

    func testAddsMissingServerAndDoesNotOverwriteExistingName() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioMCPSetupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex", isDirectory: false)
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        XCTAssertEqual(chmod(executable.path, 0o755), 0)

        let runner = FakeCommandRunner(responses: [
            MCPSetupCommandResult(status: 1, stderr: "not configured"),
            MCPSetupCommandResult(status: 0, stdout: "added"),
            MCPSetupCommandResult(status: 0, stdout: "{\"command\":\"/path/StudioMCP\",\"args\":[]}"),
            MCPSetupCommandResult(status: 0, stdout: "{\"command\":\"/other/server\",\"args\":[]}"),
        ])
        let outcomes = MCPSetupInstaller.install(
            clients: [.codex, .codex],
            executablePath: "/path/StudioMCP",
            searchPath: directory.path,
            runner: runner
        )

        XCTAssertEqual(outcomes.map(\.state), [.installed, .conflict])
        XCTAssertEqual(runner.invocations.count, 4)
        XCTAssertEqual(runner.invocations[1].arguments, [
            "mcp", "add", "sqlite-graph-studio", "--", "/path/StudioMCP",
        ])
    }

    func testReportsMissingClientWithoutAttemptingConfiguration() {
        let runner = FakeCommandRunner(responses: [])
        let outcomes = MCPSetupInstaller.install(
            clients: [.claude],
            executablePath: "/path/StudioMCP",
            searchPath: "/definitely/missing",
            runner: runner
        )
        XCTAssertEqual(outcomes.first?.state, .unavailable)
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testFindsClientInCommonUserInstallLocationOutsidePath() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let codex = bin.appendingPathComponent("codex")
        XCTAssertTrue(FileManager.default.createFile(atPath: codex.path, contents: Data()))
        XCTAssertEqual(chmod(codex.path, 0o755), 0)

        let runner = FakeCommandRunner(responses: [
            MCPSetupCommandResult(status: 1, stderr: "not configured"),
            MCPSetupCommandResult(status: 0, stdout: "added"),
            MCPSetupCommandResult(status: 0, stdout: "{\"command\":\"/path/StudioMCP\",\"args\":[]}"),
        ])
        let outcomes = MCPSetupInstaller.install(
            clients: [.codex],
            executablePath: "/path/StudioMCP",
            searchPath: "",
            homeDirectory: home,
            runner: runner
        )

        XCTAssertEqual(outcomes.first?.state, .installed)
        XCTAssertEqual(runner.invocations.first?.executable, codex.path)
    }

    func testInstallsCanonicalSkillsAndPreservesCustomizedCopies() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        let initial = MCPSetupInstaller.installUserSkills(in: home)
        XCTAssertTrue(initial.succeeded, initial.summary)
        XCTAssertEqual(initial.installed.count, 10)

        let customizedPath = home.appendingPathComponent(".agents/skills/database-explore/SKILL.md")
        try Data("user-edited skill\n".utf8).write(to: customizedPath)
        let retiredDirectory = home.appendingPathComponent(".agents/skills/story-flows", isDirectory: true)
        try FileManager.default.createDirectory(at: retiredDirectory, withIntermediateDirectories: true)
        let retiredPath = retiredDirectory.appendingPathComponent("SKILL.md")
        try Data("user-edited retired skill\n".utf8).write(to: retiredPath)

        let second = MCPSetupInstaller.installUserSkills(in: home)
        XCTAssertTrue(second.succeeded, second.summary)
        XCTAssertEqual(second.customizedPreserved, ["~/.agents/skills/database-explore/SKILL.md"])
        XCTAssertTrue(second.retiredCustomizedPreserved.contains("~/.agents/skills/story-flows/SKILL.md"))
        XCTAssertEqual(try Data(contentsOf: customizedPath), Data("user-edited skill\n".utf8))
        XCTAssertEqual(try Data(contentsOf: retiredPath), Data("user-edited retired skill\n".utf8))
        XCTAssertTrue(second.alreadyCurrent.contains("~/.claude/skills/database-explore/SKILL.md"))
    }

    func testUpdatesKnownManagedFilesAndRemovesOnlyKnownRetiredFiles() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        let oldBytes = Data("old generated skill\n".utf8)
        let oldHash = digest(oldBytes)
        let catalog = MCPManagedSkillCatalog(
            version: 1,
            skills: [MCPManagedSkillDocument(id: "example", content: "new canonical skill\n", managedSHA256: [oldHash])],
            retiredSkills: [MCPRetiredSkillDocument(id: "story-flows", managedSHA256: [oldHash])]
        )
        for root in [".agents/skills", ".claude/skills"] {
            let skillDirectory = home.appendingPathComponent("\(root)/example", isDirectory: true)
            let retiredDirectory = home.appendingPathComponent("\(root)/story-flows", isDirectory: true)
            try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: retiredDirectory, withIntermediateDirectories: true)
            try oldBytes.write(to: skillDirectory.appendingPathComponent("SKILL.md"))
            try oldBytes.write(to: retiredDirectory.appendingPathComponent("SKILL.md"))
            try Data("keep unrelated file\n".utf8).write(to: retiredDirectory.appendingPathComponent("notes.txt"))
        }

        let result = MCPSetupInstaller.installUserSkills(catalog: catalog, homeDirectory: home)
        XCTAssertTrue(result.succeeded, result.summary)
        XCTAssertEqual(result.updated.count, 2)
        XCTAssertEqual(result.retiredRemoved.count, 2)
        for root in [".agents/skills", ".claude/skills"] {
            let updated = home.appendingPathComponent("\(root)/example/SKILL.md")
            let retired = home.appendingPathComponent("\(root)/story-flows/SKILL.md")
            let preservedNote = home.appendingPathComponent("\(root)/story-flows/notes.txt")
            XCTAssertEqual(try Data(contentsOf: updated), Data("new canonical skill\n".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: retired.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: preservedNote.path))
        }
    }

    func testSetupInstallsSelectedClientSkillsAndReportsHelperOutcome() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let codex = bin.appendingPathComponent("codex")
        XCTAssertTrue(FileManager.default.createFile(atPath: codex.path, contents: Data()))
        XCTAssertEqual(chmod(codex.path, 0o755), 0)

        let runner = FakeCommandRunner(responses: [
            MCPSetupCommandResult(status: 1, stderr: "not configured"),
            MCPSetupCommandResult(status: 0, stdout: "added"),
            MCPSetupCommandResult(status: 0, stdout: "{\"command\":\"/path/StudioMCP\",\"args\":[]}"),
        ])
        let report = MCPSetupInstaller.setup(
            clients: [.codex],
            executablePath: "/path/StudioMCP",
            homeDirectory: home,
            searchPath: bin.path,
            runner: runner,
            helperDiagnoser: FakeHelperDiagnoser(result: MCPSetupVerification(
                succeeded: true,
                discoveredToolCount: 61,
                statusSummary: "MCP handshake, 61-tool discovery, and studio_status succeeded. Graph Studio is closed."
            ))
        )

        XCTAssertEqual(report.clients.map(\.state), [.installed])
        XCTAssertEqual(report.skills.installed.count, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/skills").path))
        XCTAssertFalse(report.hasFailures)
        XCTAssertEqual(report.outputLines.last, "skills: installed 5")
        XCTAssertTrue(report.clients[0].verification?.succeeded == true)
    }

    func testDoesNotWriteThroughUserSkillDirectorySymlinks() throws {
        let home = try temporaryDirectory()
        let external = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: external)
        }

        let agentsDirectory = home.appendingPathComponent(".agents", isDirectory: true)
        let externalSkills = external.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalSkills, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: agentsDirectory.appendingPathComponent("skills", isDirectory: true),
            withDestinationURL: externalSkills
        )

        let result = MCPSetupInstaller.installUserSkills(in: home)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.errors.contains { $0.contains(".agents/skills") })
        XCTAssertEqual(result.installed.count, 5)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: externalSkills.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/skills/database-explore/SKILL.md").path))
    }

    func testAppBundlePreviewIsReadOnlyAndReportsClaudeSymlinkBlocker() throws {
        let home = try temporaryDirectory()
        let external = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: external)
        }

        let appBundleURL = home.appendingPathComponent("SQLiteGraphStudio.app", isDirectory: true)
        let macOSDirectory = appBundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSDirectory, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.SQLiteGraphStudioTests",
            "CFBundleExecutable": "SQLiteGraphStudio",
            "CFBundlePackageType": "APPL",
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: appBundleURL.appendingPathComponent("Contents/Info.plist"))
        let helper = macOSDirectory.appendingPathComponent("StudioMCP")
        XCTAssertTrue(FileManager.default.createFile(atPath: helper.path, contents: Data()))
        XCTAssertEqual(chmod(helper.path, 0o755), 0)
        let appBundle = try XCTUnwrap(Bundle(url: appBundleURL))

        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["codex", "claude"] {
            let cli = bin.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.createFile(atPath: cli.path, contents: Data()))
            XCTAssertEqual(chmod(cli.path, 0o755), 0)
        }

        let externalSkills = external.appendingPathComponent("skills", isDirectory: true)
        let externalSkill = externalSkills.appendingPathComponent("database-explore", isDirectory: true)
        try FileManager.default.createDirectory(at: externalSkill, withIntermediateDirectories: true)
        let externalSkillFile = externalSkill.appendingPathComponent("SKILL.md")
        try Data("outside content stays untouched\n".utf8).write(to: externalSkillFile)
        let claudeDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: claudeDirectory.appendingPathComponent("skills", isDirectory: true),
            withDestinationURL: externalSkills
        )

        let runner = FakeCommandRunner(responses: [
            MCPSetupCommandResult(status: 0, stdout: "codex 0.1"),
            MCPSetupCommandResult(status: 0, stdout: "{\"command\":\"\(helper.path)\",\"args\":[]}"),
            MCPSetupCommandResult(status: 1, stderr: "not configured"),
            MCPSetupCommandResult(status: 0, stdout: "claude 1.2"),
        ])
        let preview = MCPSetupInstaller.previewFromAppBundle(
            appBundle: appBundle,
            homeDirectory: home,
            searchPath: bin.path,
            runner: runner
        )

        XCTAssertEqual(preview.helperPath, helper.path)
        XCTAssertEqual(preview.clients.map(\.state), [.alreadyRegistered, .willRegister])
        XCTAssertEqual(preview.clients[0].cliVersion, "codex 0.1")
        XCTAssertEqual(preview.clients[1].cliVersion, "claude 1.2")
        XCTAssertTrue(preview.canInstall)
        XCTAssertEqual(preview.skills.first(where: { $0.client == .codex })?.install.count, 5)
        let claudeSkills = try XCTUnwrap(preview.skills.first(where: { $0.client == .claude }))
        XCTAssertEqual(claudeSkills.state, .blocked)
        XCTAssertTrue(claudeSkills.blockers.contains { $0.contains(".claude/skills") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".agents/skills").path))
        XCTAssertEqual(try Data(contentsOf: externalSkillFile), Data("outside content stays untouched\n".utf8))
        XCTAssertEqual(runner.invocations.map(\.arguments), [
            ["--version"],
            ["mcp", "get", MCPSetupInstaller.serverName, "--json"],
            ["--version"],
            ["mcp", "get", MCPSetupInstaller.serverName],
        ])
    }

    func testProjectCodexSetupAppendsManagedMCPTableAndInstallsOnlyProjectSkills() throws {
        let project = try temporaryDirectory()
        let home = try temporaryDirectory()
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let codex = bin.appendingPathComponent("codex")
        XCTAssertTrue(FileManager.default.createFile(atPath: codex.path, contents: Data()))
        XCTAssertEqual(chmod(codex.path, 0o755), 0)
        defer {
            try? FileManager.default.removeItem(at: project)
            try? FileManager.default.removeItem(at: home)
        }

        let codexDirectory = project.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let config = codexDirectory.appendingPathComponent("config.toml")
        let original = "model = \"gpt-6-luna\"\n\n[mcp_servers.other-tool]\ncommand = \"other\"\nargs = []\n"
        try Data(original.utf8).write(to: config)
        let helperPath = "/Applications/SQLiteGraphStudio.app/Contents/MacOS/StudioMCP"
        let runner = FakeCommandRunner(responses: [])
        let diagnostician = FakeHelperDiagnoser(result: MCPSetupVerification(
            succeeded: true,
            discoveredToolCount: 61,
            statusSummary: "MCP handshake, 61-tool discovery, and studio_status succeeded. Graph Studio is closed.",
            appRunning: false,
            bridgeConnected: false
        ))

        let report = MCPSetupInstaller.setup(
            clients: [.codex],
            executablePath: helperPath,
            scope: .project,
            projectDirectory: project,
            homeDirectory: home,
            searchPath: bin.path,
            runner: runner,
            helperDiagnoser: diagnostician
        )

        XCTAssertEqual(report.scope, .project)
        XCTAssertEqual(report.projectDirectoryPath, project.standardizedFileURL.path)
        XCTAssertEqual(report.clients.first?.state, .installed)
        XCTAssertEqual(report.clients.first?.verification?.discoveredToolCount, 61)
        XCTAssertFalse(report.hasFailures)
        let updated = try String(contentsOf: config, encoding: .utf8)
        XCTAssertEqual(String(updated.prefix(original.count)), original)
        XCTAssertTrue(updated.contains("[mcp_servers.\"sqlite-graph-studio\"]"))
        XCTAssertTrue(updated.contains("command = \"\(helperPath)\""))
        XCTAssertTrue(updated.contains("args = []"))
        XCTAssertEqual(report.skills.installed.count, 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.appendingPathComponent(".agents/skills/database-explore/SKILL.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".agents/skills/database-explore/SKILL.md").path))
        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertEqual(diagnostician.calls.first?.workingDirectory, project.standardizedFileURL)
    }

    func testProjectCodexNameConflictIsPreservedAndReported() throws {
        let project = try temporaryDirectory()
        let home = try temporaryDirectory()
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let codex = bin.appendingPathComponent("codex")
        XCTAssertTrue(FileManager.default.createFile(atPath: codex.path, contents: Data()))
        XCTAssertEqual(chmod(codex.path, 0o755), 0)
        defer {
            try? FileManager.default.removeItem(at: project)
            try? FileManager.default.removeItem(at: home)
        }

        let codexDirectory = project.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let config = codexDirectory.appendingPathComponent("config.toml")
        let original = "[mcp_servers.\"sqlite-graph-studio\"]\ncommand = \"/different/helper\"\nargs = []\n"
        try Data(original.utf8).write(to: config)
        let report = MCPSetupInstaller.setup(
            clients: [.codex],
            executablePath: "/Applications/SQLiteGraphStudio.app/Contents/MacOS/StudioMCP",
            scope: .project,
            projectDirectory: project,
            homeDirectory: home,
            searchPath: bin.path,
            runner: FakeCommandRunner(responses: [])
        )

        XCTAssertEqual(report.clients.first?.state, .conflict)
        XCTAssertTrue(report.hasFailures)
        XCTAssertEqual(try Data(contentsOf: config), Data(original.utf8))
    }

    func testProjectPreviewShowsVersionWithoutCreatingProjectFiles() throws {
        let project = try temporaryDirectory()
        let home = try temporaryDirectory()
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let codex = bin.appendingPathComponent("codex")
        XCTAssertTrue(FileManager.default.createFile(atPath: codex.path, contents: Data()))
        XCTAssertEqual(chmod(codex.path, 0o755), 0)
        defer {
            try? FileManager.default.removeItem(at: project)
            try? FileManager.default.removeItem(at: home)
        }
        let runner = FakeCommandRunner(responses: [MCPSetupCommandResult(status: 0, stdout: "codex-cli 0.155.0")])

        let preview = MCPSetupInstaller.preview(
            clients: [.codex],
            executablePath: "/Applications/SQLiteGraphStudio.app/Contents/MacOS/StudioMCP",
            scope: .project,
            projectDirectory: project,
            homeDirectory: home,
            searchPath: bin.path,
            runner: runner
        )

        XCTAssertEqual(preview.scope, .project)
        XCTAssertEqual(preview.projectDirectoryPath, project.standardizedFileURL.path)
        XCTAssertEqual(preview.clients.first?.state, .willRegister)
        XCTAssertEqual(preview.clients.first?.cliVersion, "codex-cli 0.155.0")
        XCTAssertEqual(runner.invocations.map(\.arguments), [["--version"]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent(".codex").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent(".agents").path))
    }

    func testProjectPreviewBlocksSymlinkedCodexConfigDirectory() throws {
        let project = try temporaryDirectory()
        let external = try temporaryDirectory()
        let home = try temporaryDirectory()
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let codex = bin.appendingPathComponent("codex")
        XCTAssertTrue(FileManager.default.createFile(atPath: codex.path, contents: Data()))
        XCTAssertEqual(chmod(codex.path, 0o755), 0)
        defer {
            try? FileManager.default.removeItem(at: project)
            try? FileManager.default.removeItem(at: external)
            try? FileManager.default.removeItem(at: home)
        }
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent(".codex", isDirectory: true),
            withDestinationURL: external
        )
        let runner = FakeCommandRunner(responses: [MCPSetupCommandResult(status: 0, stdout: "codex-cli 0.155.0")])

        let preview = MCPSetupInstaller.preview(
            clients: [.codex],
            executablePath: "/Applications/SQLiteGraphStudio.app/Contents/MacOS/StudioMCP",
            scope: .project,
            projectDirectory: project,
            homeDirectory: home,
            searchPath: bin.path,
            runner: runner
        )

        XCTAssertEqual(preview.clients.first?.state, .unsafeDestination)
        XCTAssertTrue(preview.clients.first?.message.contains("symbolic link") == true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
    }

    func testProjectClaudeSetupUsesProjectScopeAndVerifiesMergedProjectFile() throws {
        let project = try temporaryDirectory()
        let home = try temporaryDirectory()
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let claude = bin.appendingPathComponent("claude")
        XCTAssertTrue(FileManager.default.createFile(atPath: claude.path, contents: Data()))
        XCTAssertEqual(chmod(claude.path, 0o755), 0)
        defer {
            try? FileManager.default.removeItem(at: project)
            try? FileManager.default.removeItem(at: home)
        }
        let helperPath = "/Applications/SQLiteGraphStudio.app/Contents/MacOS/StudioMCP"
        let unrelated = ["review": ["command": "review-tool", "args": ["--check"]]]
        let runner = FakeCommandRunner(responses: [MCPSetupCommandResult(status: 0, stdout: "added")]) { invocation in
            guard invocation.arguments.starts(with: ["mcp", "add"]), let directory = invocation.currentDirectory else { return }
            let root: [String: Any] = [
                "mcpServers": unrelated.merging([
                    MCPSetupInstaller.serverName: ["command": helperPath, "args": [String]()],
                ]) { _, new in new },
                "teamSetting": "keep",
            ]
            let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            try data.write(to: directory.appendingPathComponent(".mcp.json"))
        }
        let diagnostician = FakeHelperDiagnoser(result: MCPSetupVerification(
            succeeded: true,
            discoveredToolCount: 61,
            statusSummary: "MCP handshake, 61-tool discovery, and studio_status succeeded. Graph Studio is running."
        ))

        let report = MCPSetupInstaller.setup(
            clients: [.claude],
            executablePath: helperPath,
            scope: .project,
            projectDirectory: project,
            homeDirectory: home,
            searchPath: bin.path,
            runner: runner,
            helperDiagnoser: diagnostician
        )

        XCTAssertEqual(report.clients.first?.state, .installed)
        XCTAssertTrue(report.clients.first?.verification?.succeeded == true)
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(runner.invocations.first?.arguments, [
            "mcp", "add", "--scope", "project", "--transport", "stdio", MCPSetupInstaller.serverName, "--", helperPath,
        ])
        XCTAssertEqual(runner.invocations.first?.currentDirectory, project.standardizedFileURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(from: Data(contentsOf: project.appendingPathComponent(".mcp.json"))) as? [String: Any])
        XCTAssertEqual(root["teamSetting"] as? String, "keep")
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(servers["review"]?["command"] as? String, "review-tool")
        XCTAssertEqual(servers[MCPSetupInstaller.serverName]?["command"] as? String, helperPath)
        XCTAssertEqual(report.skills.installed.count, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/skills/database-explore/SKILL.md").path))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioMCPSetupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class FakeCommandRunner: MCPSetupCommandRunning {
    struct Invocation {
        let executable: String
        let arguments: [String]
        let currentDirectory: URL?
    }

    private(set) var invocations: [Invocation] = []
    private var responses: [MCPSetupCommandResult]
    private let onInvocation: ((Invocation) throws -> Void)?

    init(responses: [MCPSetupCommandResult], onInvocation: ((Invocation) throws -> Void)? = nil) {
        self.responses = responses
        self.onInvocation = onInvocation
    }

    func run(executable: String, arguments: [String]) -> MCPSetupCommandResult {
        run(executable: executable, arguments: arguments, currentDirectory: nil, environment: nil)
    }

    func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?
    ) -> MCPSetupCommandResult {
        let invocation = Invocation(executable: executable, arguments: arguments, currentDirectory: currentDirectory)
        invocations.append(invocation)
        try? onInvocation?(invocation)
        guard !responses.isEmpty else { return MCPSetupCommandResult(status: 0) }
        return responses.removeFirst()
    }
}

private final class FakeHelperDiagnoser: MCPSetupHelperDiagnosing {
    struct Call {
        let helperPath: String
        let workingDirectory: URL?
    }

    let result: MCPSetupVerification
    private(set) var calls: [Call] = []

    init(result: MCPSetupVerification) {
        self.result = result
    }

    func diagnose(helperPath: String, workingDirectory: URL?) -> MCPSetupVerification {
        calls.append(Call(helperPath: helperPath, workingDirectory: workingDirectory))
        return result
    }
}
