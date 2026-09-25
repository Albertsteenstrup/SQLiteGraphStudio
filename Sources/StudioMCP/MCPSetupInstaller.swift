import CryptoKit
import Foundation

public enum MCPSetupClient: String, CaseIterable, Equatable, Sendable {
    case codex
    case claude

    fileprivate var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        }
    }

    fileprivate var skillRoot: String {
        switch self {
        case .codex: ".agents/skills"
        case .claude: ".claude/skills"
        }
    }
}

public enum MCPSetupScope: String, CaseIterable, Equatable, Sendable {
    case user
    case project

    public var displayName: String {
        switch self {
        case .user: "User-wide"
        case .project: "This project"
        }
    }
}

public struct MCPSetupOutcome: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case installed
        case alreadyInstalled
        case conflict
        case unavailable
        case failed
    }

    public let client: MCPSetupClient
    public let state: State
    public let message: String
    public let verification: MCPSetupVerification?

    public init(
        client: MCPSetupClient,
        state: State,
        message: String,
        verification: MCPSetupVerification? = nil
    ) {
        self.client = client
        self.state = state
        self.message = message
        self.verification = verification
    }
}

public struct MCPSetupVerification: Equatable, Sendable {
    public let succeeded: Bool
    public let discoveredToolCount: Int
    public let statusSummary: String
    public let appRunning: Bool?
    public let bridgeConnected: Bool?

    public init(
        succeeded: Bool,
        discoveredToolCount: Int,
        statusSummary: String,
        appRunning: Bool? = nil,
        bridgeConnected: Bool? = nil
    ) {
        self.succeeded = succeeded
        self.discoveredToolCount = discoveredToolCount
        self.statusSummary = statusSummary
        self.appRunning = appRunning
        self.bridgeConnected = bridgeConnected
    }
}

public struct MCPManagedSkillsOutcome: Equatable, Sendable {
    public let installed: [String]
    public let updated: [String]
    public let alreadyCurrent: [String]
    public let customizedPreserved: [String]
    public let retiredRemoved: [String]
    public let retiredCustomizedPreserved: [String]
    public let errors: [String]

    public var summary: String {
        var parts: [String] = []
        if !installed.isEmpty { parts.append("installed \(installed.count)") }
        if !updated.isEmpty { parts.append("updated \(updated.count)") }
        if !alreadyCurrent.isEmpty { parts.append("current \(alreadyCurrent.count)") }
        if !customizedPreserved.isEmpty { parts.append("preserved \(customizedPreserved.count) customized") }
        if !retiredRemoved.isEmpty { parts.append("removed \(retiredRemoved.count) managed retired") }
        if !retiredCustomizedPreserved.isEmpty { parts.append("preserved \(retiredCustomizedPreserved.count) customized retired") }
        if !errors.isEmpty { parts.append("\(errors.count) error(s): \(errors.joined(separator: "; "))") }
        return parts.isEmpty ? "no skill files needed attention" : parts.joined(separator: "; ")
    }

    public var succeeded: Bool { errors.isEmpty }

    fileprivate init(
        installed: [String] = [], updated: [String] = [], alreadyCurrent: [String] = [],
        customizedPreserved: [String] = [], retiredRemoved: [String] = [],
        retiredCustomizedPreserved: [String] = [], errors: [String] = []
    ) {
        self.installed = installed
        self.updated = updated
        self.alreadyCurrent = alreadyCurrent
        self.customizedPreserved = customizedPreserved
        self.retiredRemoved = retiredRemoved
        self.retiredCustomizedPreserved = retiredCustomizedPreserved
        self.errors = errors
    }
}

public struct MCPSetupReport: Equatable, Sendable {
    public let clients: [MCPSetupOutcome]
    public let skills: MCPManagedSkillsOutcome
    public let scope: MCPSetupScope
    public let projectDirectoryPath: String?

    public var hasFailures: Bool {
        !skills.succeeded || clients.contains {
            [.conflict, .unavailable, .failed].contains($0.state) || $0.verification?.succeeded == false
        }
    }

    public var outputLines: [String] {
        clients.flatMap { outcome -> [String] in
            var lines = ["\(outcome.client.rawValue): \(outcome.message)"]
            if let verification = outcome.verification {
                lines.append("\(outcome.client.rawValue) MCP diagnostic: \(verification.statusSummary)")
            }
            return lines
        } + ["skills: \(skills.summary)"]
    }

    public init(
        clients: [MCPSetupOutcome],
        skills: MCPManagedSkillsOutcome,
        scope: MCPSetupScope = .user,
        projectDirectoryPath: String? = nil
    ) {
        self.clients = clients
        self.skills = skills
        self.scope = scope
        self.projectDirectoryPath = projectDirectoryPath
    }
}

public struct MCPSetupClientPlan: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case willRegister
        case alreadyRegistered
        case nameConflict
        case cliUnavailable
        case helperUnavailable
        case projectDirectoryRequired
        case unsafeDestination
    }

    public let client: MCPSetupClient
    public let state: State
    public let cliPath: String?
    public let cliVersion: String?
    public let message: String

    public init(
        client: MCPSetupClient,
        state: State,
        cliPath: String?,
        cliVersion: String? = nil,
        message: String
    ) {
        self.client = client
        self.state = state
        self.cliPath = cliPath
        self.cliVersion = cliVersion
        self.message = message
    }
}

public struct MCPSetupSkillsPlan: Equatable, Sendable {
    public enum State: String, Equatable, Sendable { case ready, blocked }

    public let client: MCPSetupClient
    public let rootPath: String
    public let state: State
    public let install: [String]
    public let update: [String]
    public let alreadyCurrent: [String]
    public let customizedPreserved: [String]
    public let retiredManaged: [String]
    public let retiredCustomizedPreserved: [String]
    public let blockers: [String]

    public var hasChanges: Bool { !install.isEmpty || !update.isEmpty || !retiredManaged.isEmpty }

    public var summary: String {
        if state == .blocked {
            return "\(rootPath): blocked; no files below this path will be inspected or changed."
        }
        var items: [String] = []
        if !install.isEmpty { items.append("install \(install.count)") }
        if !update.isEmpty { items.append("update \(update.count)") }
        if !alreadyCurrent.isEmpty { items.append("already current \(alreadyCurrent.count)") }
        if !customizedPreserved.isEmpty { items.append("preserve customized \(customizedPreserved.count)") }
        if !retiredManaged.isEmpty { items.append("remove managed retired \(retiredManaged.count)") }
        if !retiredCustomizedPreserved.isEmpty { items.append("preserve retired customized \(retiredCustomizedPreserved.count)") }
        let overview = items.isEmpty ? "already current" : items.joined(separator: "; ")
        return blockers.isEmpty ? "\(rootPath): \(overview)." : "\(rootPath): \(overview); \(blockers.joined(separator: "; "))."
    }
}

public struct MCPSetupPreview: Equatable, Sendable {
    public let helperPath: String?
    public let scope: MCPSetupScope
    public let projectDirectoryPath: String?
    public let clients: [MCPSetupClientPlan]
    public let skills: [MCPSetupSkillsPlan]

    public init(
        helperPath: String?,
        scope: MCPSetupScope = .user,
        projectDirectoryPath: String? = nil,
        clients: [MCPSetupClientPlan],
        skills: [MCPSetupSkillsPlan]
    ) {
        self.helperPath = helperPath
        self.scope = scope
        self.projectDirectoryPath = projectDirectoryPath
        self.clients = clients
        self.skills = skills
    }

    public var canInstall: Bool {
        clients.contains { $0.state == .willRegister } || skills.contains(where: \.hasChanges)
    }

    public var hasBlockers: Bool {
        helperPath == nil || clients.contains {
            [.nameConflict, .cliUnavailable, .helperUnavailable, .projectDirectoryRequired, .unsafeDestination].contains($0.state)
        }
            || skills.contains { $0.state == .blocked || !$0.blockers.isEmpty }
    }
}

