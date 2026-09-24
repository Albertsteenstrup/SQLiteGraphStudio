import AppKit
import Observation
import StudioCore
import StudioMCP
import SwiftUI

@MainActor
@Observable
private final class StudioApplicationState {
    let initialSession: AppSession
    let tabs: WorkspaceTabController
    let automation: StudioAutomationCoordinator
    let server: StudioAutomationServer
    var serverError: String?
    var setupSheetPresented = false
    var setupPreviewLoading = false
    var setupPreview: MCPSetupPreview?
    var setupReport: MCPSetupReport?
    var setupScope: MCPSetupScope = .user
    var setupProjectDirectory: URL?
    var setupRunning = false
    var configured = false
    var setupPreviewRequestID = UUID()
    @ObservationIgnored private var documentOpenTask: Task<Void, Never>?

    init() {
        PreferenceDomainMigration.migrateIfNeeded()
        let session = AppSession()
        let tabs = WorkspaceTabController(initialSession: session)
        let coordinator = StudioAutomationCoordinator(workspaces: tabs)
        self.initialSession = session
        self.tabs = tabs
        self.automation = coordinator
        self.server = StudioAutomationServer(capabilities: [
            "contexts", "workspace-tabs", "schema-discovery", "exact-table-subsets",
            "table-inspection", "read-only-queries", "streaming-system-speech",
        ]) { name, arguments, contextID, clientID in
            await coordinator.handle(name, arguments: arguments, contextID: contextID, clientID: clientID)
        } clientDisconnectHandler: { clientID in
            coordinator.disconnectClient(clientID)
        }
    }

    func installCodingAgents() {
        guard !setupRunning, !setupPreviewLoading else { return }
        setupScope = .user
        setupProjectDirectory = nil
        setupPreviewRequestID = UUID()
        setupPreview = nil
        setupReport = nil
        setupPreviewLoading = true
        setupSheetPresented = true
        Task.detached { [weak self] in
            let preview = MCPSetupInstaller.previewFromAppBundle(scope: .user)
            await MainActor.run {
                guard self?.setupSheetPresented == true else { return }
                self?.setupPreviewLoading = false
                self?.setupPreview = preview
            }
        }
    }

    func reviewCodingAgentSetup(scope: MCPSetupScope, projectDirectory: URL?) {
        guard !setupRunning, setupSheetPresented else { return }
        let requestID = UUID()
        setupPreviewRequestID = requestID
        setupScope = scope
        setupProjectDirectory = projectDirectory
        setupPreview = nil
        setupReport = nil
        setupPreviewLoading = true
        Task.detached { [weak self] in
            let preview = MCPSetupInstaller.previewFromAppBundle(
                scope: scope,
                projectDirectory: projectDirectory
            )
            await MainActor.run {
                guard self?.setupSheetPresented == true,
                      self?.setupPreviewRequestID == requestID,
                      self?.setupScope == scope,
                      self?.setupProjectDirectory?.standardizedFileURL.path == projectDirectory?.standardizedFileURL.path else { return }
                self?.setupPreviewLoading = false
                self?.setupPreview = preview
            }
        }
    }

    func confirmCodingAgentSetup(scope: MCPSetupScope, projectDirectory: URL?) {
        guard !setupRunning, let preview = setupPreview, preview.canInstall else { return }
        guard preview.scope == scope,
              preview.projectDirectoryPath == (scope == .project ? projectDirectory?.standardizedFileURL.path : nil) else { return }
        setupRunning = true
        Task.detached { [weak self] in
            let report = MCPSetupInstaller.installFromAppBundle(
                scope: scope,
                projectDirectory: projectDirectory
            )
            await MainActor.run {
                self?.setupRunning = false
                self?.setupReport = report
            }
        }
    }

    func dismissCodingAgentSetup() {
        guard !setupRunning else { return }
        setupSheetPresented = false
        setupPreviewLoading = false
        setupPreview = nil
        setupReport = nil
        setupScope = .user
        setupProjectDirectory = nil
        setupPreviewRequestID = UUID()
    }

