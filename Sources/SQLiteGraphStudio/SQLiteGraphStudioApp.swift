import AppKit
import StudioCore
import SwiftUI

final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    var onOpenURLs: (([URL]) -> Void)?
    var onTerminate: (() async -> Void)?
    private var pendingOpenURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let databaseURLs = LaunchRequestResolver.databaseURLs(from: urls)
        guard !databaseURLs.isEmpty else { return }

        if let onOpenURLs {
            onOpenURLs(databaseURLs)
        } else {
            pendingOpenURLs.append(contentsOf: databaseURLs)
        }
    }

    func deliverPendingOpenURLs() {
        guard !pendingOpenURLs.isEmpty, let onOpenURLs else { return }
        let urls = pendingOpenURLs
        pendingOpenURLs.removeAll()
        onOpenURLs(urls)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let onTerminate else { return .terminateNow }
        Task { await onTerminate(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main
struct StudioLauncher {
    @MainActor static func main() {
        // AppKit must own the ordinary synchronous main entrypoint. Nesting its
        // event loop inside an async main-actor job starves later UI tasks.
        guard PostgresRuntimeSupervisor.isRequested else {
            SQLiteGraphStudioApp.main()
            return
        }
        Task.detached { exit(await PostgresRuntimeSupervisor.runIfRequested() ?? 2) }
        dispatchMain()
    }
}

struct SQLiteGraphStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var appDelegate
    @State private var session: AppSession = {
        PreferenceDomainMigration.migrateIfNeeded()
        return AppSession()
    }()
    @State private var didConfigureLaunchHandling = false

    var body: some Scene {
        WindowGroup("SQLite Graph Studio") {
            StudioRootView(session: session)
                .frame(minWidth: 1200, minHeight: 760)
                .task {
                    configureLaunchHandling()
                }
        }
        .commands {
            StudioCommands(session: session)
        }
    }

    private func configureLaunchHandling() {
        guard !didConfigureLaunchHandling else { return }
        didConfigureLaunchHandling = true
        appDelegate.onTerminate = { await session.closeAndWait() }

        appDelegate.onOpenURLs = { urls in
            guard let documentURL = urls.first else { return }
            Task {
                await session.openDocument(url: documentURL)
            }
        }
        appDelegate.deliverPendingOpenURLs()

        let launchURLs = LaunchRequestResolver.databaseURLs(fromArguments: ProcessInfo.processInfo.arguments)
        guard let documentURL = launchURLs.first else { return }
        Task {
            await session.openDocument(url: documentURL)
        }
    }
}

private enum LaunchRequestResolver {
    private static let allowedExtensions = DatabaseDocument.supportedExtensions

    static func databaseURLs(fromArguments arguments: [String]) -> [URL] {
        databaseURLs(
            from: arguments.dropFirst().map { argument in
                URL(fileURLWithPath: NSString(string: argument).expandingTildeInPath)
            }
        )
    }

    static func databaseURLs(from urls: [URL]) -> [URL] {
        urls.compactMap { url in
            let resolvedURL = url.standardizedFileURL
            guard allowedExtensions.contains(resolvedURL.pathExtension.lowercased()) else { return nil }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolvedURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return nil
            }

            return resolvedURL
        }
    }
}