public struct MCPSetupCommandResult {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String = "", stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol MCPSetupHelperDiagnosing {
    func diagnose(helperPath: String, workingDirectory: URL?) -> MCPSetupVerification
}

/// Starts the exact bundled helper and performs the read-only MCP handshake,
/// tool discovery, and `studio_status` call. `studio_status` never launches the app.
public struct SystemMCPSetupHelperDiagnoser: MCPSetupHelperDiagnosing {
    public init() {}

    public func diagnose(helperPath: String, workingDirectory: URL?) -> MCPSetupVerification {
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            return MCPSetupVerification(
                succeeded: false,
                discoveredToolCount: 0,
                statusSummary: "The configured helper is not executable at the reviewed path."
            )
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helperPath)
        process.currentDirectoryURL = workingDirectory
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let requests: [[String: Any]] = [
                [
                    "jsonrpc": "2.0", "id": 1, "method": "initialize",
                    "params": [
                        "protocolVersion": "2025-11-25",
                        "capabilities": [:],
                        "clientInfo": ["name": "SQLite Graph Studio setup check", "version": "1"],
                    ],
                ],
                ["jsonrpc": "2.0", "method": "notifications/initialized"],
                ["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]],
                [
                    "jsonrpc": "2.0", "id": 3, "method": "tools/call",
                    "params": ["name": "studio_status", "arguments": [:]],
                ],
            ]
            var payload = Data()
            for request in requests {
                payload.append(try JSONSerialization.data(withJSONObject: request))
                payload.append(0x0A)
            }
            try input.fileHandleForWriting.write(contentsOf: payload)
            try input.fileHandleForWriting.close()
            let responseData = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return MCPSetupVerification(
                    succeeded: false,
                    discoveredToolCount: 0,
                    statusSummary: "The helper exited with status \(process.terminationStatus) during the MCP check."
                )
            }
            let responses = responseData.split(separator: 0x0A).compactMap { line -> [String: Any]? in
                (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
            }
            guard let listing = responses.first(where: { ($0["id"] as? Int) == 2 })?["result"] as? [String: Any],
                  let tools = listing["tools"] as? [[String: Any]],
                  tools.contains(where: { $0["name"] as? String == "studio_status" }),
                  let statusResponse = responses.first(where: { ($0["id"] as? Int) == 3 })?["result"] as? [String: Any],
                  statusResponse["isError"] as? Bool != true else {
                return MCPSetupVerification(
                    succeeded: false,
                    discoveredToolCount: 0,
                    statusSummary: "The helper did not complete MCP tool discovery and the read-only studio_status call."
                )
            }
            let content = statusResponse["content"] as? [[String: Any]] ?? []
            let statusSummary = content.first?["text"] as? String ?? "studio_status returned without a text summary."
            let structured = statusResponse["structuredContent"] as? [String: Any] ?? [:]
            return MCPSetupVerification(
                succeeded: true,
                discoveredToolCount: tools.count,
                statusSummary: "MCP handshake, \(tools.count)-tool discovery, and studio_status succeeded. \(statusSummary)",
                appRunning: structured["appRunning"] as? Bool,
                bridgeConnected: structured["bridgeConnected"] as? Bool
            )
        } catch {
            if process.isRunning { process.terminate() }
            return MCPSetupVerification(
                succeeded: false,
                discoveredToolCount: 0,
                statusSummary: "The helper could not complete its read-only MCP check: \(error.localizedDescription)"
            )
        }
    }
}

public protocol MCPSetupCommandRunning {
    func run(executable: String, arguments: [String]) -> MCPSetupCommandResult
    func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?
    ) -> MCPSetupCommandResult
}

public extension MCPSetupCommandRunning {
    func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?
    ) -> MCPSetupCommandResult {
        run(executable: executable, arguments: arguments)
    }
}

public struct SystemMCPSetupCommandRunner: MCPSetupCommandRunning {
    public init() {}

    public func run(executable: String, arguments: [String]) -> MCPSetupCommandResult {
        run(executable: executable, arguments: arguments, currentDirectory: nil, environment: nil)
    }

    public func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?
    ) -> MCPSetupCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return MCPSetupCommandResult(
                status: process.terminationStatus,
                stdout: String(data: outputData, encoding: .utf8) ?? ""
            )
        } catch {
            return MCPSetupCommandResult(status: -1, stderr: error.localizedDescription)
        }
    }
}

struct MCPManagedSkillDocument: Decodable, Equatable, Sendable {
    let id: String
    let content: String
    let managedSHA256: [String]

    enum CodingKeys: String, CodingKey {
        case id, content
        case managedSHA256 = "managed_sha256"
    }
}

struct MCPRetiredSkillDocument: Decodable, Equatable, Sendable {
    let id: String
    let managedSHA256: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case managedSHA256 = "managed_sha256"
    }
}

struct MCPManagedSkillCatalog: Decodable, Equatable, Sendable {
    let version: Int
    let skills: [MCPManagedSkillDocument]
    let retiredSkills: [MCPRetiredSkillDocument]

    enum CodingKeys: String, CodingKey {
        case version, skills
        case retiredSkills = "retired_skills"
    }

    static func bundled() throws -> Self {
        guard let url = Bundle.module.url(
            forResource: "CanonicalSkills",
            withExtension: "json",
            subdirectory: "Resources"
        ) else {
            throw MCPManagedSkillCatalogError.missingResource
        }
        let catalog = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard catalog.version == 1,
              !catalog.skills.isEmpty,
              Set(catalog.skills.map(\.id)).count == catalog.skills.count,
              catalog.skills.allSatisfy({ isSafeSkillID($0.id) && !$0.content.isEmpty }),
              catalog.retiredSkills.allSatisfy({ isSafeSkillID($0.id) }) else {
            throw MCPManagedSkillCatalogError.invalidResource
        }
        return catalog
    }

    private static func isSafeSkillID(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 97 && scalar.value <= 122) ||
            (scalar.value >= 48 && scalar.value <= 57) || scalar == "-"
        }
    }
}

private enum MCPManagedSkillCatalogError: LocalizedError {
    case missingResource
    case invalidResource

    var errorDescription: String? {
        switch self {
        case .missingResource: "The bundled canonical MCP skills are missing."
        case .invalidResource: "The bundled canonical MCP skills are invalid."
        }
    }
}

private enum MCPSetupError: LocalizedError {
    case unsafePath(String)
    case projectConfigConflict(String)

    var errorDescription: String? {
        switch self {
        case .unsafePath(let path): "Refusing to write through a symbolic link or non-directory path: \(path)"
        case .projectConfigConflict(let path): "The project already defines \(MCPSetupInstaller.serverName) in \(path); it was left unchanged."
        }
    }
}

private enum CodexProjectEntryState {
    case missing
    case matching
    case conflict
    case unsafe(String)
}

/// Installs the local stdio bridge with the clients' own MCP CLIs and maintains
/// the canonical skills in their user-wide skill directories. Config files are
/// never rewritten directly. Existing customized skill files are kept intact.
public enum MCPSetupInstaller {
    public static let serverName = "sqlite-graph-studio"

    private static let maximumProjectConfigBytes: UInt64 = 1_000_000

    /// Registers the server only. `setup` also installs the bundled canonical skills.
    public static func install(
        clients: [MCPSetupClient],
        executablePath: String,
        scope: MCPSetupScope = .user,
        projectDirectory: URL? = nil,
        searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        runner: MCPSetupCommandRunning = SystemMCPSetupCommandRunner(),
        helperDiagnoser: MCPSetupHelperDiagnosing? = nil
    ) -> [MCPSetupOutcome] {
        clients.map { client in
            install(
                client: client,
                executablePath: executablePath,
                scope: scope,
                projectDirectory: projectDirectory,
                searchPath: searchPath,
                homeDirectory: homeDirectory,
                runner: runner,
                helperDiagnoser: helperDiagnoser
            )
        }
    }