    /// File-open callbacks can arrive while saved tabs are being restored. Keep
    /// them in arrival order so one document never races another tab activation.
    func enqueueOpenDocuments(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let prior = documentOpenTask
        documentOpenTask = Task { @MainActor [tabs] in
            await prior?.value
            await tabs.openDocuments(urls)
        }
    }
}

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
        if SchemaReviewCommand.isRequested {
            Task.detached { exit(await SchemaReviewCommand.run()) }
            dispatchMain()
        }
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

@MainActor
struct SQLiteGraphStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var appDelegate
    @State private var state = StudioApplicationState()

    var body: some Scene {
        Window("SQLite Graph Studio", id: "main") {
            StudioRootView(session: state.initialSession, workspaceTabs: state.tabs)
                .frame(
                    minWidth: WorkspaceCompactLayout.windowMinimumWidth,
                    minHeight: WorkspaceCompactLayout.windowMinimumHeight
                )
                .overlay(alignment: .bottom) {
                    LivePresentationOverlay(coordinator: state.automation)
                        .padding(20)
                }
                .overlay(alignment: .topTrailing) {
                    LiveViewAnnotationOverlay(store: state.automation.viewAnnotations, workspaces: state.tabs)
                        .padding(20)
                }
                .overlay(alignment: .top) {
                    if let error = state.serverError {
                        Text("Local MCP unavailable: \(error)")
                            .font(.caption)
                            .padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .padding(12)
                    }
                }
                .sheet(isPresented: Binding(
                    get: { state.setupSheetPresented },
                    set: { if !$0 { state.dismissCodingAgentSetup() } }
                ), onDismiss: state.dismissCodingAgentSetup) {
                    CodingAgentSetupSheet(
                        scope: state.setupScope,
                        projectDirectory: state.setupProjectDirectory,
                        preview: state.setupPreview,
                        report: state.setupReport,
                        isChecking: state.setupPreviewLoading,
                        isInstalling: state.setupRunning,
                        onReview: state.reviewCodingAgentSetup,
                        onInstall: state.confirmCodingAgentSetup,
                        onDone: state.dismissCodingAgentSetup
                    )
                }
                .task {
                    await configureLaunchHandling()
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            StudioCommands(controller: state.tabs)
            CommandMenu("Coding Agents") {
                Button("Install local MCP and skills…") { state.installCodingAgents() }
                    .disabled(state.setupRunning || state.setupPreviewLoading)
                Button("Allow another coding task to use this tab") {
                    state.automation.releaseActiveWorkspaceForTransfer()
                }
                .disabled(!state.automation.canReleaseActiveWorkspaceForTransfer)
            }
        }
    }

    private func configureLaunchHandling() async {
        guard !state.configured else { return }
        state.configured = true
        let state = state
        let restorationStore = WorkspaceRestorationStore.defaultStore
        if let snapshot = restorationStore.load() {
            await state.tabs.restoreWorkspace(from: snapshot)
        }
        state.tabs.enableAutomaticRestoration(using: restorationStore)

        do {
            try state.server.start()
        } catch {
            state.serverError = error.localizedDescription
        }
        appDelegate.onTerminate = {
            do {
                try state.tabs.saveRestorationState()
            } catch {
                NSLog("SQLite Graph Studio could not save its workspaces: %@", error.localizedDescription)
            }
            state.tabs.stopAutomaticRestoration()
            state.server.stop()
            await state.automation.close()
            await state.tabs.closeAllAndWait()
        }

        appDelegate.onOpenURLs = { urls in
            state.enqueueOpenDocuments(urls)
        }
        appDelegate.deliverPendingOpenURLs()

        let launchURLs = LaunchRequestResolver.databaseURLs(fromArguments: ProcessInfo.processInfo.arguments)
        state.enqueueOpenDocuments(launchURLs)
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
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolvedURL.path, isDirectory: &isDirectory) else { return nil }

            // A folder of versioned .sql files, or a single schema script, opens
            // as a migration model.
            if isDirectory.boolValue { return resolvedURL }
            let fileExtension = resolvedURL.pathExtension.lowercased()
            guard allowedExtensions.contains(fileExtension) || fileExtension == "sql" else { return nil }
            return resolvedURL
        }
    }
}
