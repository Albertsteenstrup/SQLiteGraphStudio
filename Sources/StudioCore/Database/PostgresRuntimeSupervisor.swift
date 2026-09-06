import Darwin
import Foundation

/// Internal executable mode of the app. No UI or document state is initialized.
/// The direct parent relationship detects GUI exit without polling a reusable PID.
public enum PostgresRuntimeSupervisor {
    static let argument = "--studio-postgres-supervisor"
    public static var isRequested: Bool { ProcessInfo.processInfo.arguments.dropFirst().first == argument }

    static func executable() throws -> URL {
        if let explicit = ProcessInfo.processInfo.environment["SGS_POSTGRES_SUPERVISOR"],
           FileManager.default.isExecutableFile(atPath: explicit) {
            return URL(fileURLWithPath: explicit)
        }
        if let executable = Bundle.main.executableURL, executable.lastPathComponent == "SQLiteGraphStudio" {
            return executable
        }
        throw DatabaseUserError(kind: .notFound, message: "The PostgreSQL lifecycle helper is unavailable.",
            recoverySuggestion: "Build or run the complete Graph Studio application. Integration tests can specify SGS_POSTGRES_SUPERVISOR.")
    }

    public static func runIfRequested() async -> Int32? {
        let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        guard arguments.first == argument else { return nil }
        guard arguments.count >= 5, let parent = pid_t(arguments[1]), parent > 1, getppid() == parent else { return 2 }
        // The GUI signals the owned server too. Let this helper finish reaping
        // instead of dying before its server; inherited PostgreSQL handlers are
        // installed by PostgreSQL itself during startup.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGQUIT, SIG_IGN)
        let process = PostgresToolProcess(executable: URL(fileURLWithPath: arguments[4]),
            arguments: Array(arguments.dropFirst(5)), directory: URL(fileURLWithPath: arguments[2]), profile: arguments[3])
        do {
            try process.start()
            while getppid() == parent && process.isRunning {
                try await Task.sleep(for: .milliseconds(100))
            }
            let stopped = await process.stop()
            FileHandle.standardError.write(Data(process.outputText().utf8))
            return stopped ? 0 : 1
        } catch {
            _ = await process.stop()
            FileHandle.standardError.write(Data(process.outputText().utf8))
            return 1
        }
    }
}