    /// Full agent-led setup: update known-managed skill versions, preserve edited
    /// skill files, remove only recognized retired skill copies, and register the
    /// helper with each selected client.
    public static func setup(
        clients: [MCPSetupClient],
        executablePath: String?,
        scope: MCPSetupScope = .user,
        projectDirectory: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        runner: MCPSetupCommandRunning = SystemMCPSetupCommandRunner(),
        helperDiagnoser: MCPSetupHelperDiagnosing = SystemMCPSetupHelperDiagnoser()
    ) -> MCPSetupReport {
        let skills: MCPManagedSkillsOutcome
        do {
            skills = installSkills(
                catalog: try MCPManagedSkillCatalog.bundled(),
                homeDirectory: homeDirectory,
                clients: clients,
                scope: scope,
                projectDirectory: projectDirectory,
                fileManager: .default
            )
        } catch {
            skills = MCPManagedSkillsOutcome(errors: [error.localizedDescription])
        }

        let clientOutcomes: [MCPSetupOutcome]
        if let executablePath, !executablePath.isEmpty {
            clientOutcomes = install(
                clients: clients,
                executablePath: executablePath,
                scope: scope,
                projectDirectory: projectDirectory,
                searchPath: searchPath,
                homeDirectory: homeDirectory,
                runner: runner,
                helperDiagnoser: helperDiagnoser
            )
        } else {
            clientOutcomes = clients.map {
                MCPSetupOutcome(
                    client: $0,
                    state: .unavailable,
                    message: "The bundled StudioMCP helper was not found at Contents/MacOS/StudioMCP; no MCP entry was changed."
                )
            }
        }
        return MCPSetupReport(
            clients: clientOutcomes,
            skills: skills,
            scope: scope,
            projectDirectoryPath: scope == .project ? projectDirectory?.standardizedFileURL.path : nil
        )
    }

    /// App-led setup entry point. Both local packaging scripts place the helper
    /// at `Contents/MacOS/StudioMCP`; a missing helper is reported without
    /// registering a broken client command.
    public static func installFromAppBundle(
        clients: [MCPSetupClient] = MCPSetupClient.allCases,
        scope: MCPSetupScope = .user,
        projectDirectory: URL? = nil,
        appBundle: Bundle = .main,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        runner: MCPSetupCommandRunning = SystemMCPSetupCommandRunner(),
        helperDiagnoser: MCPSetupHelperDiagnosing = SystemMCPSetupHelperDiagnoser()
    ) -> MCPSetupReport {
        let helper = appBundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("StudioMCP", isDirectory: false)
        let path = FileManager.default.isExecutableFile(atPath: helper.path) ? helper.path : nil
        return setup(
            clients: clients,
            executablePath: path,
            scope: scope,
            projectDirectory: projectDirectory,
            homeDirectory: homeDirectory,
            searchPath: searchPath,
            runner: runner,
            helperDiagnoser: helperDiagnoser
        )
    }

    /// Read-only setup review for the app's bundled helper. This only locates
    /// client executables, asks each available CLI for its existing entry, and
    /// inspects skill paths without creating directories or following symlinks.
    public static func previewFromAppBundle(
        clients: [MCPSetupClient] = MCPSetupClient.allCases,
        scope: MCPSetupScope = .user,
        projectDirectory: URL? = nil,
        appBundle: Bundle = .main,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        runner: MCPSetupCommandRunning = SystemMCPSetupCommandRunner(),
        fileManager: FileManager = .default
    ) -> MCPSetupPreview {
        let helper = appBundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("StudioMCP", isDirectory: false)
        let helperPath = fileManager.isExecutableFile(atPath: helper.path) ? helper.path : nil
        return preview(
            clients: clients,
            executablePath: helperPath,
            scope: scope,
            projectDirectory: projectDirectory,
            homeDirectory: homeDirectory,
            searchPath: searchPath,
            runner: runner,
            fileManager: fileManager
        )
    }

    /// Read-only setup review with an explicit helper path, useful to embedders
    /// and isolated tests. A nonzero `mcp get` result is treated as an entry to
    /// register after confirmation; it never invokes `mcp add` during preview.
    public static func preview(
        clients: [MCPSetupClient],
        executablePath: String?,
        scope: MCPSetupScope = .user,
        projectDirectory: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        runner: MCPSetupCommandRunning = SystemMCPSetupCommandRunner(),
        fileManager: FileManager = .default
    ) -> MCPSetupPreview {
        let helperPath = executablePath.flatMap { $0.isEmpty ? nil : $0 }
        let projectIssue = scope == .project
            ? projectDirectoryIssue(projectDirectory, fileManager: fileManager)
            : nil
        let clientPlans = clients.map { client -> MCPSetupClientPlan in
            guard let helperPath else {
                return MCPSetupClientPlan(
                    client: client, state: .helperUnavailable, cliPath: nil,
                    message: "The bundled StudioMCP helper is missing, so no client entry can be registered."
                )
            }
            if scope == .project, let projectIssue {
                return MCPSetupClientPlan(
                    client: client,
                    state: projectDirectory == nil ? .projectDirectoryRequired : .unsafeDestination,
                    cliPath: nil,
                    message: projectIssue
                )
            }
            guard let cliPath = findExecutable(
                named: client.rawValue, searchPath: searchPath, homeDirectory: homeDirectory
            ) else {
                return MCPSetupClientPlan(
                    client: client, state: .cliUnavailable, cliPath: nil,
                    message: "\(client.displayName) CLI was not found; its MCP configuration will be left unchanged."
                )
            }

            let versionResult = runner.run(executable: cliPath, arguments: ["--version"])
            let cliVersion = versionResult.status == 0 ? cliVersionLabel(versionResult.stdout, for: client) : nil

            if scope == .project, let projectDirectory {
                let destinationIssue = projectMCPDestinationIssue(
                    for: client,
                    projectDirectory: projectDirectory,
                    fileManager: fileManager
                )
                if let destinationIssue {
                    return MCPSetupClientPlan(
                        client: client,
                        state: .unsafeDestination,
                        cliPath: cliPath,
                        cliVersion: cliVersion,
                        message: destinationIssue
                    )
                }
                if client == .codex {
                    let config = projectDirectory.appendingPathComponent(".codex/config.toml")
                    switch inspectCodexProjectEntry(configURL: config, helperPath: helperPath) {
                    case .missing:
                        return MCPSetupClientPlan(
                            client: client,
                            state: .willRegister,
                            cliPath: cliPath,
                            cliVersion: cliVersion,
                            message: "Will add this helper to the trusted project config at .codex/config.toml. Existing settings will be kept."
                        )
                    case .matching:
                        return MCPSetupClientPlan(
                            client: client,
                            state: .alreadyRegistered,
                            cliPath: cliPath,
                            cliVersion: cliVersion,
                            message: "The project Codex config already points to this bundled helper."
                        )
                    case .conflict:
                        return MCPSetupClientPlan(
                            client: client,
                            state: .nameConflict,
                            cliPath: cliPath,
                            cliVersion: cliVersion,
                            message: "The project Codex config already defines \(serverName); it will be left unchanged."
                        )
                    case .unsafe(let detail):
                        return MCPSetupClientPlan(
                            client: client,
                            state: .unsafeDestination,
                            cliPath: cliPath,
                            cliVersion: cliVersion,
                            message: detail
                        )
                    }
                }
                switch inspectClaudeProjectEntry(projectDirectory: projectDirectory, helperPath: helperPath, fileManager: fileManager) {
                case .missing:
                    return MCPSetupClientPlan(
                        client: client,
                        state: .willRegister,
                        cliPath: cliPath,
                        cliVersion: cliVersion,
                        message: "Will ask Claude Code to merge this helper into the project's .mcp.json. Existing entries will be kept."
                    )
                case .matching:
                    return MCPSetupClientPlan(
                        client: client,
                        state: .alreadyRegistered,
                        cliPath: cliPath,
                        cliVersion: cliVersion,
                        message: "The project .mcp.json already points to this bundled helper."
                    )
                case .conflict:
                    return MCPSetupClientPlan(
                        client: client,
                        state: .nameConflict,
                        cliPath: cliPath,
                        cliVersion: cliVersion,
                        message: "The project .mcp.json already defines \(serverName); it will be left unchanged."
                    )
                case .unsafe(let message):
                    return MCPSetupClientPlan(
                        client: client,
                        state: .unsafeDestination,
                        cliPath: cliPath,
                        cliVersion: cliVersion,
                        message: message
                    )
                }
            }

            let arguments = client == .codex
                ? ["mcp", "get", serverName, "--json"]
                : ["mcp", "get", serverName]
            let current = runner.run(
                executable: cliPath,
                arguments: arguments,
                currentDirectory: scope == .project ? projectDirectory : nil,
                environment: nil
            )
            guard current.status == 0 else {
                return MCPSetupClientPlan(
                    client: client, state: .willRegister, cliPath: cliPath,
                    cliVersion: cliVersion,
                    message: "\(client.displayName) did not confirm an existing \(serverName) entry (CLI status \(current.status)). The installer will attempt registration after you approve."
                )
            }

            let matches: Bool
            if client == .codex {
                matches = codexEntry(current.stdout, matches: helperPath)
            } else if let userEntry = claudeUserEntry(homeDirectory: homeDirectory) {
                matches = commandEntry(userEntry, matches: helperPath)
            } else {
                matches = false
            }
            return MCPSetupClientPlan(
                client: client,
                state: matches ? .alreadyRegistered : .nameConflict,
                cliPath: cliPath,
                cliVersion: cliVersion,
                message: matches
                    ? "\(client.displayName) already has the bundled helper registered."
                    : "\(client.displayName) already has an entry named \(serverName); it will be left unchanged."
            )
        }

        let skillPlans: [MCPSetupSkillsPlan]
        do {
            let catalog = try MCPManagedSkillCatalog.bundled()
            skillPlans = MCPSetupClient.allCases.filter(clients.contains).map { client in
                previewSkills(
                    for: client,
                    catalog: catalog,
                    scope: scope,
                    homeDirectory: homeDirectory,
                    projectDirectory: projectDirectory,
                    fileManager: fileManager
                )
            }
        } catch {
            skillPlans = MCPSetupClient.allCases.filter(clients.contains).map { client in
                MCPSetupSkillsPlan(
                    client: client,
                    rootPath: "~/\(client.skillRoot)",
                    state: .blocked,
                    install: [], update: [], alreadyCurrent: [], customizedPreserved: [],
                    retiredManaged: [], retiredCustomizedPreserved: [],
                    blockers: ["Bundled skills could not be read: \(error.localizedDescription)"]
                )
            }
        }
        return MCPSetupPreview(
            helperPath: helperPath,
            scope: scope,
            projectDirectoryPath: scope == .project ? projectDirectory?.standardizedFileURL.path : nil,
            clients: clientPlans,
            skills: skillPlans
        )
    }

    public static func addArguments(for client: MCPSetupClient, executablePath: String) -> [String] {
        addArguments(for: client, executablePath: executablePath, scope: .user)
    }

    public static func addArguments(
        for client: MCPSetupClient,
        executablePath: String,
        scope: MCPSetupScope
    ) -> [String] {
        switch client {
        case .codex:
            // Codex has no MCP scope flag. Project-scoped MCP entries are
            // written to the trusted project's .codex/config.toml.
            if scope == .project { return [] }
            return ["mcp", "add", serverName, "--", executablePath]
        case .claude:
            return ["mcp", "add", "--scope", scope == .project ? "project" : "user", "--transport", "stdio", serverName, "--", executablePath]
        }
    }

    static func installUserSkills(in homeDirectory: URL) -> MCPManagedSkillsOutcome {
        do {
            return installUserSkills(
                catalog: try MCPManagedSkillCatalog.bundled(),
                homeDirectory: homeDirectory,
                clients: MCPSetupClient.allCases
            )
        } catch {
            return MCPManagedSkillsOutcome(errors: [error.localizedDescription])
        }
    }

    static func installUserSkills(
        catalog: MCPManagedSkillCatalog,
        homeDirectory: URL,
        clients: [MCPSetupClient] = MCPSetupClient.allCases,
        fileManager: FileManager = .default
    ) -> MCPManagedSkillsOutcome {
        installSkills(
            catalog: catalog,
            homeDirectory: homeDirectory,
            clients: clients,
            scope: .user,
            projectDirectory: nil,
            fileManager: fileManager
        )
    }

    private static func installSkills(
        catalog: MCPManagedSkillCatalog,
        homeDirectory: URL,
        clients: [MCPSetupClient],
        scope: MCPSetupScope,
        projectDirectory: URL?,
        fileManager: FileManager
    ) -> MCPManagedSkillsOutcome {
        var installed: [String] = []
        var updated: [String] = []
        var alreadyCurrent: [String] = []
        var customizedPreserved: [String] = []
        var retiredRemoved: [String] = []
        var retiredCustomizedPreserved: [String] = []
        var errors: [String] = []

        if scope == .project, let issue = projectDirectoryIssue(projectDirectory, fileManager: fileManager) {
            return MCPManagedSkillsOutcome(errors: [issue])
        }
        let targets: [(anchor: URL, root: URL, labelRoot: String)]
        if scope == .project, let projectDirectory {
            let projectRoot = projectDirectory.standardizedFileURL
            targets = MCPSetupClient.allCases.filter(clients.contains).map { client in
                let relativeRoot = client == .codex ? ".agents/skills" : ".claude/skills"
                return (
                    anchor: projectRoot,
                    root: projectRoot.appendingPathComponent(relativeRoot, isDirectory: true),
                    labelRoot: relativeRoot
                )
            }
        } else {
            targets = MCPSetupClient.allCases.filter(clients.contains).map { client in
                let relativeRoot = client == .codex ? ".agents/skills" : ".claude/skills"
                return (
                    anchor: homeDirectory,
                    root: homeDirectory.appendingPathComponent(relativeRoot, isDirectory: true),
                    labelRoot: "~/\(relativeRoot)"
                )
            }
        }
        for target in targets {
            let anchor = target.anchor
            let root = target.root
            let labelRoot = target.labelRoot
            do {
                try ensureDirectory(root, under: anchor, fileManager: fileManager)
            } catch {
                errors.append("\(labelRoot): \(error.localizedDescription)")
                continue
            }

            for skill in catalog.skills {
                let skillDirectory = root.appendingPathComponent(skill.id, isDirectory: true)
                let destination = skillDirectory.appendingPathComponent("SKILL.md", isDirectory: false)
                let label = "\(labelRoot)/\(skill.id)/SKILL.md"
                do {
                    try ensureDirectory(skillDirectory, under: anchor, fileManager: fileManager)
                    if isSymbolicLink(destination, fileManager: fileManager) {
                        customizedPreserved.append(label)
                        continue
                    }
                    if let attributes = try? fileManager.attributesOfItem(atPath: destination.path) {
                        guard attributes[.type] as? FileAttributeType == .typeRegular,
                              let existing = try? Data(contentsOf: destination) else {
                            customizedPreserved.append(label)
                            continue
                        }
                        let canonical = Data(skill.content.utf8)
                        if existing == canonical {
                            alreadyCurrent.append(label)
                        } else if isKnownManaged(existing, hashes: skill.managedSHA256) {
                            try canonical.write(to: destination, options: .atomic)
                            updated.append(label)
                        } else {
                            customizedPreserved.append(label)
                        }
                    } else {
                        try Data(skill.content.utf8).write(to: destination, options: .atomic)
                        installed.append(label)
                    }
                } catch {
                    errors.append("\(label): \(error.localizedDescription)")
                }
            }

            for retired in catalog.retiredSkills {
                let skillDirectory = root.appendingPathComponent(retired.id, isDirectory: true)
                let destination = skillDirectory.appendingPathComponent("SKILL.md", isDirectory: false)
                let label = "\(labelRoot)/\(retired.id)/SKILL.md"
                if isSymbolicLink(destination, fileManager: fileManager) {
                    retiredCustomizedPreserved.append(label)
                    continue
                }
                guard let attributes = try? fileManager.attributesOfItem(atPath: destination.path) else { continue }
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let existing = try? Data(contentsOf: destination),
                      isKnownManaged(existing, hashes: retired.managedSHA256) else {
                    retiredCustomizedPreserved.append(label)
                    continue
                }
                do {
                    try fileManager.removeItem(at: destination)
                    retiredRemoved.append(label)
                    if let contents = try? fileManager.contentsOfDirectory(atPath: skillDirectory.path), contents.isEmpty {
                        try fileManager.removeItem(at: skillDirectory)
                    }
                } catch {
                    errors.append("\(label): \(error.localizedDescription)")
                }
            }
        }

        return MCPManagedSkillsOutcome(
            installed: installed,
            updated: updated,
            alreadyCurrent: alreadyCurrent,
            customizedPreserved: customizedPreserved,
            retiredRemoved: retiredRemoved,
            retiredCustomizedPreserved: retiredCustomizedPreserved,
            errors: errors
        )
    }

    private static func install(
        client: MCPSetupClient,
        executablePath: String,
        scope: MCPSetupScope,
        projectDirectory: URL?,
        searchPath: String,
        homeDirectory: URL,
        runner: MCPSetupCommandRunning,
        helperDiagnoser: MCPSetupHelperDiagnosing?
    ) -> MCPSetupOutcome {
        if scope == .project, let issue = projectDirectoryIssue(projectDirectory, fileManager: .default) {
            return MCPSetupOutcome(client: client, state: .unavailable, message: issue)
        }
        guard let clientExecutable = findExecutable(
            named: client.rawValue,
            searchPath: searchPath,
            homeDirectory: homeDirectory
        ) else {
            return MCPSetupOutcome(
                client: client,
                state: .unavailable,
                message: "\(client.rawValue) CLI was not found on PATH or common install locations; no MCP configuration was changed."
            )
        }

        if scope == .project, let projectDirectory,
           client == .codex {
            let config = projectDirectory.appendingPathComponent(".codex/config.toml")
            switch inspectCodexProjectEntry(configURL: config, helperPath: executablePath) {
            case .matching:
                return verifiedOutcome(
                    client: client,
                    state: .alreadyInstalled,
                    baseMessage: "The project Codex config already points to this bundled helper.",
                    helperPath: executablePath,
                    projectDirectory: projectDirectory,
                    helperDiagnoser: helperDiagnoser
                )
            case .conflict:
                return MCPSetupOutcome(
                    client: client,
                    state: .conflict,
                    message: "The project Codex config already defines \(serverName); it was left unchanged."
                )
            case .unsafe(let message):
                return MCPSetupOutcome(client: client, state: .failed, message: message)
            case .missing:
                do {
                    try appendCodexProjectEntry(
                        configURL: config,
                        projectDirectory: projectDirectory,
                        executablePath: executablePath
                    )
                    guard case .matching = inspectCodexProjectEntry(configURL: config, helperPath: executablePath) else {
                        return MCPSetupOutcome(
                            client: client,
                            state: .failed,
                            message: "The project Codex config was written, but read-back did not confirm the expected helper entry."
                        )
                    }
                    return verifiedOutcome(
                        client: client,
                        state: .installed,
                        baseMessage: "Added the helper to the project Codex config. Codex loads project config only after the project is trusted.",
                        helperPath: executablePath,
                        projectDirectory: projectDirectory,
                        helperDiagnoser: helperDiagnoser
                    )
                } catch {
                    return MCPSetupOutcome(client: client, state: .failed, message: error.localizedDescription)
                }
            }
        }

        if scope == .project, let projectDirectory, client == .claude {
            switch inspectClaudeProjectEntry(projectDirectory: projectDirectory, helperPath: executablePath) {
            case .matching:
                return verifiedOutcome(
                    client: client,
                    state: .alreadyInstalled,
                    baseMessage: "The project .mcp.json already points to this bundled helper.",
                    helperPath: executablePath,
                    projectDirectory: projectDirectory,
                    helperDiagnoser: helperDiagnoser
                )
            case .conflict:
                return MCPSetupOutcome(
                    client: client,
                    state: .conflict,
                    message: "The project .mcp.json already defines \(serverName); it was left unchanged."
                )
            case .unsafe(let message):
                return MCPSetupOutcome(client: client, state: .failed, message: message)
            case .missing:
                break
            }
            let added = runner.run(
                executable: clientExecutable,
                arguments: addArguments(for: .claude, executablePath: executablePath, scope: .project),
                currentDirectory: projectDirectory,
                environment: nil
            )
            guard added.status == 0 else {
                return MCPSetupOutcome(
                    client: client,
                    state: .failed,
                    message: "Could not register SQLite Graph Studio in this Claude Code project: \(brief(added.stderr.isEmpty ? added.stdout : added.stderr))."
                )
            }
            guard case .matching = inspectClaudeProjectEntry(projectDirectory: projectDirectory, helperPath: executablePath) else {
                return MCPSetupOutcome(
                    client: client,
                    state: .failed,
                    message: "Claude Code accepted the project registration command, but read-back did not confirm the expected helper in .mcp.json."
                )
            }
            return verifiedOutcome(
                client: client,
                state: .installed,
                baseMessage: "Registered SQLite Graph Studio in this Claude Code project. Reload the project to pick up the connection.",
                helperPath: executablePath,
                projectDirectory: projectDirectory,
                helperDiagnoser: helperDiagnoser
            )
        }

        let getArguments = client == .codex
            ? ["mcp", "get", serverName, "--json"]
            : ["mcp", "get", serverName]
        let current = runner.run(
            executable: clientExecutable,
            arguments: getArguments,
            currentDirectory: scope == .project ? projectDirectory : nil,
            environment: nil
        )
        if current.status == 0 {
            let matching: Bool
            if client == .codex {
                matching = codexEntry(current.stdout, matches: executablePath)
            } else if scope == .project, let projectDirectory {
                matching = claudeProjectEntry(projectDirectory: projectDirectory, matches: executablePath)
            } else if let userEntry = claudeUserEntry(homeDirectory: homeDirectory) {
                matching = commandEntry(userEntry, matches: executablePath)
            } else {
                matching = false
            }
            return matching
                ? verifiedOutcome(
                    client: client,
                    state: .alreadyInstalled,
                    baseMessage: "\(client.rawValue) already has the SQLite Graph Studio helper configured.",
                    helperPath: executablePath,
                    projectDirectory: scope == .project ? projectDirectory : nil,
                    helperDiagnoser: helperDiagnoser
                )
                : MCPSetupOutcome(
                    client: client,
                    state: .conflict,
                    message: "\(client.rawValue) already has a server named \(serverName); it was left unchanged."
                )
        }

        let addArguments = addArguments(for: client, executablePath: executablePath, scope: scope)
        guard !addArguments.isEmpty else {
            return MCPSetupOutcome(client: client, state: .failed, message: "This client cannot register a project entry through its CLI.")
        }
        let added = runner.run(
            executable: clientExecutable,
            arguments: addArguments,
            currentDirectory: scope == .project ? projectDirectory : nil,
            environment: nil
        )
        guard added.status == 0 else {
            return MCPSetupOutcome(
                client: client,
                state: .failed,
                message: "Could not register SQLite Graph Studio with \(client.rawValue): \(brief(added.stderr.isEmpty ? added.stdout : added.stderr))."
            )
        }
        let readBack = runner.run(
            executable: clientExecutable,
            arguments: getArguments,
            currentDirectory: scope == .project ? projectDirectory : nil,
            environment: nil
        )
        let matching: Bool
        if readBack.status != 0 {
            matching = false
        } else if client == .codex {
            matching = codexEntry(readBack.stdout, matches: executablePath)
        } else if scope == .project, let projectDirectory {
            matching = claudeProjectEntry(projectDirectory: projectDirectory, matches: executablePath)
        } else if let userEntry = claudeUserEntry(homeDirectory: homeDirectory) {
            matching = commandEntry(userEntry, matches: executablePath)
        } else {
            matching = false
        }
        guard matching else {
            return MCPSetupOutcome(
                client: client,
                state: .failed,
                message: "\(client.rawValue) accepted the registration command, but read-back did not confirm the configured helper."
            )
        }
        return verifiedOutcome(
            client: client,
            state: .installed,
            baseMessage: "Registered SQLite Graph Studio at \(scope == .project ? "project" : "user") scope with \(client.rawValue). Reload that client to pick up the connection.",
            helperPath: executablePath,
            projectDirectory: scope == .project ? projectDirectory : nil,
            helperDiagnoser: helperDiagnoser
        )
    }

    private static func verifiedOutcome(
        client: MCPSetupClient,
        state: MCPSetupOutcome.State,
        baseMessage: String,
        helperPath: String,
        projectDirectory: URL?,
        helperDiagnoser: MCPSetupHelperDiagnosing?
    ) -> MCPSetupOutcome {
        guard let helperDiagnoser else {
            return MCPSetupOutcome(client: client, state: state, message: baseMessage)
        }
        let verification = helperDiagnoser.diagnose(
            helperPath: helperPath,
            workingDirectory: projectDirectory
        )
        let message: String
        if verification.succeeded {
            message = "\(baseMessage) \(verification.statusSummary)"
        } else {
            message = "\(baseMessage) The direct MCP check failed: \(verification.statusSummary)"
        }
        return MCPSetupOutcome(client: client, state: state, message: message, verification: verification)
    }

    private static func projectDirectoryIssue(_ projectDirectory: URL?, fileManager: FileManager) -> String? {
        guard let projectDirectory else { return "Choose an existing project folder before reviewing project-scoped setup." }
        let root = projectDirectory.standardizedFileURL
        if isSymbolicLink(root, fileManager: fileManager) {
            return "The selected project folder is a symbolic link. Choose its real folder so setup cannot write through a symlink."
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: root.path),
              attributes[.type] as? FileAttributeType == .typeDirectory else {
            return "The selected project folder is unavailable or is not a directory."
        }
        return nil
    }

    private static func projectMCPDestinationIssue(
        for client: MCPSetupClient,
        projectDirectory: URL,
        fileManager: FileManager
    ) -> String? {
        let project = projectDirectory.standardizedFileURL
        let configURL: URL
        let parent: URL
        if client == .codex {
            parent = project.appendingPathComponent(".codex", isDirectory: true)
            configURL = parent.appendingPathComponent("config.toml", isDirectory: false)
            if case .blocked(let path) = inspectDirectory(parent, under: project, fileManager: fileManager) {
                return "Refusing project setup because \(path) is a symbolic link or non-directory."
            }
        } else {
            parent = project
            configURL = project.appendingPathComponent(".mcp.json", isDirectory: false)
        }
        if isSymbolicLink(configURL, fileManager: fileManager) {
            return "Refusing project setup because \(configURL.path) is a symbolic link."
        }
        if let attributes = try? fileManager.attributesOfItem(atPath: configURL.path),
           attributes[.type] as? FileAttributeType != .typeRegular {
            return "Refusing project setup because \(configURL.path) is not a regular file."
        }
        _ = parent
        return nil
    }

    private static func claudeProjectEntry(projectDirectory: URL, matches executablePath: String) -> Bool {
        if case .matching = inspectClaudeProjectEntry(projectDirectory: projectDirectory, helperPath: executablePath) {
            return true
        }
        return false
    }

    private static func inspectClaudeProjectEntry(
        projectDirectory: URL,
        helperPath: String,
        fileManager: FileManager = .default
    ) -> CodexProjectEntryState {
        let configURL = projectDirectory.appendingPathComponent(".mcp.json", isDirectory: false)
        if isSymbolicLink(configURL, fileManager: fileManager) {
            return .unsafe("Refusing project setup because \(configURL.path) is a symbolic link.")
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: configURL.path) else { return .missing }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.uint64Value <= maximumProjectConfigBytes,
              let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unsafe("The project MCP config is not a regular JSON file under the 1 MB setup limit: \(configURL.path)")
        }
        guard root["mcpServers"] == nil || root["mcpServers"] is [String: Any] else {
            return .unsafe("The project .mcp.json has an invalid mcpServers value and will be left unchanged.")
        }
        guard let servers = root["mcpServers"] as? [String: Any], let rawEntry = servers[serverName] else {
            return .missing
        }
        guard let entry = rawEntry as? [String: Any] else { return .conflict }
        return commandEntry(entry, matches: helperPath) ? .matching : .conflict
    }

    private static func appendCodexProjectEntry(
        configURL: URL,
        projectDirectory: URL,
        executablePath: String,
        fileManager: FileManager = .default
    ) throws {
        if let issue = projectMCPDestinationIssue(for: .codex, projectDirectory: projectDirectory, fileManager: fileManager) {
            throw MCPSetupError.unsafePath(issue)
        }
        switch inspectCodexProjectEntry(configURL: configURL, helperPath: executablePath, fileManager: fileManager) {
        case .matching:
            return
        case .conflict:
            throw MCPSetupError.projectConfigConflict(configURL.path)
        case .unsafe(let message):
            throw MCPSetupError.unsafePath(message)
        case .missing:
            break
        }
        let parent = configURL.deletingLastPathComponent()
        try ensureDirectory(parent, under: projectDirectory.standardizedFileURL, fileManager: fileManager)
        let oldData: Data
        let originalPermissions: NSNumber?
        if let attributes = try? fileManager.attributesOfItem(atPath: configURL.path) {
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw MCPSetupError.unsafePath(configURL.path)
            }
            guard let size = attributes[.size] as? NSNumber,
                  size.uint64Value <= maximumProjectConfigBytes,
                  let data = try? Data(contentsOf: configURL), String(data: data, encoding: .utf8) != nil else {
                throw MCPSetupError.unsafePath("The project Codex config is too large or is not valid UTF-8: \(configURL.path)")
            }
            oldData = data
            originalPermissions = attributes[.posixPermissions] as? NSNumber
        } else {
            oldData = Data()
            originalPermissions = nil
        }
        let command = tomlBasicString(executablePath)
        let block = "[mcp_servers.\"\(serverName)\"]\ncommand = \(command)\nargs = []\n"
        var updated = oldData
        if !updated.isEmpty, updated.last != 0x0A { updated.append(0x0A) }
        if !updated.isEmpty { updated.append(0x0A) }
        updated.append(Data(block.utf8))
        try updated.write(to: configURL, options: .atomic)
        if let originalPermissions {
            try? fileManager.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: configURL.path)
        }
    }

    private static func inspectCodexProjectEntry(
        configURL: URL,
        helperPath: String,
        fileManager: FileManager = .default
    ) -> CodexProjectEntryState {
        if isSymbolicLink(configURL, fileManager: fileManager) {
            return .unsafe("Refusing project setup because \(configURL.path) is a symbolic link.")
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: configURL.path) else { return .missing }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.uint64Value <= maximumProjectConfigBytes,
              let data = try? Data(contentsOf: configURL),
              let text = String(data: data, encoding: .utf8) else {
            return .unsafe("The project Codex config is not a regular UTF-8 file under the 1 MB setup limit: \(configURL.path)")
        }
        return codexProjectEntryState(in: text, helperPath: helperPath)
    }

    private static func codexProjectEntryState(in text: String, helperPath: String) -> CodexProjectEntryState {
        var section: [String] = []
        var targetBlocks = 0
        var nestedTarget = false
        var inlineTarget = false
        var command: String?
        var args: String?
        var duplicateTargetValue = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = stripTOMLComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("[") {
                guard let parsed = parseTOMLTableHeader(line) else {
                    return .unsafe("The project Codex config contains a table header the setup checker cannot safely parse.")
                }
                section = parsed
                if parsed == ["mcp_servers", serverName] {
                    targetBlocks += 1
                    command = nil
                    args = nil
                } else if parsed.count > 2 && Array(parsed.prefix(2)) == ["mcp_servers", serverName] {
                    nestedTarget = true
                }
                continue
            }
            guard let (key, value) = parseTOMLAssignment(line) else { continue }
            if section.isEmpty, key == "mcp_servers" { inlineTarget = true }
            if section == ["mcp_servers"], key == serverName { inlineTarget = true }
            guard section == ["mcp_servers", serverName] else { continue }
            switch key {
            case "command":
                if command != nil { duplicateTargetValue = true }
                command = parseTOMLBasicString(value)
            case "args":
                if args != nil { duplicateTargetValue = true }
                args = value.trimmingCharacters(in: .whitespacesAndNewlines)
            default:
                break
            }
        }
        if targetBlocks == 0, !nestedTarget, !inlineTarget { return .missing }
        guard targetBlocks == 1, !nestedTarget, !inlineTarget, !duplicateTargetValue,
              command == helperPath, args == "[]" else { return .conflict }
        return .matching
    }

    private static func stripTOMLComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if let activeQuote = quote {
                if activeQuote == "\"", escaped { escaped = false; continue }
                if activeQuote == "\"", character == "\\" { escaped = true; continue }
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return String(line[..<index])
            }
        }
        return line
    }

    private static func parseTOMLTableHeader(_ line: String) -> [String]? {
        guard line.first == "[", line.last == "]", !line.hasPrefix("[[") else { return nil }
        let inner = String(line.dropFirst().dropLast())
        return parseTOMLDottedKeys(inner)
    }

    private static func parseTOMLAssignment(_ line: String) -> (String, String)? {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if let activeQuote = quote {
                if activeQuote == "\"", escaped { escaped = false; continue }
                if activeQuote == "\"", character == "\\" { escaped = true; continue }
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "=" {
                let keyText = line[..<index].trimmingCharacters(in: .whitespaces)
                guard let key = parseTOMLDottedKeys(keyText), key.count == 1 else { return nil }
                return (key[0], String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private static func parseTOMLDottedKeys(_ text: String) -> [String]? {
        var result: [String] = []
        var index = text.startIndex
        func skipSpaces() { while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) } }
        while index < text.endIndex {
            skipSpaces()
            guard index < text.endIndex else { return nil }
            let key: String
            let quote = text[index]
            if quote == "\"" || quote == "'" {
                let start = index
                index = text.index(after: index)
                var escaped = false
                while index < text.endIndex {
                    let character = text[index]
                    if quote == "\"", escaped { escaped = false; index = text.index(after: index); continue }
                    if quote == "\"", character == "\\" { escaped = true; index = text.index(after: index); continue }
                    if character == quote { index = text.index(after: index); break }
                    index = text.index(after: index)
                }
                guard index <= text.endIndex,
                      let parsed = parseTOMLBasicString(String(text[start..<index])) ?? parseTOMLLiteralString(String(text[start..<index])) else { return nil }
                key = parsed
            } else {
                let start = index
                while index < text.endIndex, text[index].isLetter || text[index].isNumber || text[index] == "_" || text[index] == "-" {
                    index = text.index(after: index)
                }
                guard start != index else { return nil }
                key = String(text[start..<index])
            }
            result.append(key)
            skipSpaces()
            if index == text.endIndex { break }
            guard text[index] == "." else { return nil }
            index = text.index(after: index)
        }
        return result.isEmpty ? nil : result
    }

    private static func parseTOMLBasicString(_ value: String) -> String? {
        guard value.first == "\"", value.last == "\"",
              let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }

    private static func parseTOMLLiteralString(_ value: String) -> String? {
        guard value.count >= 2, value.first == "'", value.last == "'" else { return nil }
        return String(value.dropFirst().dropLast())
    }

    /// TOML basic strings share most escapes with JSON but not `\/`, which
    /// JSONEncoder emits for every slash and TOML parsers reject.
    private static func tomlBasicString(_ value: String) -> String {
        var escaped = String.UnicodeScalarView()
        escaped.append("\"")
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": escaped.append(contentsOf: "\\\"".unicodeScalars)
            case "\\": escaped.append(contentsOf: "\\\\".unicodeScalars)
            case "\n": escaped.append(contentsOf: "\\n".unicodeScalars)
            case "\r": escaped.append(contentsOf: "\\r".unicodeScalars)
            case "\t": escaped.append(contentsOf: "\\t".unicodeScalars)
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                escaped.append(contentsOf: String(format: "\\u%04X", scalar.value).unicodeScalars)
            default: escaped.append(scalar)
            }
        }
        escaped.append("\"")
        return String(escaped)
    }

    private static func ensureDirectory(_ directory: URL, under home: URL, fileManager: FileManager) throws {
        let homePath = home.standardizedFileURL.path
        let targetPath = directory.standardizedFileURL.path
        guard targetPath.hasPrefix(homePath + "/") else { throw MCPSetupError.unsafePath(targetPath) }
        let relative = String(targetPath.dropFirst(homePath.count + 1))
        var current = home.standardizedFileURL
        for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
            current.appendPathComponent(String(component), isDirectory: true)
            guard !isSymbolicLink(current, fileManager: fileManager) else {
                throw MCPSetupError.unsafePath(current.path)
            }
            if let attributes = try? fileManager.attributesOfItem(atPath: current.path) {
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw MCPSetupError.unsafePath(current.path)
                }
            } else {
                try fileManager.createDirectory(at: current, withIntermediateDirectories: false)
            }
        }
    }

    private static func isSymbolicLink(_ url: URL, fileManager: FileManager) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func previewSkills(
        for client: MCPSetupClient,
        catalog: MCPManagedSkillCatalog,
        scope: MCPSetupScope,
        homeDirectory: URL,
        projectDirectory: URL?,
        fileManager: FileManager
    ) -> MCPSetupSkillsPlan {
        let relativeRoot = client.skillRoot
        let anchor: URL
        let root: URL
        let labelRoot: String
        if scope == .project {
            guard let projectDirectory,
                  projectDirectoryIssue(projectDirectory, fileManager: fileManager) == nil else {
                return MCPSetupSkillsPlan(
                    client: client,
                    rootPath: "Project/\(relativeRoot)",
                    state: .blocked,
                    install: [], update: [], alreadyCurrent: [], customizedPreserved: [],
                    retiredManaged: [], retiredCustomizedPreserved: [],
                    blockers: [projectDirectory == nil
                        ? "Choose an existing project folder before previewing project skills."
                        : "The selected project folder is unsafe or unavailable; no paths below it will be inspected or changed."]
                )
            }
            anchor = projectDirectory.standardizedFileURL
            root = anchor.appendingPathComponent(relativeRoot, isDirectory: true)
            labelRoot = relativeRoot
        } else {
            anchor = homeDirectory
            root = homeDirectory.appendingPathComponent(relativeRoot, isDirectory: true)
            labelRoot = "~/\(relativeRoot)"
        }
        let rootPath = scope == .project ? relativeRoot : "~/\(relativeRoot)"
        let rootState = inspectDirectory(root, under: anchor, fileManager: fileManager)
        if case .blocked(let path) = rootState {
            return MCPSetupSkillsPlan(
                client: client,
                rootPath: rootPath,
                state: .blocked,
                install: [], update: [], alreadyCurrent: [], customizedPreserved: [],
                retiredManaged: [], retiredCustomizedPreserved: [],
                blockers: ["\(path) is a symbolic link or non-directory; nothing below it will be inspected or changed."]
            )
        }

        let rootExists: Bool
        if case .exists = rootState { rootExists = true } else { rootExists = false }
        var install: [String] = []
        var update: [String] = []
        var alreadyCurrent: [String] = []
        var customizedPreserved: [String] = []
        var retiredManaged: [String] = []
        var retiredCustomizedPreserved: [String] = []
        var blockers: [String] = []

        for skill in catalog.skills {
            let skillDirectory = root.appendingPathComponent(skill.id, isDirectory: true)
            let destination = skillDirectory.appendingPathComponent("SKILL.md", isDirectory: false)
            let label = "\(labelRoot)/\(skill.id)/SKILL.md"
            let directoryState = rootExists
                ? inspectDirectory(skillDirectory, under: anchor, fileManager: fileManager)
                : .missing
            switch directoryState {
            case .blocked(let path):
                blockers.append("\(path) is a symbolic link or non-directory; this skill will be left untouched.")
                continue
            case .missing:
                install.append(label)
                continue
            case .exists:
                break
            }

            if isSymbolicLink(destination, fileManager: fileManager) {
                customizedPreserved.append(label)
            } else if let attributes = try? fileManager.attributesOfItem(atPath: destination.path) {
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let existing = try? Data(contentsOf: destination) else {
                    customizedPreserved.append(label)
                    continue
                }
                let canonical = Data(skill.content.utf8)
                if existing == canonical {
                    alreadyCurrent.append(label)
                } else if isKnownManaged(existing, hashes: skill.managedSHA256) {
                    update.append(label)
                } else {
                    customizedPreserved.append(label)
                }
            } else {
                install.append(label)
            }
        }

        for retired in catalog.retiredSkills {
            guard rootExists else { continue }
            let skillDirectory = root.appendingPathComponent(retired.id, isDirectory: true)
            let destination = skillDirectory.appendingPathComponent("SKILL.md", isDirectory: false)
            let label = "\(labelRoot)/\(retired.id)/SKILL.md"
            switch inspectDirectory(skillDirectory, under: anchor, fileManager: fileManager) {
            case .blocked(let path):
                blockers.append("\(path) is a symbolic link or non-directory; the retired skill will be left untouched.")
                continue
            case .missing:
                continue
            case .exists:
                break
            }
            if isSymbolicLink(destination, fileManager: fileManager) {
                retiredCustomizedPreserved.append(label)
                continue
            }
            guard let attributes = try? fileManager.attributesOfItem(atPath: destination.path) else { continue }
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let existing = try? Data(contentsOf: destination),
                  isKnownManaged(existing, hashes: retired.managedSHA256) else {
                retiredCustomizedPreserved.append(label)
                continue
            }
            retiredManaged.append(label)
        }

        return MCPSetupSkillsPlan(
            client: client,
            rootPath: rootPath,
            state: .ready,
            install: install,
            update: update,
            alreadyCurrent: alreadyCurrent,
            customizedPreserved: customizedPreserved,
            retiredManaged: retiredManaged,
            retiredCustomizedPreserved: retiredCustomizedPreserved,
            blockers: blockers
        )
    }

    private enum DirectoryInspection {
        case exists
        case missing
        case blocked(String)
    }

    /// Inspects only path components beneath the caller's trusted home root.
    /// Symlink checks happen before metadata reads so preview never follows one.
    private static func inspectDirectory(
        _ directory: URL,
        under home: URL,
        fileManager: FileManager
    ) -> DirectoryInspection {
        let homePath = home.standardizedFileURL.path
        let targetPath = directory.standardizedFileURL.path
        guard targetPath.hasPrefix(homePath + "/") else { return .blocked(targetPath) }
        let relative = String(targetPath.dropFirst(homePath.count + 1))
        var current = home.standardizedFileURL
        for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
            current.appendPathComponent(String(component), isDirectory: true)
            if isSymbolicLink(current, fileManager: fileManager) { return .blocked(current.path) }
            guard let attributes = try? fileManager.attributesOfItem(atPath: current.path) else {
                return .missing
            }
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                return .blocked(current.path)
            }
        }
        return .exists
    }

    private static func isKnownManaged(_ data: Data, hashes: [String]) -> Bool {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return hashes.contains(hash)
    }

    private static func codexEntry(_ text: String, matches executablePath: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              commandEntry(entry, matches: executablePath)
        else { return false }
        return true
    }

    private static func claudeUserEntry(homeDirectory: URL) -> [String: Any]? {
        let configURL = homeDirectory.appendingPathComponent(".claude.json", isDirectory: false)
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: [String: Any]]
        else { return nil }
        return servers[serverName]
    }

    private static func commandEntry(_ entry: [String: Any], matches executablePath: String) -> Bool {
        guard entry["command"] as? String == executablePath else { return false }
        let arguments = entry["args"] as? [String] ?? []
        return arguments.isEmpty
    }

    /// Replaces the machine-wide client locations: package-manager prefixes
    /// from the process environment, Homebrew, /usr/local and /Applications.
    /// Tests set it so a CLI installed on the host cannot leak into results
    /// that should depend only on the injected search path and home directory.
    @TaskLocal static var hostSearchDirectoriesOverride: [String]?

    private static func findExecutable(named name: String, searchPath: String, homeDirectory: URL) -> String? {
        let isCodex = name == MCPSetupClient.codex.rawValue
        let hostOverride = hostSearchDirectoriesOverride
        var directories = searchPath.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        if hostOverride == nil {
            let environment = ProcessInfo.processInfo.environment
            if let npmPrefix = environment["NPM_CONFIG_PREFIX"], !npmPrefix.isEmpty {
                directories.append(URL(fileURLWithPath: npmPrefix, isDirectory: true).appendingPathComponent("bin").path)
            }
            if let npmPrefix = environment["npm_config_prefix"], !npmPrefix.isEmpty {
                directories.append(URL(fileURLWithPath: npmPrefix, isDirectory: true).appendingPathComponent("bin").path)
            }
            if let nodeBin = environment["NVM_BIN"], !nodeBin.isEmpty {
                directories.append(nodeBin)
            }
            if let voltaHome = environment["VOLTA_HOME"], !voltaHome.isEmpty {
                directories.append(URL(fileURLWithPath: voltaHome, isDirectory: true).appendingPathComponent("bin").path)
            }
            if let asdfData = environment["ASDF_DATA_DIR"], !asdfData.isEmpty {
                directories.append(URL(fileURLWithPath: asdfData, isDirectory: true).appendingPathComponent("shims").path)
            }
        }
        directories.append(contentsOf: [
            homeDirectory.appendingPathComponent(".local/bin", isDirectory: true).path,
            homeDirectory.appendingPathComponent(".npm-global/bin", isDirectory: true).path,
            homeDirectory.appendingPathComponent(".volta/bin", isDirectory: true).path,
            homeDirectory.appendingPathComponent(".asdf/shims", isDirectory: true).path,
        ])
        directories.append(contentsOf: hostOverride ?? (
            ["/opt/homebrew/bin", "/usr/local/bin"] + (isCodex ? ["/Applications/ChatGPT.app/Contents/Resources"] : [])
        ))
        if isCodex {
            directories.append(homeDirectory.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources").path)
        }

        for directory in directories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name, isDirectory: false).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func brief(_ value: String) -> String {
        let firstLine = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? "client CLI returned an error"
        return firstLine.isEmpty ? "client CLI returned an error" : firstLine
    }

    private static func cliVersionLabel(_ output: String, for client: MCPSetupClient) -> String? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let clientWord = client == .codex ? "codex" : "claude"
        return lines.first(where: { $0.localizedCaseInsensitiveContains(clientWord) }) ?? lines.last
    }
}
