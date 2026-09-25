import AppKit
import CryptoKit
import Foundation
import Observation
import StudioCore
import StudioMCP

/// The app-side boundary for the local MCP helper. Tools are intentionally
/// enumerated here; the helper cannot invoke arbitrary selectors or SQL writes.
@MainActor
@Observable
final class StudioAutomationCoordinator {
    @MainActor
    private final class PresentationState {
        let id: String
        var ownerClientID: String
        let ownerContextID: String
        let workspaceID: UUID
        let title: String
        let controller: LivePresentationController
        let narrator: StudioSpeechNarrator?
        let narrationEnabled: Bool
        var returnCheckpointID: String?
        var returnWorkspaceID: UUID?
        var revision = 1
        var actions: [UUID: [[String: Any]]] = [:]
        var pointsByID: [UUID: LivePresentationController.Point] = [:]
        var externalIDs: [UUID: String] = [:]
        var savedNarration: [UUID: String] = [:]
        var savedTiming: [UUID: (minimumMS: Int, holdMS: Int, advance: String)] = [:]
        var savedEvidence: [UUID: [HistoricalExplanationArtifact.EvidenceReference]] = [:]
        var replayOmissions: [UUID: [String]] = [:]
        var displayedPointOrder: [UUID] = []
        var displayedPointIDs: Set<UUID> = []
        var captionRendered: Set<UUID> = []
        var requiredRenderRevision: [UUID: Int] = [:]

        init(ownerClientID: String, ownerContextID: String, workspaceID: UUID, title: String, narrator: StudioSpeechNarrator?) {
            id = "presentation:" + UUID().uuidString
            self.ownerClientID = ownerClientID
            self.ownerContextID = ownerContextID
            self.workspaceID = workspaceID
            self.title = title
            self.narrator = narrator
            narrationEnabled = narrator != nil
            controller = LivePresentationController(narrator: narrator)
        }
    }

    private struct Context {
        let id: String
        var clientID: String
        let taskID: String
        var resumeTokenHash: Data
        var workspaceID: UUID?
        var disconnectedAt: Date?
        var recoveryStatus: String
    }

    private struct Receipt {
        let fingerprint: String
        let result: Data
        let contextID: String
        let createdAt: Date
    }

    private struct ViewCheckpoint {
        let workspace: UUID
        let sourceID: String
        let selected: Set<String>
        let expanded: Set<String>
        let visible: Set<String>?
        let zoom: CGFloat
        let pan: CGSize
        let positions: GraphLayoutSnapshot
        let nodeSizeMetric: GraphNodeSizeMetric
        let leftPane: PaneContentKind
        let rightPane: PaneContentKind
        let activePaneSide: WorkspacePaneSide
        let activeTableTabID: UUID?
        let openTableTabIDs: Set<UUID>
        let activeQueryID: UUID?
        let showsAllGraphTableCards: Bool
        let splitFraction: CGFloat
        let maximizedPane: WorkspacePaneSide?
        let annotations: [LiveViewAnnotation]
    }

    private struct Failure: LocalizedError {
        let code: String
        let detail: String
        var errorDescription: String? { detail }
    }

    private enum ExportWork: Sendable {
        case retainedRows(names: [String], rows: [[DatabaseResultValue]])
        case matchingTableRows(reader: DatabaseService, target: DatabaseTarget, query: TableQueryState, descriptor: TableDescriptor)
    }

    private final class ExportJobState {
        let id: String
        let clientID: String
        let contextID: String
        let workspaceID: UUID
        let sourceID: String
        let sourceRevision: String
        let destination: URL
        let format: DataTransferFormat
        let scope: String
        let objectType: String
        let objectID: String?
        let overwrite: Bool
        let sourceResultTruncated: Bool
        let timeoutSeconds: Int
        let cancellation = ExportCancellation()
        var status = "queued"
        var rowsWritten = 0
        var rowCount: Int?
        var error: String?
        var task: Task<Void, Never>?

        init(id: String, clientID: String, contextID: String, workspaceID: UUID, sourceID: String, sourceRevision: String,
             destination: URL, format: DataTransferFormat, scope: String, objectType: String,
             objectID: String?, overwrite: Bool, sourceResultTruncated: Bool = false, timeoutSeconds: Int = 300) {
            self.id = id
            self.clientID = clientID
            self.contextID = contextID
            self.workspaceID = workspaceID
            self.sourceID = sourceID
            self.sourceRevision = sourceRevision
            self.destination = destination
            self.format = format
            self.scope = scope
            self.objectType = objectType
            self.objectID = objectID
            self.overwrite = overwrite
            self.sourceResultTruncated = sourceResultTruncated
            self.timeoutSeconds = timeoutSeconds
        }
    }

    /// Read-only MCP queries run independently from the tool call so a slow
    /// query never holds the coding agent's request open. The immutable result
    /// is published only after the source, owner and cancellation state still
    /// match the values captured at launch.
    private final class QueryJobState {
        let id: String
        let clientID: String
        let contextID: String
        let workspaceID: UUID
        let sourceID: String
        let sourceRevision: String
        let sql: String
        let title: String?
        let rowLimit: Int
        let timeoutSeconds: Int
        var status = "queued"
        var resultID: String?
        var error: String?
        var task: Task<Void, Never>?

        init(id: String, clientID: String, contextID: String, workspaceID: UUID,
             sourceID: String, sourceRevision: String, sql: String, title: String?,
             rowLimit: Int, timeoutSeconds: Int) {
            self.id = id
            self.clientID = clientID
            self.contextID = contextID
            self.workspaceID = workspaceID
            self.sourceID = sourceID
            self.sourceRevision = sourceRevision
            self.sql = sql
            self.title = title
            self.rowLimit = rowLimit
            self.timeoutSeconds = timeoutSeconds
        }
    }

    private final class SpeechOperationJob {
        let id: String
        let clientID: String
        let ownerContextID: String
        let kind: String
        let workspaceID: UUID?
        let packageID: String?
        let voiceID: String?
        let sampleCharacterCount: Int?
        var status = "queued"
        var error: String?
        var progress: SpeechPlaybackStatus = .preparing("Waiting to start")
        var providerName: String?
        var providerID: String?
        var narrator: StudioSpeechNarrator?
        var task: Task<Void, Never>?

        init(
            id: String,
            clientID: String,
            ownerContextID: String,
            kind: String,
            workspaceID: UUID? = nil,
            packageID: String? = nil,
            voiceID: String? = nil,
            sampleCharacterCount: Int? = nil,
            narrator: StudioSpeechNarrator? = nil
        ) {
            self.id = id
            self.clientID = clientID
            self.ownerContextID = ownerContextID
            self.kind = kind
            self.workspaceID = workspaceID
            self.packageID = packageID
            self.voiceID = voiceID
            self.sampleCharacterCount = sampleCharacterCount
            self.narrator = narrator
        }
    }

    let workspaces: WorkspaceTabController
    private let openDocument: @MainActor (AppSession, URL) async -> Void
    let viewAnnotations = LiveViewAnnotationStore()
    private var contexts: [String: Context] = [:]
    /// Tabs opened by a coding task remain private to its retained context,
    /// including across a stdio reconnect. Native tabs have no owner until a
    /// task attaches or a user explicitly transfers one.
    private var workspaceOwners: [UUID: String] = [:]
    private var readers: [UUID: DatabaseService] = [:]
    private var readerTargets: [UUID: String] = [:]
    private var results: [String: (workspace: UUID, sql: String, result: QueryResult, sourceID: String, sourceRevision: String,
                                   displayedOffset: Int, displayedLimit: Int, ownerClientID: String, ownerContextID: String)] = [:]
    private var artifacts: [String: URL] = [:]
    private var artifactOwners: [String: String] = [:]
    private var artifactFingerprints: [String: String] = [:]
    private var presentations: [String: PresentationState] = [:]
    private var presentationTasks: [String: Task<Void, Never>] = [:]
    private var currentPresentationIDByWorkspace: [UUID: String] = [:]
    private var checkpoints: [String: ViewCheckpoint] = [:]
    private var receipts: [String: Receipt] = [:]
    private var inFlightReceipts: [String: String] = [:]
    private var exportJobs: [String: ExportJobState] = [:]
    private var queryJobs: [String: QueryJobState] = [:]
    private var speechJobs: [String: SpeechOperationJob] = [:]
    private let speechAssetManager = PocketTTSAssetDownloadManager()
    private var annotationSourceByWorkspace: [UUID: String] = [:]
    @ObservationIgnored private var visibilityObservers: [NSObjectProtocol] = []
    private static let contextRetention: TimeInterval = 24 * 60 * 60
    private static let maximumRetainedContexts = 128
    private static let maximumReceipts = 4_096
    private static let mutatingTools: Set<String> = [
        "studio_open_source", "studio_create_workspace", "studio_update_workspace", "studio_close_workspace",
        "studio_set_layout", "studio_capture_view", "studio_restore_view", "studio_refresh_source",
        "studio_show_tables", "studio_select_objects", "studio_expand_tables", "studio_focus_keys",
        "studio_set_camera", "studio_arrange_tables", "studio_set_node_sizing", "studio_set_groups",
        "studio_annotate_view", "studio_open_table", "studio_configure_table", "studio_inspect_value",
        "studio_follow_record", "studio_show_record_graph", "studio_prepare_query",
        "studio_run_query", "studio_show_query_results", "studio_start_presentation", "studio_update_presentation",
        "studio_control_presentation", "studio_update_preferences", "studio_update_annotations", "studio_capture_schema",
        "studio_update_preview", "studio_compare_schemas", "studio_show_artifact", "studio_save_explanation",
        "studio_open_explanation", "studio_prepare_explanation_refresh", "studio_export", "studio_configure_speech",
        "studio_manage_speech_assets", "studio_test_speech", "studio_cancel_job",
    ]

    init(
        workspaces: WorkspaceTabController,
        openDocument: @escaping @MainActor (AppSession, URL) async -> Void = { session, url in
            await session.openDocument(url: url)
        }
    ) {
        self.workspaces = workspaces
        self.openDocument = openDocument
        workspaces.onActiveTabChanged = { [weak self] activeID in
            self?.pausePresentationsOutside(activeID)
        }
        workspaces.onTabClosed = { [weak self] closedID in
            self?.releaseWorkspace(closedID)
        }
        for name in [NSApplication.didHideNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
            visibilityObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.hasVisibleAppWindow else { return }
                    self.pausePresentationsOutside(nil)
                    self.stopSpeechTestsForHiddenWindow()
                }
            })
        }
        synchronizeManualGraphHooks()
    }

    private var hasVisibleAppWindow: Bool {
        guard let app = NSApp, !app.isHidden else { return false }
        return app.windows.contains {
            // AppKit can report an active SwiftUI window as occluded while a
            // local agent's host is switching focus. An active window is still
            // safe to narrate; inactive windows must be genuinely exposed.
            $0.isVisible && !$0.isMiniaturized && (app.isActive || $0.occlusionState.contains(.visible))
        }
    }

    private func synchronizeManualGraphHooks() {
        for tab in workspaces.tabs {
            let id = tab.id
            tab.session.onManualGraphInteraction = { [weak self] in
                guard let self else { return }
                self.workspaces.tabs.first(where: { $0.id == id })?.session.markAutomationViewChanged()
                guard let presentationID = self.currentPresentationIDByWorkspace[id],
                      let state = self.presentations[presentationID] else { return }
                switch state.controller.status {
                case .preparing(let pointID), .applied(let pointID):
                    state.controller.markFailed(pointID: pointID,
                        message: "The view changed while this point was being prepared. Retry or revise the explanation from the current view.")
                default:
                    // The camera now belongs to the user; stop speech immediately
                    // so it cannot describe a view they have moved away from.
                    state.controller.pauseForChangedView()
                }
                state.revision += 1
            }
        }
    }

    private func pausePresentationsOutside(_ activeID: UUID?) {
        for state in presentations.values where state.workspaceID != activeID {
            state.controller.pause()
            state.revision += 1
        }
    }

    private func releaseWorkspace(_ workspaceID: UUID) {
        workspaces.tabs.first(where: { $0.id == workspaceID })?.session.selectHistoricalExplanationPoint(externalPointID: nil)
        workspaceOwners.removeValue(forKey: workspaceID)
        cancelQueryJobs(workspaceID: workspaceID)
        viewAnnotations.clear(nil, in: workspaceID)
        annotationSourceByWorkspace.removeValue(forKey: workspaceID)
        for job in exportJobs.values where job.workspaceID == workspaceID && (job.status == "queued" || job.status == "running") {
            job.cancellation.cancel()
            job.task?.cancel()
        }
        for job in speechJobs.values where job.kind == "speech_test" && job.workspaceID == workspaceID
            && ["queued", "running", "cancelling"].contains(job.status) {
            job.status = "cancelling"
            job.narrator?.stop()
            job.task?.cancel()
        }
        if let reader = readers.removeValue(forKey: workspaceID) {
            Task { await reader.close() }
        }
        readerTargets.removeValue(forKey: workspaceID)
        results = results.filter { $0.value.workspace != workspaceID }
        checkpoints = checkpoints.filter { $0.value.workspace != workspaceID }
        currentPresentationIDByWorkspace.removeValue(forKey: workspaceID)
        let presentationIDs = presentations.compactMap { $0.value.workspaceID == workspaceID ? $0.key : nil }
        for id in presentationIDs {
            presentations[id]?.controller.end()
            presentationTasks.removeValue(forKey: id)?.cancel()
            presentations.removeValue(forKey: id)
        }
        for id in Array(contexts.keys) where contexts[id]?.workspaceID == workspaceID {
            contexts[id]?.workspaceID = nil
            contexts[id]?.recoveryStatus = "workspace_closed"
        }
    }

    private func cancelQueryJobs(workspaceID: UUID? = nil, contextID: String? = nil) {
        for job in queryJobs.values where
            (workspaceID == nil || job.workspaceID == workspaceID) &&
            (contextID == nil || job.contextID == contextID) &&
            (job.status == "queued" || job.status == "running") {
            // Mark terminal before cancelling so a completion racing this
            // callback cannot publish a result or update the query pane.
            job.status = "cancelled"
            job.task?.cancel()
        }
    }

    var activePresentation: LivePresentationController? {
        guard let state = currentPresentationState,
              state.controller.currentPoint != nil,
              state.controller.status != .interrupted else { return nil }
        return state.controller
    }

    var activePresentationTitle: String? {
        activePresentation == nil ? nil : currentPresentationState?.title
    }

    var activePresentationID: String? {
        activePresentation == nil ? nil : currentPresentationState?.id
    }

    private var currentPresentationState: PresentationState? {
        guard let workspaceID = workspaces.activeTabID,
              let id = currentPresentationIDByWorkspace[workspaceID] else { return nil }
        return presentations[id]
    }

    private func clearHistoricalReplaySelection(for state: PresentationState) {
        workspaces.tabs.first(where: { $0.id == state.workspaceID })?.session.selectHistoricalExplanationPoint(externalPointID: nil)
    }

    func captionRendered(pointID: UUID) {
        guard let state = currentPresentationState, state.controller.currentPoint?.id == pointID else { return }
        state.captionRendered.insert(pointID)
        maybeMarkPointVisible(state)
    }

    func userControlPresentation(_ control: String) {
        guard let state = currentPresentationState else { return }
        let hadCompleted = state.controller.status == .completed
        let priorPointID = state.controller.currentPoint?.id
        switch control {
        case "pause": state.controller.pause()
        case "continue": state.controller.resume()
        case "back": state.controller.back()
        case "next": state.controller.next()
        case "repeat": state.controller.retryCurrent()
        case "end":
            state.controller.end()
            presentationTasks.removeValue(forKey: state.id)?.cancel()
            clearHistoricalReplaySelection(for: state)
        case "return":
            state.controller.end()
            presentationTasks.removeValue(forKey: state.id)?.cancel()
            clearHistoricalReplaySelection(for: state)
            if let checkpointID = state.returnCheckpointID,
               let tab = workspaces.tabs.first(where: { $0.id == state.workspaceID }) {
                try? restoreView(checkpointID, in: tab)
            }
            if let priorWorkspace = state.returnWorkspaceID {
                workspaces.activate(priorWorkspace)
            }
        default: return
        }
        if let pointID = state.controller.currentPoint?.id, pointID != priorPointID {
            state.captionRendered.remove(pointID)
            state.requiredRenderRevision.removeValue(forKey: pointID)
        }
        if hadCompleted && ["back", "next", "repeat"].contains(control) {
            startPresentationLoop(state)
        }
        state.revision += 1
    }

    func close() async {
        for observer in visibilityObservers { NotificationCenter.default.removeObserver(observer) }
        visibilityObservers.removeAll()
        cancelQueryJobs()
        for task in presentationTasks.values { task.cancel() }
        for presentation in presentations.values { presentation.controller.end() }
        for job in exportJobs.values where job.status == "queued" || job.status == "running" || job.status == "cancelling" {
            job.cancellation.cancel()
            job.task?.cancel()
        }
        for job in speechJobs.values where ["queued", "running", "cancelling"].contains(job.status) {
            job.status = "cancelling"
            if job.kind == "speech_asset_install" { speechAssetManager.cancel() }
            job.narrator?.stop()
            job.task?.cancel()
        }
        for job in exportJobs.values { await job.task?.value }
        for job in queryJobs.values { await job.task?.value }
        for job in speechJobs.values { await job.task?.value }
        for reader in readers.values { await reader.close() }
        readers.removeAll()
    }

    /// Marks task contexts resumable when a stdio MCP process ends. The stable
    /// context continues to own its workspaces and receipts until explicit
    /// native transfer or bounded retention expires. Transient jobs are stopped.
    func disconnectClient(_ clientID: String) {
        let disconnectedContextIDs = contexts.values.filter { $0.clientID == clientID }.map(\.id)
        for contextID in disconnectedContextIDs { cancelQueryJobs(contextID: contextID) }
        for state in presentations.values where contexts[state.ownerContextID]?.clientID == clientID {
            state.controller.pause()
            state.revision += 1
        }
        for job in exportJobs.values where job.clientID == clientID
            && ["queued", "running", "cancelling"].contains(job.status) {
            job.status = "cancelling"
            job.cancellation.cancel()
            job.task?.cancel()
        }
        for job in speechJobs.values where job.clientID == clientID && job.kind == "speech_test"
            && ["queued", "running", "cancelling"].contains(job.status) {
            job.status = "cancelling"
            job.narrator?.stop()
            job.task?.cancel()
        }
        let disconnectedAt = Date()
        for id in Array(contexts.keys) where contexts[id]?.clientID == clientID {
            contexts[id]?.disconnectedAt = disconnectedAt
            if !["ownership_released", "workspace_closed"].contains(contexts[id]?.recoveryStatus ?? "") {
                contexts[id]?.recoveryStatus = "disconnected"
            }
        }
        pruneRetainedState(now: disconnectedAt)
    }

    func pruneRetainedState(now: Date) {
        let expiredByAge = contexts.values
            .filter { context in
                guard let disconnectedAt = context.disconnectedAt else { return false }
                return now.timeIntervalSince(disconnectedAt) >= Self.contextRetention
            }
            .map(\.id)
        for id in expiredByAge { expireContext(id) }

        let detached = contexts.values
            .filter { $0.disconnectedAt != nil }
            .sorted { ($0.disconnectedAt ?? .distantPast) < ($1.disconnectedAt ?? .distantPast) }
        if detached.count > Self.maximumRetainedContexts {
            for context in detached.prefix(detached.count - Self.maximumRetainedContexts) {
                expireContext(context.id)
            }
        }

        receipts = receipts.filter { now.timeIntervalSince($0.value.createdAt) < Self.contextRetention }
        if receipts.count > Self.maximumReceipts {
            let excess = receipts.count - Self.maximumReceipts
            for key in receipts.sorted(by: { $0.value.createdAt < $1.value.createdAt }).prefix(excess).map(\.key) {
                receipts.removeValue(forKey: key)
            }
        }
    }

    private func expireContext(_ contextID: String) {
        cancelQueryJobs(contextID: contextID)
        guard contexts.removeValue(forKey: contextID) != nil else { return }
        let ownedWorkspaceIDs = workspaceOwners.compactMap { $0.value == contextID ? $0.key : nil }
        for workspaceID in ownedWorkspaceIDs {
            checkpoints = checkpoints.filter { $0.value.workspace != workspaceID }
            viewAnnotations.clear(nil, in: workspaceID)
            annotationSourceByWorkspace.removeValue(forKey: workspaceID)
        }
        workspaceOwners = workspaceOwners.filter { $0.value != contextID }
        receipts = receipts.filter { $0.value.contextID != contextID }
        inFlightReceipts = inFlightReceipts.filter { !$0.key.hasPrefix(contextID + ":") }
        artifacts = artifacts.filter { artifactOwners[$0.key] != contextID }
        artifactFingerprints = artifactFingerprints.filter { artifactOwners[$0.key] != contextID }
        artifactOwners = artifactOwners.filter { $0.value != contextID }
        results = results.filter { $0.value.ownerContextID != contextID }

        let presentationIDs = presentations.compactMap { $0.value.ownerContextID == contextID ? $0.key : nil }
        for id in presentationIDs {
            presentations[id]?.controller.end()
            presentationTasks.removeValue(forKey: id)?.cancel()
            if let workspaceID = presentations[id]?.workspaceID,
               currentPresentationIDByWorkspace[workspaceID] == id {
                currentPresentationIDByWorkspace.removeValue(forKey: workspaceID)
            }
            presentations.removeValue(forKey: id)
        }
        for job in exportJobs.values where job.contextID == contextID
            && ["queued", "running", "cancelling"].contains(job.status) {
            job.cancellation.cancel()
            job.task?.cancel()
        }
        for job in speechJobs.values where job.ownerContextID == contextID
            && job.kind == "speech_test" && ["queued", "running", "cancelling"].contains(job.status) {
            job.narrator?.stop()
            job.task?.cancel()
        }
        exportJobs = exportJobs.filter { $0.value.contextID != contextID }
        queryJobs = queryJobs.filter { $0.value.contextID != contextID }
        speechJobs = speechJobs.filter {
            $0.value.ownerContextID != contextID || $0.value.kind == "speech_asset_install"
        }
    }

    /// A deliberate native handoff lets another coding task attach to the
    /// foreground tab. No MCP call can release a tab owned by a different task.
    var canReleaseActiveWorkspaceForTransfer: Bool {
        workspaces.activeTabID.flatMap { workspaceOwners[$0] } != nil
    }

    func releaseActiveWorkspaceForTransfer() {
        guard let tabID = workspaces.activeTabID,
              let ownerID = workspaceOwners.removeValue(forKey: tabID) else { return }
        cancelQueryJobs(workspaceID: tabID, contextID: ownerID)
        if contexts[ownerID]?.workspaceID == tabID {
            contexts[ownerID]?.workspaceID = nil
            contexts[ownerID]?.recoveryStatus = "ownership_released"
        }
        if let presentationID = currentPresentationIDByWorkspace[tabID],
           let presentation = presentations[presentationID] {
            presentation.controller.pause()
            presentation.revision += 1
        }
        for job in exportJobs.values where job.workspaceID == tabID && job.contextID == ownerID
            && ["queued", "running", "cancelling"].contains(job.status) {
            job.status = "cancelling"
            job.cancellation.cancel()
            job.task?.cancel()
        }
    }

    func handle(_ name: String, arguments: Data, contextID: String?, clientID: String) async -> Data {
        var pendingReceipt: (key: String, fingerprint: String, contextID: String)?
        var receiptContextID = contextID
        do {
            pruneRetainedState(now: Date())
            synchronizeManualGraphHooks()
            guard let args = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "Tool arguments must be a JSON object.")
            }
            receiptContextID = contextID ?? string(args, "context_id")
            if Self.mutatingTools.contains(name) {
                let context = try ownedContext(receiptContextID, clientID: clientID)
                let requestID = try requiredString(args, "request_id")
                let key = context.id + ":" + requestID
                let normalized = try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
                let fp = fingerprint(name + ":" + String(decoding: normalized, as: UTF8.self))
                if let prior = receipts[key] {
                    guard prior.fingerprint == fp else {
                        throw Failure(code: "REQUEST_ID_CONFLICT", detail: "This request_id was already used with different arguments.")
                    }
                    return prior.result
                }
                if let inFlight = inFlightReceipts[key] {
                    guard inFlight == fp else {
                        throw Failure(code: "REQUEST_ID_CONFLICT", detail: "This request_id is running with different arguments.")
                    }
                    throw Failure(code: "REQUEST_IN_PROGRESS", detail: "The original request is still running. Retry this same request_id after it finishes.")
                }
                inFlightReceipts[key] = fp
                pendingReceipt = (key, fp, context.id)
            }
            let payload = try await execute(name, args, contextID: contextID, clientID: clientID)
            synchronizeManualGraphHooks()
            let response = Self.result("Graph Studio returned \(name). Check structured status for visibility and completion.", payload)
            if let pendingReceipt {
                inFlightReceipts.removeValue(forKey: pendingReceipt.key)
                storeReceipt(pendingReceipt, response: response)
            }
            return response
        } catch let failure as Failure {
            let response = Self.result(failure.detail, ["error": ["code": failure.code, "message": failure.detail,
                                                               "recovery": recovery(for: failure.code)]], error: true)
            if let pendingReceipt {
                inFlightReceipts.removeValue(forKey: pendingReceipt.key)
                storeReceipt(pendingReceipt, response: response)
            }
            return response
        } catch {
            let response = Self.result(error.localizedDescription, ["error": ["code": "OPERATION_FAILED", "message": error.localizedDescription,
                                                                         "recovery": "Read the current view and retry with corrected inputs."]], error: true)
            if let pendingReceipt {
                inFlightReceipts.removeValue(forKey: pendingReceipt.key)
                storeReceipt(pendingReceipt, response: response)
            }
            return response
        }
    }

    private func storeReceipt(_ pending: (key: String, fingerprint: String, contextID: String), response: Data) {
        guard contexts[pending.contextID] != nil else { return }
        receipts[pending.key] = Receipt(fingerprint: pending.fingerprint, result: response,
                                        contextID: pending.contextID, createdAt: Date())
        pruneRetainedState(now: Date())
    }

    private func execute(_ name: String, _ args: [String: Any], contextID: String?, clientID: String) async throws -> [String: Any] {
        // Never interpret a malformed or stale explicit target as an omitted
        // target. Falling back to the task's bound tab can expose another source.
        if args["workspace_id"] != nil {
            guard let requested = explicitWorkspace(args) else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "workspace_id must be an exact workspace UUID from studio_list_workspaces.")
            }
            guard workspaces.tabs.contains(where: { $0.id == requested }) else {
                throw Failure(code: "OBJECT_NOT_FOUND", detail: "The requested workspace_id is no longer open.")
            }
        }
        if name == "studio_connect_context" {
            let taskID = string(args, "client_task_id") ?? UUID().uuidString
            if let resumeContextID = string(args, "resume_context_id") {
                let resumeToken = try requiredString(args, "resume_token")
                guard var existing = contexts[resumeContextID] else {
                    throw Failure(code: "CONTEXT_EXPIRED", detail: "This task context has expired or is no longer available. Connect a new context and select the intended workspace explicitly.")
                }
                guard taskID == existing.taskID, matchesResumeToken(resumeToken, hash: existing.resumeTokenHash) else {
                    throw Failure(code: "RESUME_DENIED", detail: "The resume capability does not match this coding task.")
                }
                guard existing.clientID == clientID || existing.disconnectedAt != nil else {
                    throw Failure(code: "CONTEXT_IN_USE", detail: "This coding task is still connected to another MCP client. Close that connection before resuming it.")
                }

                let rotatedToken = makeResumeToken()
                existing.clientID = clientID
                existing.disconnectedAt = nil
                if !["ownership_released", "workspace_closed"].contains(existing.recoveryStatus) {
                    existing.recoveryStatus = "resumed"
                }
                existing.resumeTokenHash = resumeTokenHash(rotatedToken)
                if let bound = existing.workspaceID {
                    if !workspaces.tabs.contains(where: { $0.id == bound }) {
                        existing.workspaceID = nil
                        existing.recoveryStatus = "workspace_closed"
                    } else if workspaceOwners[bound] != existing.id {
                        // A native transfer is authoritative. A reconnect reports
                        // the release instead of silently reclaiming the tab.
                        existing.workspaceID = nil
                        existing.recoveryStatus = "ownership_released"
                    }
                }
                if let requested = explicitWorkspace(args) {
                    try claimWorkspace(requested, for: existing.id)
                    existing.workspaceID = requested
                    existing.recoveryStatus = "workspace_selected"
                }
                contexts[resumeContextID] = existing
                for state in presentations.values where state.ownerContextID == existing.id {
                    state.ownerClientID = clientID
                }
                return contextPayload(resumeContextID, existing, resumeToken: rotatedToken)
            }
            if args["resume_token"] != nil {
                throw Failure(code: "INVALID_ARGUMENT", detail: "resume_token requires its matching resume_context_id.")
            }
            let id = "context:" + UUID().uuidString
            let unowned = workspaces.tabs.filter { workspaceOwners[$0.id] == nil }
            let chosen = explicitWorkspace(args) ?? (unowned.count == 1 ? unowned.first?.id : nil)
            if let chosen { try claimWorkspace(chosen, for: id) }
            let resumeToken = makeResumeToken()
            contexts[id] = Context(id: id, clientID: clientID, taskID: taskID,
                                   resumeTokenHash: resumeTokenHash(resumeToken), workspaceID: chosen,
                                   disconnectedAt: nil, recoveryStatus: "connected")
            return contextPayload(id, contexts[id]!, resumeToken: resumeToken)
        }

        let context = try ownedContext(contextID ?? string(args, "context_id"), clientID: clientID)
        if let requested = explicitWorkspace(args), requested != context.workspaceID {
            throw Failure(code: "CONTEXT_WORKSPACE_MISMATCH", detail: "This coding task is bound to another workspace. Call studio_connect_context with the same client_task_id and the intended workspace_id to switch deliberately.")
        }
        if let tab = try? workspace(args, context: context),
           let annotatedSource = annotationSourceByWorkspace[tab.id],
           annotatedSource != sourceID(tab) {
            viewAnnotations.clear(nil, in: tab.id)
            annotationSourceByWorkspace.removeValue(forKey: tab.id)
        }
        if let expected = string(args, "expected_view_revision"), let tab = try? workspace(args, context: context),
           expected != viewRevision(tab) {
            throw Failure(code: "STALE_VIEW", detail: "The workspace changed since this request was prepared. Read studio_get_view before retrying.")
        }
        switch name {
        case "studio_list_workspaces":
            return ["workspaces": availableWorkspaces(for: context.id).map(workspacePayload),
                    "active_workspace_id": visibleActiveWorkspaceID(for: context.id)]
        case "studio_scan_project":
            let path = try requiredString(args, "project_path")
            let root = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw Failure(code: "SOURCE_NOT_FOUND", detail: "project_path must name an existing local folder.")
            }
            let result = try await BackgroundWork.run {
                try ProjectScanner.scan(root: root, limits: ProjectScanLimits(maximumDepth: 14,
                                                                            maximumEntries: 50_000,
                                                                            honorsGitIgnore: true))
            }
            let offset = args["candidate_offset"] as? Int ?? 0
            guard offset >= 0, offset <= result.candidates.count else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "candidate_offset must be within the scan result.")
            }
            let limit = bounded(args, "candidate_limit", default: 25, maximum: 50)
            let page = result.candidates.dropFirst(offset).prefix(limit)
            let candidates: [[String: Any]] = page.map { candidate in
                var item: [String: Any] = [
                    "candidate_id": candidate.id,
                    "kind": candidate.kind.rawValue,
                    "source_path": candidate.url.path,
                    "title": candidate.title,
                    "relative_path": candidate.relativePath,
                    "detail": candidate.detail,
                ]
                item["migration_count"] = candidate.migrationSet?.files.count as Any? ?? NSNull()
                item["latest_migration_version"] = candidate.migrationSet?.latest?.version as Any? ?? NSNull()
                item["engine"] = candidate.migrationSet?.dialect.displayName
                    ?? (candidate.kind == .sqliteDatabase ? "SQLite" : "PostgreSQL")
                item["supports_rows"] = candidate.kind == .sqliteDatabase || candidate.kind == .postgresConnection
                return item
            }
            let response: [String: Any] = [
                "project_path": root.path,
                "candidates": candidates,
                "candidate_offset": offset,
                "candidate_count": result.candidates.count,
                "available_engines": result.sourceEngines.map(\.displayName),
                "source_choice_required": result.requiresEngineChoice,
                "source_choice_reason": result.requiresEngineChoice
                    ? "Both PostgreSQL and SQLite models were found. Ask which model the user wants before opening a source."
                    : NSNull(),
                "has_more_candidates": offset + page.count < result.candidates.count,
                "reached_scan_limit": result.reachedLimit,
                "directories_visited": result.directoriesVisited,
                "files_inspected": result.filesInspected,
                "skipped_directory_count": result.skippedDirectoryCount,
            ]
            return response
        case "studio_open_source":
            guard let path = string(args, "source_path") else { throw Failure(code: "INVALID_ARGUMENT", detail: "Provide source_path for a local database or workspace file.") }
            let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw Failure(code: "SOURCE_NOT_FOUND", detail: "The requested source file does not exist: \(url.path)")
            }
            let migrationSource = isDirectory.boolValue || url.pathExtension.lowercased() == "sql"
            var resolvedMigrationVersion: String?
            if migrationSource {
                let set: MigrationSet
                do {
                    set = try await BackgroundWork.run { try ProjectScanner.migrationSet(at: url) }
                } catch {
                    if isDirectory.boolValue {
                        throw Failure(code: "PROJECT_SELECTION_REQUIRED", detail: "This folder is not one migration set. Call studio_scan_project for exact candidate source_path values, then open the intended candidate with a new request_id.")
                    }
                    throw Failure(code: "SOURCE_OPEN_FAILED", detail: error.localizedDescription)
                }
                if let version = string(args, "migration_version"), set.index(ofVersion: version) == nil {
                    throw Failure(code: "INVALID_ARGUMENT", detail: "migration_version must match a version in the selected migration set.")
                }
                resolvedMigrationVersion = string(args, "migration_version") ?? set.latest?.version
            } else if !DatabaseDocument.supportedExtensions.contains(url.pathExtension.lowercased()),
                      url.pathExtension.lowercased() != "sql" {
                throw Failure(code: "UNSUPPORTED_SOURCE", detail: "Graph Studio does not support this source file type.")
            }
            if !migrationSource, string(args, "migration_version") != nil {
                throw Failure(code: "INVALID_ARGUMENT", detail: "migration_version applies only to a migration set or SQL schema script.")
            }
            if let boundID = context.workspaceID,
               let bound = workspaces.tabs.first(where: { $0.id == boundID }),
               workspaceOwners[boundID] == context.id,
               bound.session.databaseURL?.resolvingSymlinksInPath().standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL,
               (!migrationSource || bound.session.selectedMigrationVersion == resolvedMigrationVersion),
               bound.session.hasOpenDatabase || bound.session.schemaReview != nil {
                if bool(args, "activate") == true { workspaces.activate(bound.id) }
                return workspacePayload(bound).merging(["reused": true]) { _, new in new }
            }
            try requireAutomationWorkspaceCapacity(openingDocument: true)
            let tab = workspaces.createTab(kind: inferredWorkspaceKind(for: url),
                                           activate: bool(args, "activate") ?? false)
            try claimWorkspace(tab.id, for: context.id)
            guard workspaces.reserveDocumentOpening(for: tab.id) else {
                await workspaces.closeAndWait(tab.id)
                throw documentLimitFailure()
            }
            if migrationSource {
                await tab.session.openMigrations(at: url, version: string(args, "migration_version"))
            } else {
                await openDocument(tab.session, url)
            }
            workspaces.finishDocumentOpening(for: tab.id)
            guard workspaces.tabs.contains(where: { $0 === tab }) else {
                await tab.session.closeAndWait()
                throw Failure(code: "STALE_VIEW", detail: "The source tab closed while its document was opening.")
            }
            try requireWorkspaceOwnership(tab.id, contextID: context.id)
            do { try verifyContextUnchanged(context) } catch {
                await workspaces.closeAndWait(tab.id)
                throw error
            }
            guard tab.session.hasOpenDatabase || tab.session.schemaReview != nil else {
                let message = tab.session.presentedError?.message ?? tab.session.schemaPreviewReloadError ?? "The source did not open."
                await workspaces.closeAndWait(tab.id)
                throw Failure(code: "SOURCE_OPEN_FAILED", detail: message)
            }
            try bind(context.id, workspace: tab.id)
            return workspacePayload(tab)
        case "studio_create_workspace":
            guard let kind = WorkspaceTabKind(rawValue: string(args, "kind") ?? "workspace") else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "kind must be a supported workspace tab kind.")
            }
            let activate = string(args, "activation_intent") == "foreground" || bool(args, "activate") == true
            var sourceURL: URL?
            var migrationVersion: String?
            var sourceIsMigration = false
            if let requestedSource = string(args, "source_id") {
                guard let boundID = context.workspaceID,
                      let source = workspaces.tabs.first(where: { $0.id == boundID }),
                      sourceID(source) == requestedSource,
                      let url = source.session.databaseURL else {
                    throw Failure(code: "STALE_SOURCE", detail: "source_id must identify the live source in this coding task's bound workspace.")
                }
                sourceURL = url
                if case .migrations? = source.session.databaseTarget {
                    sourceIsMigration = true
                    migrationVersion = source.session.selectedMigrationVersion
                }
            }
            try requireAutomationWorkspaceCapacity(openingDocument: sourceURL != nil)
            let tab = workspaces.createTab(kind: kind, title: string(args, "title"), activate: activate)
            try claimWorkspace(tab.id, for: context.id)
            if let url = sourceURL {
                guard workspaces.reserveDocumentOpening(for: tab.id) else {
                    await workspaces.closeAndWait(tab.id)
                    throw documentLimitFailure()
                }
                if sourceIsMigration {
                    await tab.session.openMigrations(at: url, version: migrationVersion)
                } else {
                    await openDocument(tab.session, url)
                }
                workspaces.finishDocumentOpening(for: tab.id)
                guard workspaces.tabs.contains(where: { $0 === tab }) else {
                    await tab.session.closeAndWait()
                    throw Failure(code: "STALE_VIEW", detail: "The new workspace closed while its source was opening.")
                }
                try requireWorkspaceOwnership(tab.id, contextID: context.id)
                do { try verifyContextUnchanged(context) } catch {
                    await workspaces.closeAndWait(tab.id)
                    throw error
                }
                guard tab.session.hasOpenDatabase else {
                    let message = tab.session.presentedError?.message ?? "The source did not open."
                    await workspaces.closeAndWait(tab.id)
                    throw Failure(code: "SOURCE_OPEN_FAILED", detail: message)
                }
            }
            try bind(context.id, workspace: tab.id)
            return workspacePayload(tab)
        case "studio_update_workspace":
            let tab = try workspace(args, context: context)
            let changes = args["changes"] as? [String: Any] ?? args
            guard !changes.isEmpty, Set(changes.keys).isSubset(of: ["activate", "activation_intent"]),
                  bool(changes, "activate") == true || string(changes, "activation_intent") == "foreground" else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "This build supports only activate=true or activation_intent=foreground for workspace updates. Reconnect the task context to switch its bound workspace first.")
            }
            if bool(changes, "activate") == true || string(changes, "activation_intent") == "foreground" { workspaces.activate(tab.id) }
            return workspacePayload(tab)
        case "studio_close_workspace":
            let tab = try workspace(args, context: context)
            await workspaces.closeAndWait(tab.id)
            return ["closed_workspace_id": tab.id.uuidString,
                    "active_workspace_id": visibleActiveWorkspaceID(for: context.id)]
        case "studio_get_view":
            return viewPayload(try workspace(args, context: context))
        case "studio_set_layout":
            let tab = try workspace(args, context: context)
            let session = tab.session
            if let raw = args["left_pane"], !(raw is String) || string(args, "left_pane").flatMap(PaneContentKind.init(rawValue:)) == nil {
                throw Failure(code: "INVALID_ARGUMENT", detail: "left_pane must be schema, tables, or query.")
            }
            if let raw = args["right_pane"], !(raw is String) || string(args, "right_pane").flatMap(PaneContentKind.init(rawValue:)) == nil {
                throw Failure(code: "INVALID_ARGUMENT", detail: "right_pane must be schema, tables, or query.")
            }
            if let raw = args["maximize"], !(raw is String) || string(args, "maximize").flatMap(WorkspacePaneSide.init(rawValue:)) == nil {
                throw Failure(code: "INVALID_ARGUMENT", detail: "maximize must be left or right.")
            }
            if args["split_fraction"] != nil && (number(args, "split_fraction")?.isFinite != true) {
                throw Failure(code: "INVALID_ARGUMENT", detail: "split_fraction must be a finite number.")
            }
            guard args["left_pane"] != nil || args["right_pane"] != nil || args["split_fraction"] != nil || args["maximize"] != nil || bool(args, "restore_split") == true else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "Specify a pane, split_fraction, maximize, or restore_split=true.")
            }
            if let left = string(args, "left_pane"), let kind = PaneContentKind(rawValue: left) { session.setPaneContent(kind, for: .left) }
            if let right = string(args, "right_pane"), let kind = PaneContentKind(rawValue: right) { session.setPaneContent(kind, for: .right) }
            if let fraction = number(args, "split_fraction") { session.workspaceSplitFraction = min(0.85, max(0.15, fraction)) }
            if let maximized = string(args, "maximize") { session.maximizedPaneSide = WorkspacePaneSide(rawValue: maximized) }
            if bool(args, "restore_split") == true { session.maximizedPaneSide = nil }
            session.markAutomationViewChanged()
            return viewPayload(tab)
        case "studio_capture_view":
            let tab = try workspace(args, context: context)
            let id = captureView(tab)
            return ["checkpoint_id": id, "workspace_id": tab.id.uuidString, "view_revision": viewRevision(tab)]
        case "studio_restore_view":
            let tab = try workspace(args, context: context)
            try restoreView(try requiredString(args, "checkpoint_id"), in: tab)
            return viewPayload(tab)
        case "studio_search_schema":
            let tab = try sourceWorkspace(args, context: context)
            let needle = (string(args, "text") ?? string(args, "query") ?? "").lowercased()
            guard !needle.isEmpty else { throw Failure(code: "INVALID_ARGUMENT", detail: "Provide text to search the schema.") }
            let limit = bounded(args, "limit", default: 40, maximum: 100)
            let tableMatches = tab.session.tables.filter { $0.name.lowercased().contains(needle) || (tab.session.tableDescription(for: $0.name) ?? "").lowercased().contains(needle) }
            var matches: [[String: Any]] = tableMatches.map { ["kind": "table", "id": $0.id, "name": $0.name, "description": nullable(tab.session.tableDescription(for: $0.name))] }
            for table in tab.session.tables {
                guard let descriptor = tab.session.descriptor(named: table.id) else { continue }
                for column in descriptor.columns where column.name.lowercased().contains(needle) || (tab.session.columnDescription(for: table.id, column: column.name) ?? "").lowercased().contains(needle) {
                    matches.append(["kind": "column", "id": table.id + "." + column.name, "table_id": table.id, "name": column.name,
                                    "description": nullable(tab.session.columnDescription(for: table.id, column: column.name))])
                }
            }
            return ["source_id": sourceID(tab), "source_revision": sourceRevision(tab), "matches": Array(matches.prefix(limit)), "truncated": matches.count > limit]
        case "studio_describe_schema":
            let tab = try sourceWorkspace(args, context: context)
            let requested = strings(args, "object_ids") ?? strings(args, "table_ids")
            let names = requested ?? tab.session.tables.map(\.id)
            let limit = bounded(args, "limit", default: requested == nil ? 40 : 100, maximum: 100)
            let tables = names.prefix(limit).compactMap { id -> [String: Any]? in
                guard let descriptor = tab.session.descriptor(named: id) else { return nil }
                return descriptorPayload(descriptor, session: tab.session)
            }
            return ["source_id": sourceID(tab), "source_revision": sourceRevision(tab), "table_count": tab.session.tables.count,
                    "tables": tables, "truncated": names.count > limit]
        case "studio_find_relations":
            let tab = try sourceWorkspace(args, context: context)
            let seeds = Set(strings(args, "table_ids") ?? strings(args, "seeds") ?? [])
            guard !seeds.isEmpty else { throw Failure(code: "INVALID_ARGUMENT", detail: "Provide one or more table_ids to find declared relationships.") }
            guard seeds.isSubset(of: Set(tab.session.graph.nodes.map(\.id))) else {
                throw Failure(code: "OBJECT_NOT_FOUND", detail: "One or more seed table IDs do not exist in this source.")
            }
            let hops = bounded(args, "hops", default: 1, maximum: 5)
            var visited = seeds
            var frontier = seeds
            for _ in 0..<hops {
                frontier = Set(frontier.flatMap { tab.session.graph.neighbors(of: $0) }).subtracting(visited)
                visited.formUnion(frontier)
                if frontier.isEmpty { break }
            }
            let edges = tab.session.graph.edges.filter { visited.contains($0.sourceID) && visited.contains($0.targetID) }
            return ["source_id": sourceID(tab), "table_ids": visited.sorted(),
                    "declared_relationships": edges.map { edgePayload($0, recordRelationships: tab.session.records.relationships) },
                    "warning": "Only declared database relationships are shown; proximity and names do not create an edge. Use record_relation_id, when present, for studio_follow_record or studio_show_record_graph; id is the graph-edge ID used by studio_focus_keys."]
        case "studio_refresh_source":
            let tab = try sourceWorkspace(args, context: context)
            viewAnnotations.clear(nil, in: tab.id)
            annotationSourceByWorkspace.removeValue(forKey: tab.id)
            cancelQueryJobs(workspaceID: tab.id)
            for job in exportJobs.values where job.workspaceID == tab.id && (job.status == "queued" || job.status == "running") {
                job.cancellation.cancel()
                job.task?.cancel()
            }
            results = results.filter { $0.value.workspace != tab.id }
            checkpoints = checkpoints.filter { $0.value.workspace != tab.id }
            if let id = currentPresentationIDByWorkspace[tab.id], let state = presentations[id] {
                state.controller.end()
                presentationTasks[id]?.cancel()
                clearHistoricalReplaySelection(for: state)
            }
            tab.session.refreshSchema()
            tab.session.markAutomationViewChanged()
            return ["workspace_id": tab.id.uuidString, "status": "refresh_started", "source_id": sourceID(tab)]
        case "studio_show_tables":
            let tab = try workspace(args, context: context)
            let session = tab.session
            let valid = Set(session.graph.nodes.map(\.id))
            let requested = Set(strings(args, "table_ids") ?? [])
            guard requested.isSubset(of: valid) else { throw Failure(code: "OBJECT_NOT_FOUND", detail: "One or more table IDs do not exist in this source.") }
            let operation = string(args, "operation") ?? "replace"
            let prior = session.automationVisibleTableIDs ?? valid
            let next: Set<String>?
            switch operation {
            case "all": next = nil
            case "replace": next = requested
            case "add": next = prior.union(requested)
            case "remove": next = prior.subtracting(requested)
            default: throw Failure(code: "INVALID_ARGUMENT", detail: "operation must be replace, add, remove, or all.")
            }
            session.requestAutomationFocusReset()
            session.setAutomationVisibleTableIDs(next)
            compactSparseAutomationSubset(session)
            session.revealSchemaForAutomation()
            session.requestAutomationViewport(fitVisibleTables: true)
            session.markAutomationViewChanged()
            return ["workspace_id": tab.id.uuidString, "visible_table_ids": session.graphVisibleTableIDs.sorted(), "view_revision": viewRevision(tab),
                    "visual_state": visualState(tab)]
        case "studio_select_objects":
            let tab = try workspace(args, context: context)
            let ids = Set(strings(args, "table_ids") ?? strings(args, "object_ids") ?? [])
            guard ids.isSubset(of: Set(tab.session.graph.nodes.map(\.id))) else { throw Failure(code: "OBJECT_NOT_FOUND", detail: "One or more selected table IDs do not exist.") }
            tab.session.setGraphSelection(ids)
            tab.session.revealSchemaForAutomation()
            tab.session.markAutomationViewChanged()
            return viewPayload(tab)
        case "studio_expand_tables":
            let tab = try workspace(args, context: context)
            let ids = Set(strings(args, "table_ids") ?? [])
            guard ids.isSubset(of: Set(tab.session.graph.nodes.map(\.id))) else { throw Failure(code: "OBJECT_NOT_FOUND", detail: "One or more table IDs do not exist.") }
            let operation = string(args, "operation") ?? "replace"
            switch operation {
            case "replace": tab.session.expandedGraphNodeIDs = ids
            case "add": tab.session.expandedGraphNodeIDs.formUnion(ids)
            case "remove": tab.session.expandedGraphNodeIDs.subtract(ids)
            case "collapse_all": tab.session.expandedGraphNodeIDs.removeAll()
            default: throw Failure(code: "INVALID_ARGUMENT", detail: "Invalid table expansion operation.")
            }
            tab.session.revealSchemaForAutomation()
            tab.session.requestAutomationViewport(fitVisibleTables: true)
            tab.session.markAutomationViewChanged()
            return viewPayload(tab)
        case "studio_focus_keys":
            let tab = try sourceWorkspace(args, context: context)
            let graph = tab.session.graph
            let tableIDs = Set(strings(args, "table_ids") ?? [])
            let relationIDs = Set(strings(args, "relation_ids") ?? [])
            let keyIDs = Set(strings(args, "key_ids") ?? [])
            guard tableIDs.isSubset(of: Set(graph.nodes.map(\.id))) else {
                throw Failure(code: "OBJECT_NOT_FOUND", detail: "A requested table does not exist in this source.")
            }
            guard relationIDs.isSubset(of: Set(graph.edges.map(\.id))) else {
                throw Failure(code: "OBJECT_NOT_FOUND", detail: "A requested relation is not a declared database relationship.")
            }
            let edgeKeys = Set(graph.edges.flatMap { [$0.sourceID + "." + $0.sourceColumn,
                                                       $0.targetID + "." + $0.targetColumn] })
            guard keyIDs.isSubset(of: edgeKeys) else {
                throw Failure(code: "OBJECT_NOT_FOUND", detail: "A requested key is not part of a declared database relationship.")
            }
            let direction = string(args, "direction") ?? "both"
            guard ["both", "incoming", "outgoing"].contains(direction) else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "direction must be incoming, outgoing, or both.")
            }
            let selectedEdges = graph.edges.filter { edge in
                if relationIDs.contains(edge.id) { return true }
                if keyIDs.contains(edge.sourceID + "." + edge.sourceColumn)
                    || keyIDs.contains(edge.targetID + "." + edge.targetColumn) { return true }
                guard bool(args, "include_all_neighbors") == true else { return false }
                if direction == "incoming" { return tableIDs.contains(edge.targetID) }
                if direction == "outgoing" { return tableIDs.contains(edge.sourceID) }
                return tableIDs.contains(edge.sourceID) || tableIDs.contains(edge.targetID)
            }
            let connected = Set(selectedEdges.flatMap { [$0.sourceID, $0.targetID] })
            let chosen = tableIDs.union(connected)
            guard !chosen.isEmpty else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "Provide table_ids, relation_ids, or key_ids to focus.")
            }
            let session = tab.session
            session.setAutomationVisibleTableIDs(chosen)
            session.expandedGraphNodeIDs = chosen
            session.setGraphSelection(tableIDs.isEmpty ? connected : tableIDs)
            if bool(args, "compact_layout") == true {
                session.compactGraphTables(chosen.sorted())
            }
            if let edge = selectedEdges.first {
                session.setAutomationFocusCommand(AutomationGraphFocusCommand(tableID: edge.sourceID,
                    sourceColumn: edge.sourceColumn, targetColumn: edge.targetColumn, relationID: edge.id))
            } else if let tableID = chosen.sorted().first {
                session.setAutomationFocusCommand(AutomationGraphFocusCommand(tableID: tableID))
            }
            session.revealSchemaForAutomation()
            session.markAutomationViewChanged()
            return ["workspace_id": tab.id.uuidString, "visible_table_ids": chosen.sorted(),
                    "declared_relationships": graph.edges.filter { chosen.contains($0.sourceID) && chosen.contains($0.targetID) }.map { edgePayload($0, recordRelationships: tab.session.records.relationships) },
                    "view_revision": viewRevision(tab), "visual_state": visualState(tab)]
        case "studio_set_camera":
            let tab = try workspace(args, context: context)
            let transitionMilliseconds = try cameraTransitionMilliseconds(args)
            let mode = string(args, "mode") ?? "absolute"
            guard ["absolute", "fit_visible"].contains(mode) else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "mode must be absolute or fit_visible.")
            }
            guard mode == "fit_visible" || args["zoom"] != nil || args["pan_x"] != nil || args["pan_y"] != nil else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "Specify zoom or both pan_x and pan_y, or mode=fit_visible.")
            }
            guard mode != "fit_visible" || (args["zoom"] == nil && args["pan_x"] == nil && args["pan_y"] == nil) else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "fit_visible cannot be combined with explicit camera coordinates.")
            }
            guard (args["pan_x"] == nil) == (args["pan_y"] == nil) else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "pan_x and pan_y must be supplied together.")
            }
            for key in ["zoom", "pan_x", "pan_y"] where args[key] != nil {
                guard let value = number(args, key), value.isFinite else {
                    throw Failure(code: "INVALID_ARGUMENT", detail: "\(key) must be a finite number.")
                }
                if key != "zoom", abs(value) > 1_000_000 {
                    throw Failure(code: "INVALID_ARGUMENT", detail: "\(key) must be within the graph's usable coordinate range of -1,000,000 to 1,000,000.")
                }
            }
            if let zoom = number(args, "zoom") { tab.session.graphZoom = min(4, max(0.2, zoom)) }
            if let x = number(args, "pan_x"), let y = number(args, "pan_y") { tab.session.graphPan = CGSize(width: x, height: y) }
            tab.session.revealSchemaForAutomation()
            tab.session.requestAutomationViewport(fitVisibleTables: mode == "fit_visible",
                                                  transitionMilliseconds: transitionMilliseconds)
            tab.session.markAutomationViewChanged()
            return viewPayload(tab)
        case "studio_arrange_tables":
            let tab = try workspace(args, context: context)
            let ids = strings(args, "table_ids") ?? []
            guard ids.allSatisfy({ tab.session.graph.contains(nodeID: $0) }) else { throw Failure(code: "OBJECT_NOT_FOUND", detail: "One or more table IDs do not exist.") }
            let mode = string(args, "operation") ?? "compact"
            for key in ["x", "y"] where args[key] != nil {
                guard let value = number(args, key), value.isFinite, abs(value) <= 1_000_000 else {
                    throw Failure(code: "INVALID_ARGUMENT", detail: "\(key) must be a finite graph coordinate between -1,000,000 and 1,000,000.")
                }
            }
            if mode == "compact" {
                guard !ids.isEmpty else {
                    throw Failure(code: "INVALID_ARGUMENT", detail: "Compact needs at least one table ID.")
                }
                guard Set(ids).count == ids.count else {
                    throw Failure(code: "INVALID_ARGUMENT", detail: "Compact table IDs must be unique.")
                }
                let midpoint = CGPoint(x: number(args, "x") ?? 0, y: number(args, "y") ?? 0)
                tab.session.compactGraphTables(ids, around: midpoint)
            } else if mode == "position", ids.count == 1, let id = ids.first,
                      let x = number(args, "x"), let y = number(args, "y") {
                tab.session.graphLayout.pin(nodeID: id, at: CGPoint(x: x, y: y))
            } else if mode == "relayout" {
                tab.session.graphLayout.relayout(for: tab.session.graph)
            } else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "Use compact, position, or relayout with the required table IDs and coordinates.")
            }
            tab.session.revealSchemaForAutomation()
            if mode == "compact" { tab.session.requestAutomationViewport(fitVisibleTables: true) }
            tab.session.markAutomationViewChanged()
            return ["workspace_id": tab.id.uuidString, "positions": positionPayload(tab, ids: ids), "view_revision": viewRevision(tab)]
        case "studio_set_node_sizing":
            let tab = try workspace(args, context: context)
            guard let metric = string(args, "metric").flatMap(GraphNodeSizeMetric.init(rawValue:)) else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "Provide metric: uniform, fields, rows, or relations.")
            }
            tab.session.setGraphNodeSizeMetric(metric, persist: bool(args, "persist") == true)
            tab.session.revealSchemaForAutomation()
            tab.session.markAutomationViewChanged()
            return ["workspace_id": tab.id.uuidString, "metric": metric.rawValue,
                    "node_sizing_data": nodeSizingDataPayload(tab.session),
                    "view_revision": viewRevision(tab), "visual_state": visualState(tab)]
        case "studio_set_groups":
            let tab = try sourceWorkspace(args, context: context)
            let session = tab.session
            if bool(args, "restore_authored") == true {
                session.setAutomationGroups(nil)
            } else {
                guard let raw = args["groups"] as? [[String: Any]] else {
                    throw Failure(code: "INVALID_ARGUMENT", detail: "Provide groups or restore_authored.")
                }
                let incoming = try groupHints(raw, session: session)
                let operation = string(args, "operation") ?? "replace"
                switch operation {
                case "replace": session.setAutomationGroups(incoming)
                case "merge":
                    var combined = session.automationGroupHints ?? session.schemaSidecar.clusters
                    for hint in incoming {
                        if let index = combined.firstIndex(where: { $0.id == hint.id }) { combined[index] = hint }
                        else { combined.append(hint) }
                    }
                    session.setAutomationGroups(combined)
                default: throw Failure(code: "INVALID_ARGUMENT", detail: "Group operation must be replace or merge.")
                }
            }
            session.revealSchemaForAutomation()
            session.markAutomationViewChanged()
            return ["workspace_id": tab.id.uuidString, "temporary": session.automationGroupHints != nil,
                    "groups": groupPayload(session), "view_revision": viewRevision(tab), "visual_state": visualState(tab)]
        case "studio_annotate_view":
            let tab = try workspace(args, context: context)
            let operation = string(args, "operation") ?? "add"
            switch operation {
            case "clear":
                if args["annotation_ids"] != nil && strings(args, "annotation_ids") == nil {
                    throw Failure(code: "INVALID_ARGUMENT", detail: "annotation_ids must be a list of note IDs.")
                }
                viewAnnotations.clear(strings(args, "annotation_ids").map(Set.init), in: tab.id)
            case "add", "replace":
                let raw: [[String: Any]]
                if let entries = args["annotations"] as? [[String: Any]] {
                    raw = entries
                } else if args["annotations"] != nil {
                    throw Failure(code: "INVALID_ARGUMENT", detail: "annotations must be a list of plain-text notes.")
                } else if let text = string(args, "text") {
                    raw = [["id": string(args, "annotation_id") ?? UUID().uuidString,
                            "text": text,
                            "anchors": args["anchors"] ?? [],
                            "evidence_refs": args["evidence_refs"] ?? []]]
                } else {
                    throw Failure(code: "INVALID_ARGUMENT", detail: "Provide annotations or one text note.")
                }
                let tableIDs = Set(tab.session.graph.nodes.map(\.id))
                let columnsByTable = Dictionary(uniqueKeysWithValues: tableIDs.map { id in
                    (id, Set(tab.session.descriptor(named: id)?.columns.map(\.name) ?? []))
                })
                let parsed: [LiveViewAnnotation]
                do {
                    parsed = try LiveViewAnnotation.parse(raw, validTableIDs: tableIDs,
                                                          columnsByTable: columnsByTable)
                } catch {
                    throw Failure(code: "INVALID_ARGUMENT", detail: error.localizedDescription)
                }
                if operation == "replace" {
                    viewAnnotations.replace(parsed, in: tab.id)
                } else {
                    let existing = viewAnnotations.annotations(in: tab.id)
                    let existingIDs = Set(existing.map(\.id))
                    guard existing.count + parsed.filter({ !existingIDs.contains($0.id) }).count <= 20 else {
                        throw Failure(code: "LIMIT_REACHED", detail: "A view can contain at most 20 temporary notes.")
                    }
                    viewAnnotations.add(parsed, in: tab.id)
                }
                annotationSourceByWorkspace[tab.id] = sourceID(tab)
            default:
                throw Failure(code: "INVALID_ARGUMENT", detail: "operation must be add, replace, or clear.")
            }
            if viewAnnotations.annotations(in: tab.id).isEmpty {
                annotationSourceByWorkspace.removeValue(forKey: tab.id)
            }
            tab.session.markAutomationViewChanged()
            return ["workspace_id": tab.id.uuidString,
                    "annotations": viewAnnotations.annotations(in: tab.id).map(\.payload),
                    "temporary": true, "view_revision": viewRevision(tab),
                    "visual_state": visualState(tab)]
        case "studio_open_table":
            let tab = try sourceWorkspace(args, context: context)
            let name = try requiredString(args, "table_id", alternative: "table_name")
            guard let table = tab.session.openTable(named: name, autoLoad: false) else {
                throw Failure(code: "OBJECT_NOT_FOUND", detail: "That table or view was not found in the selected source.")
            }
            tab.session.revealSchemaForAutomation()
            tab.session.revealPaneForAutomation(.tables)
            if let visible = tab.session.automationVisibleTableIDs, !visible.contains(name) {
                tab.session.setAutomationVisibleTableIDs(visible.union([name]))
                tab.session.requestAutomationViewport(fitVisibleTables: true)
            }
            tab.session.selectGraphNode(name)
            tab.session.markAutomationViewChanged()
            if tab.session.databaseCapabilities.canBrowseRows { await table.reload() }
            return tablePayload(table, workspace: tab)
        case "studio_configure_table":
            let tab = try sourceWorkspace(args, context: context)
            try requireRows(in: tab)
            let name = try requiredString(args, "table_id", alternative: "table_name")
            guard let table = tab.session.openTable(named: name, autoLoad: false) else { throw Failure(code: "OBJECT_NOT_FOUND", detail: "Table not found.") }
            tab.session.revealPaneForAutomation(.tables)
            var state = table.queryState
            if let search = string(args, "search_text") { state.searchText = search }
            if let page = args["page_size"] as? Int { state.limit = min(500, max(1, page)) }
            if let filters = args["filters"] as? [[String: Any]] {
                state.columnFilters = try filters.map { filter in
                    let column = try requiredString(filter, "column_name")
                    guard table.descriptor.columns.contains(where: { $0.name == column }) else { throw Failure(code: "OBJECT_NOT_FOUND", detail: "Unknown filter column \(column).") }
                    guard let comparison = ColumnFilterComparison(rawValue: string(filter, "comparison") ?? "equal") else {
                        throw Failure(code: "INVALID_ARGUMENT", detail: "Unknown filter comparison.")
                    }
                    return ColumnFilter(columnName: column, value: string(filter, "value") ?? "", comparison: comparison,
                                        upperValue: string(filter, "upper_value"))
                }
            }
            if let sortItems = args["sort"] as? [[String: Any]] {
                guard sortItems.count <= 1 else {
                    throw Failure(code: "TOOL_UNAVAILABLE", detail: "The current table grid supports one sort column. Use a read-only ORDER BY query for a multi-column sort.")
                }
                if let sort = sortItems.first {
                    let column = try requiredString(sort, "column_name")
                    guard table.descriptor.columns.contains(where: { $0.name == column }) else { throw Failure(code: "OBJECT_NOT_FOUND", detail: "Unknown sort column \(column).") }
                    let direction = string(sort, "direction") ?? "ascending"
                    guard ["ascending", "descending"].contains(direction) else {
                        throw Failure(code: "INVALID_ARGUMENT", detail: "Sort direction must be ascending or descending.")
                    }
                    state.sort = SortState(columnName: column, direction: direction == "descending" ? .descending : .ascending)
                } else {
                    state.sort = nil
                }
            }
            state.offset = 0
            table.queryState = state
            await table.reload()
            return tablePayload(table, workspace: tab)
        case "studio_fetch_rows":
            let tab = try sourceWorkspace(args, context: context)
            let expectedSourceID = sourceID(tab)
            let expectedSourceRevision = sourceRevision(tab)
            let name = try requiredString(args, "table_id", alternative: "table_name")
            let reader = try await readOnlyService(for: tab)
            let descriptor = try await reader.fetchDescriptor(named: name)
            let limit = bounded(args, "limit", default: 100, maximum: 500)
            let offset = max(0, args["offset"] as? Int ?? 0)
            let filters = try (args["filters"] as? [[String: Any]] ?? []).map { filter in
                let column = try requiredString(filter, "column_name")
                guard descriptor.columns.contains(where: { $0.name == column }) else { throw Failure(code: "OBJECT_NOT_FOUND", detail: "Unknown filter column \(column).") }
                guard let comparison = ColumnFilterComparison(rawValue: string(filter, "comparison") ?? "equal") else {
                    throw Failure(code: "INVALID_ARGUMENT", detail: "Unknown filter comparison.")
                }
                return ColumnFilter(columnName: column, value: string(filter, "value") ?? "", comparison: comparison,
                                    upperValue: string(filter, "upper_value"))
            }
            let sortItems = args["sort"] as? [[String: Any]] ?? []
            guard sortItems.count <= 1 else { throw Failure(code: "TOOL_UNAVAILABLE", detail: "Use a read-only ORDER BY query for multi-column sort.") }
            let sort: SortState?
            if let item = sortItems.first {
                let column = try requiredString(item, "column_name")
                guard descriptor.columns.contains(where: { $0.name == column }) else { throw Failure(code: "OBJECT_NOT_FOUND", detail: "Unknown sort column \(column).") }
                let direction = string(item, "direction") ?? "ascending"
                guard ["ascending", "descending"].contains(direction) else {
                    throw Failure(code: "INVALID_ARGUMENT", detail: "Sort direction must be ascending or descending.")
                }
                sort = SortState(columnName: column, direction: direction == "descending" ? .descending : .ascending)
            } else { sort = nil }
            let requestedColumns = strings(args, "column_ids")
            let selectedColumns = requestedColumns ?? descriptor.columns.map(\.name)
            guard !selectedColumns.isEmpty, Set(selectedColumns).count == selectedColumns.count,
                  Set(selectedColumns).isSubset(of: Set(descriptor.columns.map(\.name))) else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "column_ids must be distinct columns in this table.")
            }
            var query = TableQueryState(searchText: string(args, "search_text") ?? "", columnFilters: filters, sort: sort,
                                        offset: offset, limit: limit)
            query.projectedColumns = requestedColumns
            let chunk = try await reader.fetchChunk(query: query, descriptor: descriptor)
            try verifySource(tab, id: expectedSourceID, revision: expectedSourceRevision, context: context)
            return ["source_id": sourceID(tab), "table_id": name, "source_revision": sourceRevision(tab), "offset": chunk.offset,
                    "limit": chunk.limit, "has_more": chunk.hasMore,
                    "columns": selectedColumns,
                    "rows": chunk.rows.enumerated().map { index, row in
                        ["index": chunk.offset + index, "values": row.values.map(valuePayload)] as [String: Any]
                    }]
        case "studio_inspect_value":
            let tab = try sourceWorkspace(args, context: context)
            let expectedSourceID = sourceID(tab)
            let expectedSourceRevision = sourceRevision(tab)
            let name = try requiredString(args, "table_id", alternative: "table_name")
            let column = try requiredString(args, "column_name")
            let rowIndex = args["row_index"] as? Int ?? 0
            guard rowIndex >= 0 else { throw Failure(code: "INVALID_ARGUMENT", detail: "row_index must be zero or greater.") }
            let reader = try await readOnlyService(for: tab)
            let descriptor = try await reader.fetchDescriptor(named: name)
            guard let columnIndex = descriptor.columns.firstIndex(where: { $0.name == column }) else {
                throw Failure(code: "OBJECT_NOT_FOUND", detail: "That column does not exist in \(name).")
            }
            let displayIntent = string(args, "display_intent") ?? "data"
            guard ["data", "show"].contains(displayIntent) else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "display_intent must be data or show.")
            }
            if let expectedRevision = string(args, "expected_view_revision"), expectedRevision != viewRevision(tab) {
                throw Failure(code: "STALE_VIEW", detail: "The displayed view changed. Read the current view before using its row offset.")
            }
            var rowQuery = tab.session.openTabs.first(where: { $0.descriptor.name == name })?.queryState ?? TableQueryState()
            rowQuery.offset = rowIndex
            rowQuery.limit = 1
            rowQuery.after = nil
            rowQuery.cachedExactCount = nil
            if let valueOffset = args["value_offset"] as? Int, valueOffset < 0 {
                throw Failure(code: "INVALID_ARGUMENT", detail: "value_offset must be zero or greater.")
            }
            let valueOffset = args["value_offset"] as? Int ?? 0
            let maxLength = bounded(args, "max_length", default: 4_096, maximum: 65_536)
            let cellRead = try await reader.readBoundedCell(query: rowQuery, descriptor: descriptor, columnName: column,
                                                           offset: valueOffset, length: maxLength)
            try verifySource(tab, id: expectedSourceID, revision: expectedSourceRevision, context: context)
            guard let cellRead else {
                throw Failure(code: "OBJECT_NOT_FOUND", detail: "There is no row at that offset. Choose a stable record identity for a repeatable inspection.")
            }
            if displayIntent == "show" {
                let snapshot = RecordSnapshot(
                    descriptor: descriptor,
                    columns: [QueryResultColumn(name: column, typeLabel: descriptor.columns[columnIndex].typeLabel)],
                    values: [cellRead.value], identity: nil, label: "\(name) · row \(rowIndex + 1)", partialCellRead: cellRead
                )
                tab.session.records.open(snapshot)
                tab.session.records.originLabel = "\(name) · row \(rowIndex + 1) · \(column)"
            }
            return ["source_id": sourceID(tab), "table_id": name, "column_name": column,
                    "row_index": rowIndex, "storage_type": cellRead.storageType,
                    "value": boundedCellPayload(cellRead), "value_offset": valueOffset,
                    "offset_unit": cellRead.offsetUnit, "returned_length": cellRead.returnedLength,
                    "character_count": nullable(cellRead.characterCount), "byte_count": nullable(cellRead.byteCount),
                    "has_more": cellRead.hasMore, "truncated": !cellRead.isComplete,
                    "complete": cellRead.isComplete, "display_intent": displayIntent,
                    "inspector_visible": displayIntent == "show" && workspaces.activeTabID == tab.id && hasVisibleAppWindow,
                    "warning": "The row offset uses the open table's current filters and sort. Row offsets can change after source edits or a view change; reopen the row before relying on this value."]

        case "studio_follow_record":
            let tab = try sourceWorkspace(args, context: context)
            let records = tab.session.records
            guard let current = records.current else {
                throw Failure(code: "RECORD_REQUIRED", detail: "Inspect a table or query record first, then follow a declared relationship.")
            }
            let mappingID = string(args, "mapping_id")
            let relationID = string(args, "relation_id")
            guard (mappingID == nil) != (relationID == nil) else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "Provide exactly one relation_id or mapping_id.")
            }
            if let requested = string(args, "record_id"), requested != current.id {
                throw Failure(code: "STALE_VIEW", detail: "The selected record changed. Inspect the current record before following it.")
            }
            guard (string(args, "display_intent") ?? "show") == "show" else {
                throw Failure(code: "TOOL_UNAVAILABLE", detail: "Record follow currently displays results in the inspector; use the read-only row or query tools for a data-only lookup.")
            }
            let direction = try recordDirections(args).first!
            if let mappingID {
                guard let mapping = records.mappings.first(where: { $0.id == mappingID }) else {
                    throw Failure(code: "OBJECT_NOT_FOUND", detail: "This application record mapping is unavailable.")
                }
                guard let task = records.loadMapping(mapping, direction: direction) else {
                    throw Failure(code: "BUSY", detail: records.notice ?? "A record relationship request is already running.")
                }
                await task.value
                let key = RecordExpansionKey(recordID: current.id, relationshipID: "mapping:" + mappingID, direction: direction)
                if let error = records.errors[key] { throw Failure(code: "OPERATION_FAILED", detail: error) }
                guard let page = records.mappedPages[key] else {
                    throw Failure(code: "OPERATION_FAILED", detail: "The application mapping returned no page.")
                }
                records.isPresented = true
                return ["workspace_id": tab.id.uuidString, "provenance": "application_mapping",
                        "mapping_id": mappingID, "record_id": current.id,
                        "connections": page.connections.map { ["edge_record_id": $0.edge.id, "source_record_id": $0.source.id,
                                                                "target_record_id": $0.target.id, "label": nullable($0.label)] as [String: Any] },
                        "has_more": page.hasMore, "next_offset": nullable(page.nextOffset), "messages": page.messages,
                        "visual_state": workspaces.activeTabID == tab.id && records.isPresented ? "inspector_visible" : "prepared_in_background"]
            }
            guard let relationID, let relation = records.relationships.first(where: { $0.id == relationID }) else {
                throw Failure(code: "OBJECT_NOT_FOUND", detail: "This relation is not declared in the current source.")
            }
            guard relationIsIncident(relation, to: current, direction: direction) else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "This relationship does not connect to the current record in the requested direction.")
            }
            guard let task = records.load(relation, direction: direction) else {
                throw Failure(code: "BUSY", detail: records.notice ?? "A record relationship request is already running.")
            }
            await task.value
            let key = RecordExpansionKey(recordID: current.id, relationshipID: relationID, direction: direction)
            if let error = records.errors[key] { throw Failure(code: "OPERATION_FAILED", detail: error) }
            guard let page = records.pages[key] else { throw Failure(code: "OPERATION_FAILED", detail: "No record page was returned.") }
            records.isPresented = true
            return ["workspace_id": tab.id.uuidString, "provenance": "declared_database_relation",
                    "relation_id": relationID, "record_id": current.id, "status": page.status.rawValue,
                    "records": page.records.map { ["record_id": $0.id, "table": $0.table?.displayName ?? "", "label": $0.label,
                                                      "stable_identity": $0.identity != nil] as [String: Any] },
                    "has_more": page.hasMore, "next_offset": nullable(page.nextOffset),
                    "visual_state": workspaces.activeTabID == tab.id && records.isPresented ? "inspector_visible" : "prepared_in_background"]
        case "studio_list_record_mappings":
            let tab = try sourceWorkspace(args, context: context)
            let sidecarMappings = tab.session.schemaSidecar.recordGraphMappings
            let mappingID = string(args, "mapping_id")
            if let mappingID, mappingID.isEmpty {
                throw Failure(code: "INVALID_ARGUMENT", detail: "mapping_id must be a nonempty exact ID returned by this tool.")
            }
            if let mappingID, mappingID.utf8.count > 1_024 {
                throw Failure(code: "INVALID_ARGUMENT", detail: "mapping_id exceeds this tool's 1,024-byte exact-ID bound.")
            }
            let offset = args["offset"] as? Int ?? 0
            guard offset >= 0 else { throw Failure(code: "INVALID_ARGUMENT", detail: "offset must be zero or greater.") }
            let limit = args["limit"] as? Int ?? 5
            guard (1...5).contains(limit) else { throw Failure(code: "INVALID_ARGUMENT", detail: "limit must be between 1 and 5.") }

            let candidates: [(Int, RecordGraphMapping)]
            let selectedOffset: Int
            let total: Int
            if let mappingID {
                var matchCount = 0
                var selected = [(Int, RecordGraphMapping)]()
                for (index, mapping) in sidecarMappings.enumerated() where mapping.id == mappingID {
                    if matchCount >= offset && selected.count < limit { selected.append((index, mapping)) }
                    matchCount += 1
                }
                guard matchCount > 0 else {
                    throw Failure(code: "OBJECT_NOT_FOUND", detail: "No application record mapping has that exact mapping_id in this source sidecar.")
                }
                guard offset <= matchCount else { throw Failure(code: "INVALID_ARGUMENT", detail: "offset cannot exceed the number of mappings matching mapping_id.") }
                candidates = selected
                selectedOffset = offset
                total = matchCount
            } else {
                guard offset <= sidecarMappings.count else { throw Failure(code: "INVALID_ARGUMENT", detail: "offset cannot exceed the source's record_mapping_count.") }
                candidates = Array(sidecarMappings.enumerated().dropFirst(offset).prefix(limit).map { ($0.offset, $0.element) })
                selectedOffset = offset
                total = sidecarMappings.count
            }
            let mappingPayloads = candidates.map { index, mapping in
                let status: String
                let validationError: String?
                let hasDuplicateID = sidecarMappings[..<index].contains { $0.id == mapping.id }
                    || sidecarMappings[(index + 1)...].contains { $0.id == mapping.id }
                if hasDuplicateID {
                    status = "duplicate_mapping_id"
                    validationError = "This ID appears more than once in the sidecar, so studio_follow_record cannot identify one mapping unambiguously."
                } else {
                    do {
                        _ = try RecordGraphMappingAccess.validate(mapping: mapping, catalog: tab.session.records.catalog)
                        status = "usable"
                        validationError = nil
                    } catch {
                        status = "invalid"
                        validationError = error.localizedDescription
                    }
                }
                return recordGraphMappingPayload(mapping, index: index, status: status, validationError: validationError)
            }
            let hasMore = selectedOffset + candidates.count < total
            return ["source_id": sourceID(tab), "source_revision": sourceRevision(tab),
                    "provenance": "source_sidecar.recordGraphMappings", "mapping_id_filter": nullable(mappingID),
                    "offset": selectedOffset, "limit": limit, "total_count": total,
                    "mappings": mappingPayloads, "has_more": hasMore,
                    "next_offset": hasMore ? selectedOffset + candidates.count : NSNull(),
                    "read_only": true,
                    "guidance": "These are application-defined mappings from this source sidecar, not database-declared foreign keys. For a usable mapping, inspect a record from node_table and pass its exact mapping_id to studio_follow_record; do not invent a relation_id."]
        case "studio_show_record_graph":
            let tab = try sourceWorkspace(args, context: context)
            let records = tab.session.records
            guard let current = records.current, current.identity != nil else {
                throw Failure(code: "RECORD_REQUIRED", detail: "Inspect a record with a stable identity before showing its record graph.")
            }
            if let seeds = args["seed_records"] as? [[String: Any]],
               seeds.count != 1 || string(seeds[0], "record_id") != current.id {
                throw Failure(code: "TOOL_UNAVAILABLE", detail: "This build can graph the currently inspected record. Inspect the requested seed record first.")
            }
            var seenRelationIDs = Set<String>()
            let relationIDs = (strings(args, "relation_ids") ?? []).filter { seenRelationIDs.insert($0).inserted }
            guard Set(relationIDs).isSubset(of: Set(records.relationships.map(\.id))) else {
                throw Failure(code: "OBJECT_NOT_FOUND", detail: "The record graph can only expand declared relationships from this source.")
            }
            let directions = try recordDirections(args, allowBoth: true)
            for relationID in relationIDs {
                guard let relation = records.relationships.first(where: { $0.id == relationID }),
                      directions.contains(where: { relationIsIncident(relation, to: current, direction: $0) }) else {
                    throw Failure(code: "INVALID_ARGUMENT", detail: "A selected relation does not connect to the current record in the requested direction.")
                }
            }
            records.showConnections()
            records.isPresented = true
            var expanded: [String] = []
            var failures: [[String: String]] = []
            for relationID in relationIDs.prefix(8) {
                guard let relation = records.relationships.first(where: { $0.id == relationID }) else { continue }
                for direction in directions {
                    guard relationIsIncident(relation, to: current, direction: direction) else { continue }
                    guard let task = records.load(relation, direction: direction, intoGraph: true) else {
                        failures.append(["relation_id": relationID, "direction": direction.rawValue,
                                         "message": records.notice ?? records.recordGraph.limitMessage ?? "Expansion could not start."])
                        continue
                    }
                    await task.value
                    let key = RecordExpansionKey(recordID: current.id, relationshipID: relationID, direction: direction)
                    if let error = records.errors[key] {
                        failures.append(["relation_id": relationID, "direction": direction.rawValue, "message": error])
                    } else if records.pages[key] != nil {
                        expanded.append(relationID + ":" + direction.rawValue)
                    }
                }
            }
            return ["workspace_id": tab.id.uuidString, "root_record_id": current.id,
                    "expanded_relation_directions": expanded, "failures": failures,
                    "omitted_relation_count": max(0, relationIDs.count - 8),
                    "record_count": records.recordGraph.records.count,
                    "visual_state": workspaces.activeTabID == tab.id && records.isPresented && hasVisibleAppWindow ? "record_graph_visible" : "prepared_in_background"]
        case "studio_prepare_query":
            let tab = try sourceWorkspace(args, context: context)
            try requireQueries(in: tab)
            let sql = try requiredString(args, "sql")
            try validateAutomationSQL(sql)
            tab.session.openQuery(title: string(args, "title"), sqlText: sql)
            tab.session.revealPaneForAutomation(.query)
            return ["workspace_id": tab.id.uuidString, "query_id": nullable(tab.session.queryWorkspace.activeQueryID?.uuidString),
                    "status": "prepared_not_executed"]
        case "studio_run_query":
            let tab = try sourceWorkspace(args, context: context)
            try requireQueries(in: tab)
            let sql = try requiredString(args, "sql")
            try validateAutomationSQL(sql)
            let limit = bounded(args, "row_limit", default: 100, maximum: 500)
            let timeout = Int(min(30, max(1, number(args, "timeout_seconds") ?? (number(args, "timeout_ms").map { $0 / 1_000 }) ?? 30)))
            let jobID = "query:" + UUID().uuidString
            let job = QueryJobState(id: jobID, clientID: clientID, contextID: context.id,
                                    workspaceID: tab.id, sourceID: sourceID(tab),
                                    sourceRevision: sourceRevision(tab), sql: sql,
                                    title: string(args, "title"), rowLimit: limit,
                                    timeoutSeconds: timeout)
            queryJobs[jobID] = job
            job.task = Task { @MainActor [weak self] in
                await self?.performQueryJob(jobID)
            }
            return queryJobPayload(job)
        case "studio_explain_query":
            let tab = try sourceWorkspace(args, context: context)
            let expectedSourceID = sourceID(tab)
            let expectedSourceRevision = sourceRevision(tab)
            let sql = try requiredString(args, "sql")
            try validateAutomationSQL(sql)
            let reader = try await readOnlyService(for: tab)
            let plan = try await reader.explainQueryPlan(sql: sql)
            try verifySource(tab, id: expectedSourceID, revision: expectedSourceRevision, context: context)
            return ["source_id": sourceID(tab), "plan": plan.map { ["id": $0.id, "parent": $0.parent, "detail": $0.detail] }]
        case "studio_fetch_query_results", "studio_show_query_results":
            let tab = try workspace(args, context: context)
            let id = try requiredString(args, "result_id")
            guard let saved = results[id], saved.workspace == tab.id,
                  saved.ownerContextID == context.id else {
                throw Failure(code: "OBJECT_NOT_FOUND", detail: "That result is unavailable to this coding task in the selected workspace.")
            }
            guard saved.sourceID == sourceID(tab), saved.sourceRevision == sourceRevision(tab) else {
                results.removeValue(forKey: id)
                throw Failure(code: "STALE_SOURCE", detail: "The source changed after this result was captured. Run the query again against the current source.")
            }
            let offset = max(0, args["offset"] as? Int ?? 0)
            let limit = bounded(args, "limit", default: 100, maximum: 100)
            results[id] = (saved.workspace, saved.sql, saved.result, saved.sourceID, saved.sourceRevision,
                           offset, limit, saved.ownerClientID, saved.ownerContextID)
            if name == "studio_show_query_results" {
                tab.session.openQuery(title: string(args, "title"), sqlText: saved.sql)
                tab.session.revealPaneForAutomation(.query)
                if let index = tab.session.queryWorkspace.queries.firstIndex(where: { $0.id == tab.session.queryWorkspace.activeQueryID }) {
                    tab.session.queryWorkspace.queries[index].result = saved.result
                    tab.session.queryWorkspace.queries[index].executedSQL = saved.sql
                }
            }
            return queryPayload(saved.result, id: id, tab: tab,
                                offset: offset, limit: limit)
        case "studio_export":
            return try await startExport(args, context: context, clientID: clientID)
        case "studio_get_job":
            return try getJob(args, context: context, clientID: clientID)
        case "studio_cancel_job":
            return try await cancelJob(args, context: context, clientID: clientID)
        case "studio_get_speech":
            let activeNarrator = activeSpeechNarrator()
            let narrator = activeNarrator ?? StudioSpeechNarrator()
            let pocket = narrator.pocketTTSReadiness
            return ["available": narrator.isSpeechAvailable, "active_provider": narrator.speechProviderName,
                    "provider_id": narrator.speechProviderIdentifier, "streaming": true,
                    "provider_in_use": activeNarrator != nil,
                    "pocket_tts_ready": pocket.canUsePocketTTS,
                    "pocket_tts_download_available": pocket.canDownloadMissingAssets,
                    "pocket_tts_package_id": PocketTTSSpeechAssets.packageID,
                    "pocket_tts_asset_bytes": PocketTTSSpeechAssets.combinedDownloadSizeBytes,
                    "pocket_tts_status": pocket.explanation]
        case "studio_configure_speech":
            guard let settings = args["settings"] as? [String: Any], !settings.isEmpty else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "Provide settings.enabled as true or false.")
            }
            guard Set(settings.keys).isSubset(of: ["enabled", "narration"]) else {
                throw Failure(code: "TOOL_UNAVAILABLE", detail: "This build can enable or disable narration. Voice, provider and speed selection are not available.")
            }
            let enabled: Bool
            if let requestedEnabled = settings["enabled"] as? Bool {
                enabled = requestedEnabled
            } else if let narration = settings["narration"] as? String {
                switch narration.lowercased() {
                case "enabled", "on": enabled = true
                case "disabled", "off": enabled = false
                default: throw Failure(code: "INVALID_ARGUMENT", detail: "settings.narration must be enabled or disabled.")
                }
            } else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "Provide settings.enabled as true or false.")
            }
            if let named = settings["narration"] as? String {
                guard ["enabled", "on", "disabled", "off"].contains(named.lowercased()) else {
                    throw Failure(code: "INVALID_ARGUMENT", detail: "settings.narration must be enabled or disabled.")
                }
                if let explicit = settings["enabled"] as? Bool,
                   (named.lowercased() == "enabled" || named.lowercased() == "on") != explicit {
                    throw Failure(code: "INVALID_ARGUMENT", detail: "settings.enabled and settings.narration disagree.")
                }
            }
            let scope = string(args, "scope") ?? "general"
            guard ["general", "source", "temporary"].contains(scope) else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "scope must be general, source, or temporary.")
            }
            let persists = scope != "temporary" && bool(args, "durable") != false
            if persists {
                let key = scope == "source"
                    ? preferencesKey(for: try sourceWorkspace(args, context: context))
                    : "SQLiteGraphStudio.explanation-preferences.global"
                var saved = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
                saved["narration"] = enabled ? "enabled" : "disabled"
                UserDefaults.standard.set(saved, forKey: key)
            }
            return ["scope": scope, "narration_enabled": enabled, "persisted": persists,
                    "narration_mode_for_next_presentation": enabled ? "enabled" : "disabled",
                    "provider_id": "macos-av-speech",
                    "note": persists ? "The saved preference applies when narration_mode is app_default." : "Pass the returned narration_mode to the next presentation for this temporary choice."]
        case "studio_manage_speech_assets":
            return try await manageSpeechAssets(args, context: context, clientID: clientID)
        case "studio_test_speech":
            return try startSpeechTest(args, context: context, clientID: clientID)
        case "studio_get_preferences":
            let tab = try? workspace(args, context: context)
            let global = UserDefaults.standard.dictionary(forKey: "SQLiteGraphStudio.explanation-preferences.global") as? [String: String] ?? [:]
            let source = tab.map { UserDefaults.standard.dictionary(forKey: preferencesKey(for: $0)) as? [String: String] ?? [:] } ?? [:]
            let needsGlobal = global["technical_level"] == nil
            let needsSource = tab?.session.hasOpenDatabase == true && source["source_familiarity"] == nil
            return ["global": global, "source": source, "onboarding_required": needsGlobal || needsSource,
                    "onboarding_questions": (needsGlobal ? [["id": "technical_level", "question": "How familiar are you with databases?", "options": ["new", "some_experience", "experienced", "skip"]]] : []) +
                        (needsSource ? [["id": "source_familiarity", "question": "How familiar are you with this data model?", "options": ["new", "some_experience", "experienced", "skip"]]] : []),
                    "guidance": "Ask these short questions on first exploration. Save explicit answers, including skip, with studio_update_preferences so they are not asked repeatedly."]
        case "studio_update_preferences":
            let scope = string(args, "scope") ?? "global"
            guard let patch = args["preferences"] as? [String: String], !patch.isEmpty else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "Provide a nonempty preferences object with explicit user choices.")
            }
            guard Set(patch.keys).isSubset(of: ["technical_level", "source_familiarity", "detail", "pace", "narration", "language", "goal"]) else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "One or more preference keys are unsupported.")
            }
            guard scope == "global" || scope == "source" || scope == "this_answer" else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "scope must be global, source, or this_answer.")
            }
            if scope == "this_answer" { return ["scope": scope, "preferences": patch, "persisted": false] }
            let key: String
            if scope == "source" { key = preferencesKey(for: try sourceWorkspace(args, context: context)) }
            else { key = "SQLiteGraphStudio.explanation-preferences.global" }
            var saved = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
            saved.merge(patch) { _, new in new }
            UserDefaults.standard.set(saved, forKey: key)
            return ["scope": scope, "preferences": saved, "persisted": true]
        case "studio_get_annotations":
            let tab = try sourceWorkspace(args, context: context)
            guard let databaseURL = tab.session.databaseURL else {
                throw Failure(code: "SOURCE_REQUIRED", detail: "This source has no local metadata sidecar path.")
            }
            let snapshot = try SchemaSidecarStore.loadSnapshot(for: databaseURL)
            let sidecar = snapshot.sidecar
            let ids = Set(strings(args, "object_ids") ?? tab.session.tables.map(\.id))
            let descriptions = sidecar.tables.filter { ids.contains($0.key) }.mapValues { value in
                ["description": nullable(value.description), "columns": value.columns] as [String: Any]
            }
            let relevantRelations = Set(tab.session.graph.edges.filter { edge in
                ids.contains(edge.id) || ids.contains(edge.sourceID) || ids.contains(edge.targetID)
            }.map(\.id))
            let matchingNotes = sidecar.notes.filter { note in
                (note.tableID == nil && note.relationID == nil)
                    || note.tableID.map(ids.contains) == true
                    || note.relationID.map(relevantRelations.contains) == true
            }
            let noteOffset = args["note_offset"] as? Int ?? 0
            guard noteOffset >= 0, noteOffset <= matchingNotes.count else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "note_offset must be within the saved note count.")
            }
            let noteLimit = bounded(args, "note_limit", default: 25, maximum: 50)
            let visibleNotes = matchingNotes.dropFirst(noteOffset).prefix(noteLimit)
            return ["source_id": sourceID(tab), "descriptions": descriptions,
                    "clusters": sidecar.clusters.map { ["id": $0.id, "label": nullable($0.label), "table_ids": $0.tables, "color": nullable($0.color)] as [String: Any] },
                    "overview_table_ids": sidecar.overviewTables,
                    "active_groups": groupPayload(tab.session),
                    "record_mapping_count": sidecar.recordGraphMappings.count,
                    "metadata_revision": snapshot.revision,
                    "notes": visibleNotes.map { note in
                        ["id": note.id, "text": note.text, "table_id": nullable(note.tableID),
                         "column_name": nullable(note.columnName), "relation_id": nullable(note.relationID)] as [String: Any]
                    },
                    "note_offset": noteOffset, "note_count": matchingNotes.count,
                    "has_more_notes": noteOffset + visibleNotes.count < matchingNotes.count]
        case "studio_update_annotations":
            let tab = try sourceWorkspace(args, context: context)
            guard let databaseURL = tab.session.databaseURL else { throw Failure(code: "SOURCE_REQUIRED", detail: "This source has no local metadata sidecar path.") }
            let expectedRevision = try requiredString(args, "expected_metadata_revision")
            guard expectedRevision.count == 64, expectedRevision.utf8.allSatisfy({ byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }) else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "expected_metadata_revision must be the 64-character value returned by studio_get_annotations.")
            }
            let updates = args["tables"] as? [String: [String: Any]] ?? [:]
            let rawGroups = args["groups"] as? [[String: Any]]
            let overviewTableIDs = strings(args, "overview_table_ids")
            let rawNotes = args["notes_upsert"] as? [[String: Any]]
            let removedNoteIDs = strings(args, "note_ids_remove")
            guard args["overview_table_ids"] == nil || overviewTableIDs != nil else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "overview_table_ids must be a list of exact table IDs.")
            }
            guard !updates.isEmpty || rawGroups != nil || overviewTableIDs != nil || rawNotes != nil || removedNoteIDs != nil else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "Provide table descriptions, groups, overview tables, or saved note changes.")
            }
            let snapshot = try SchemaSidecarStore.loadSnapshot(for: databaseURL)
            guard snapshot.revision == expectedRevision else {
                throw Failure(code: "METADATA_CONFLICT", detail: "Metadata changed since this coding task read it. Call studio_get_annotations and retry with its new metadata_revision and a new request_id.")
            }
            var sidecar = snapshot.sidecar
            for (tableID, update) in updates {
                guard let descriptor = tab.session.descriptor(named: tableID) else { throw Failure(code: "OBJECT_NOT_FOUND", detail: "Unknown table \(tableID).") }
                var description = sidecar.tables[tableID] ?? SchemaSidecar.TableDescription()
                if let text = update["description"] as? String { description.description = text }
                if let columns = update["columns"] as? [String: String] {
                    guard Set(columns.keys).isSubset(of: Set(descriptor.columns.map(\.name))) else {
                        throw Failure(code: "OBJECT_NOT_FOUND", detail: "One or more columns in \(tableID) do not exist.")
                    }
                    description.columns.merge(columns) { _, new in new }
                }
                sidecar.tables[tableID] = description
            }
            if let rawGroups { sidecar.clusters = try groupHints(rawGroups, session: tab.session) }
            if let overviewTableIDs {
                guard overviewTableIDs.count <= 16,
                      Set(overviewTableIDs).count == overviewTableIDs.count,
                      overviewTableIDs.allSatisfy({ tab.session.descriptor(named: $0) != nil }) else {
                    throw Failure(code: "INVALID_ARGUMENT", detail: "Choose at most 16 distinct overview tables from this source.")
                }
                sidecar.overviewTables = overviewTableIDs
            }
            if let rawNotes {
                guard rawNotes.count <= 100 else { throw Failure(code: "LIMIT_REACHED", detail: "Save at most 100 notes per update.") }
                var seen = Set<String>()
                for raw in rawNotes {
                    let id = try requiredString(raw, "id")
                    let text = try requiredString(raw, "text")
                    let tableID = string(raw, "table_id")
                    let columnName = string(raw, "column_name")
                    let relationID = string(raw, "relation_id")
                    guard seen.insert(id).inserted, id.count <= 200, text.count <= 4_000,
                          (tableID == nil || tab.session.descriptor(named: tableID!) != nil),
                          (columnName == nil || (tableID.flatMap { tab.session.descriptor(named: $0) }?.columns.contains { $0.name == columnName } == true)),
                          (relationID == nil || tab.session.graph.edges.contains { $0.id == relationID }) else {
                        throw Failure(code: "INVALID_ARGUMENT", detail: "A saved note has a duplicate ID, oversized text, or an unknown table, column, or declared relation.")
                    }
                    let note = SchemaSidecar.Note(id: id, text: text, tableID: tableID,
                                                  columnName: columnName, relationID: relationID)
                    if let index = sidecar.notes.firstIndex(where: { $0.id == id }) { sidecar.notes[index] = note }
                    else { sidecar.notes.append(note) }
                }
            }
            if let removedNoteIDs {
                guard removedNoteIDs.count <= 100, Set(removedNoteIDs).count == removedNoteIDs.count else {
                    throw Failure(code: "INVALID_ARGUMENT", detail: "Remove at most 100 distinct note IDs per update.")
                }
                sidecar.notes.removeAll { removedNoteIDs.contains($0.id) }
            }
            let revision: String
            do {
                revision = try SchemaSidecarStore.save(sidecar, for: databaseURL,
                                                       expectedRevision: expectedRevision)
            } catch SchemaMetadataError.conflict {
                throw Failure(code: "METADATA_CONFLICT", detail: "Metadata changed while this update was being saved. Call studio_get_annotations and retry with the new metadata_revision and a new request_id.")
            }
            tab.session.reloadSchemaSidecarFromDisk()
            tab.session.markAutomationViewChanged()
            return ["source_id": sourceID(tab), "updated_table_ids": updates.keys.sorted(),
                    "groups_saved": rawGroups != nil, "overview_tables_saved": overviewTableIDs != nil,
                    "notes_upserted": rawNotes?.map { $0["id"] as? String ?? "" } ?? [],
                    "notes_removed": removedNoteIDs ?? [], "metadata_revision": revision,
                    "metadata_status": "saved"]
        case "studio_capture_schema":
            let tab = try sourceWorkspace(args, context: context)
            guard let document = tab.session.databaseURL else { throw Failure(code: "SOURCE_REQUIRED", detail: "The current source has no capture document.") }
            let snapshot = try await SchemaReviewCapture.snapshot(document: document)
            let fingerprint = try SchemaPreview.fingerprint(snapshot)
            let destination = try artifactDestination(args, ext: "sgsnapshot")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(snapshot).write(to: destination, options: .atomic)
            let id = try registerArtifact(destination, context: context, fingerprint: fingerprint)
            return ["artifact_id": id, "path": destination.path, "kind": "captured_schema", "engine": snapshot.engine,
                    "fingerprint": fingerprint, "table_count": snapshot.tables.count, "relation_count": snapshot.relations.count,
                    "captured_from_source_id": sourceID(tab), "historical": true]
        case "studio_inspect_artifact":
            let url = try artifactURL(args, context: context)
            if url.pathExtension.lowercased() == "sgexplanation" {
                return try inspectHistoricalExplanation(url, args: args)
            }
            if url.pathExtension.lowercased() == "sgrefresh" {
                let draft = try HistoricalExplanationStore.loadRefreshDraft(url)
                let limit = bounded(args, "limit", default: 25, maximum: 25)
                let artifactID = string(args, "artifact_id") ?? url.path
                if string(args, "detail_scope") == "object" {
                    let objectID = try requiredString(args, "object_id")
                    if let table = draft.freshSchema.tables.first(where: { $0.id == objectID }) {
                        let pages = draft.tablePages.filter { $0.tableID == objectID }
                        let relations = draft.freshSchema.relations.filter {
                            $0.source == objectID || $0.target == objectID
                        }
                        return ["artifact_id": artifactID, "kind": "fresh_refresh_table",
                                "fresh_draft": true, "historical_narration_reused": false,
                                "source_identity_hash": draft.sourceIdentityHash,
                                "table_id": table.id, "name": table.displayName, "object_kind": table.kind,
                                "columns": table.columns.prefix(256).map { column in
                                    ["name": column.name, "type": column.type, "nullable": !column.notNull,
                                     "primary_key_ordinal": column.primaryKeyOrdinal,
                                     "generated": column.generated != 0, "identity": column.identity] as [String: Any]
                                },
                                "column_count": table.columns.count, "columns_truncated": table.columns.count > 256,
                                "relations": relations.prefix(limit).map { relation in
                                    ["id": relation.id, "source": relation.source, "target": relation.target,
                                     "source_columns": relation.sourceColumns, "target_columns": relation.targetColumns] as [String: Any]
                                }, "relation_count": relations.count,
                                "captured_pages": pages.prefix(limit).map { capturedPagePayload($0, limit: limit) },
                                "captured_page_count": pages.count,
                                "captured_row_count": pages.reduce(0) { $0 + $1.rows.count },
                                "captured_data": !pages.isEmpty,
                                "truncated": pages.count > limit]
                    }
                    if let result = draft.queryResults.first(where: { $0.resultID == objectID }) {
                        return ["artifact_id": artifactID, "kind": "fresh_refresh_query_result",
                                "fresh_draft": true, "result_id": result.resultID,
                                "columns": result.columns.prefix(64).map { ["name": $0.name, "type": $0.type] },
                                "rows": result.rows.prefix(limit).map { capturedRowPayload($0, maximumColumns: 64, maximumCellCharacters: 256) },
                                "displayed_offset": result.displayedOffset,
                                "omitted_rows": result.omittedRows + max(0, result.rows.count - limit),
                                "columns_truncated": result.columns.count > 64]
                    }
                    throw Failure(code: "OBJECT_NOT_FOUND", detail: "No fresh table or query result has that object_id.")
                }
                let needle = string(args, "search")?.lowercased()
                let tables = draft.freshSchema.tables.filter {
                    needle == nil || $0.id.lowercased().contains(needle!) || $0.name.lowercased().contains(needle!)
                }
                let changes = draft.schemaChanges.filter { needle == nil || $0.lowercased().contains(needle!) }
                return ["artifact_id": string(args, "artifact_id") ?? url.path, "kind": "historical_explanation_refresh_draft",
                        "title": draft.title, "prepared_at": draft.preparedAt.formatted(.iso8601),
                        "historical_narration_reused": false, "requires_rewritten_claims": true,
                        "prior_schema_fingerprint": draft.priorSchemaFingerprint,
                        "fresh_schema_fingerprint": draft.freshSchemaFingerprint,
                        "engine": draft.engine, "source_identity_hash": draft.sourceIdentityHash,
                        "tables": tables.prefix(limit).map { ["id": $0.id, "kind": $0.kind, "field_count": $0.columns.count] },
                        "table_count": tables.count, "tables_truncated": tables.count > limit,
                        "schema_changes": changes.prefix(limit), "schema_change_count": changes.count,
                        "captured_table_pages": draft.tablePages.map { ["table_id": $0.tableID, "offset": $0.displayedOffset] },
                        "captured_rows": draft.tablePages.reduce(0) { $0 + $1.rows.count },
                        "warnings": draft.warnings,
                        "truncated": tables.count > limit || changes.count > limit]
            }
            if url.pathExtension.lowercased() == "sgpreview" {
                let review = try SchemaReviewDocument.load(url)
                let needle = string(args, "search")?.lowercased()
                let exact = string(args, "object_id")
                let matches = review.changes.filter { change in
                    (exact == nil || change.id == exact) && (needle == nil || change.id.lowercased().contains(needle!))
                }
                let limit = bounded(args, "limit", default: 100, maximum: 500)
                return ["artifact_id": string(args, "artifact_id") ?? url.path, "kind": "proposed_schema",
                        "base_fingerprint": review.proposal?.baseFingerprint ?? "",
                        "tables": matches.prefix(limit).map { ["id": $0.id, "change": $0.kind.rawValue,
                                                                "columns": $0.table.columns.map { ["name": $0.name, "type": $0.type] }] as [String: Any] },
                        "truncated": matches.count > limit, "historical": false,
                        "warning": "This is a proposal. No migration was executed."]
            }
            let baseline = try SchemaPreview.loadBaseline(url, side: string(args, "side") ?? "after")
            let detail = string(args, "detail_scope") ?? "summary"
            let requested = detail == "object" ? [try requiredString(args, "object_id")] : []
            let inspected = try SchemaPreview.inspect(baseline, tables: requested, find: string(args, "search"),
                                                      limit: bounded(args, "limit", default: 100, maximum: 500))
            guard var payload = try JSONSerialization.jsonObject(with: inspected) as? [String: Any] else {
                throw Failure(code: "ARTIFACT_INVALID", detail: "The artifact could not be inspected.")
            }
            payload["artifact_id"] = string(args, "artifact_id") ?? url.path
            payload["historical"] = true
            return payload
        case "studio_update_preview":
            let fp = try requiredString(args, "baseline_fingerprint")
            let baselineURL: URL
            if let id = string(args, "baseline_artifact_id") { baselineURL = try artifactURL(["artifact_id": id], context: context) }
            else if let match = artifactFingerprints.first(where: { $0.value == fp && artifactOwners[$0.key] == context.id }), let url = artifacts[match.key] { baselineURL = url }
            else { throw Failure(code: "ARTIFACT_NOT_FOUND", detail: "Provide baseline_artifact_id or first capture a schema with this fingerprint.") }
            let baseline = try SchemaPreview.loadBaseline(baselineURL)
            guard try SchemaPreview.fingerprint(baseline.snapshot) == fp else {
                throw Failure(code: "STALE_SOURCE", detail: "The plan's baseline fingerprint does not match the captured schema.")
            }
            guard let plan = args["plan"] as? [String: Any] else { throw Failure(code: "INVALID_ARGUMENT", detail: "Provide a compact plan object.") }
            let review = try SchemaPreview.project(baseline, planData: JSONSerialization.data(withJSONObject: plan))
            let destination = try artifactDestination(args, ext: "sgpreview")
            try review.write(to: destination)
            let id = try registerArtifact(destination, context: context)
            return ["artifact_id": id, "path": destination.path, "kind": "proposed_schema", "base_fingerprint": fp,
                    "changed_table_ids": review.changes.filter { $0.kind != .unchanged }.map(\.id),
                    "warning": "This is a projected proposal. No migration was executed or validated against live data."]
        case "studio_compare_schemas":
            let before = try SchemaPreview.loadBaseline(artifactURL(["artifact_id": try requiredString(args, "before_snapshot")], context: context))
            let after = try SchemaPreview.loadBaseline(artifactURL(["artifact_id": try requiredString(args, "after_snapshot")], context: context))
            guard before.snapshot.engine == after.snapshot.engine else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "A real before/after comparison requires the same database engine.")
            }
            let review = SchemaReviewDocument(title: string(args, "title") ?? "Database changes", baseRef: before.label,
                                              headRef: after.label, before: before.snapshot, after: after.snapshot)
            let destination = try artifactDestination(args, ext: "sgreview")
            try review.write(to: destination)
            let id = try registerArtifact(destination, context: context)
            return ["artifact_id": id, "path": destination.path, "kind": "captured_schema_comparison",
                    "changed_table_ids": review.changes.filter { $0.kind != .unchanged }.map(\.id)]
        case "studio_show_artifact":
            let url = try artifactURL(args, context: context)
            guard ["sgreview", "sgpreview"].contains(url.pathExtension.lowercased()) else {
                throw Failure(code: "UNSUPPORTED_ARTIFACT", detail: "Open a comparison or proposal artifact; a raw snapshot can be inspected or compared first.")
            }
            try requireAutomationWorkspaceCapacity(openingDocument: true)
            let tab = workspaces.createTab(kind: inferredWorkspaceKind(for: url),
                                           activate: bool(args, "activate") ?? true)
            try claimWorkspace(tab.id, for: context.id)
            guard workspaces.reserveDocumentOpening(for: tab.id) else {
                await workspaces.closeAndWait(tab.id)
                throw documentLimitFailure()
            }
            await openDocument(tab.session, url)
            workspaces.finishDocumentOpening(for: tab.id)
            guard workspaces.tabs.contains(where: { $0 === tab }) else {
                await tab.session.closeAndWait()
                throw Failure(code: "STALE_VIEW", detail: "The artifact tab closed while its document was opening.")
            }
            try requireWorkspaceOwnership(tab.id, contextID: context.id)
            do { try verifyContextUnchanged(context) } catch {
                await workspaces.closeAndWait(tab.id)
                throw error
            }
            guard tab.session.schemaReview != nil else {
                let message = tab.session.presentedError?.message ?? "The schema artifact did not open."
                await workspaces.closeAndWait(tab.id)
                throw Failure(code: "ARTIFACT_INVALID", detail: message)
            }
            try bind(context.id, workspace: tab.id)
            return ["workspace_id": tab.id.uuidString, "artifact_id": string(args, "artifact_id") ?? url.path,
                    "path": url.path, "visual_state": visualState(tab), "historical_or_proposed": true]
        case "studio_save_explanation":
            let state = try presentation(args, context: context)
            if let requestedWorkspace = explicitWorkspace(args), requestedWorkspace != state.workspaceID {
                throw Failure(code: "INVALID_ARGUMENT", detail: "The requested workspace_id does not own this presentation.")
            }
            if bool(args, "cache_audio") == true {
                throw Failure(code: "TOOL_UNAVAILABLE", detail: "Cached narration audio is not included in this build. Captions, saved words, visual actions, evidence references, and selected rows can still be saved.")
            }
            guard let tab = workspaces.tabs.first(where: { $0.id == state.workspaceID }),
                  let documentURL = tab.session.databaseURL,
                  let target = tab.session.databaseTarget else {
                throw Failure(code: "SOURCE_REQUIRED", detail: "Save an explanation while its live source is open. A historical tab cannot be used to refresh or recapture its source.")
            }
            let pointsToSave = state.displayedPointOrder.compactMap { state.pointsByID[$0] }
            guard !pointsToSave.isEmpty else {
                throw Failure(code: "NO_DISPLAYED_POINTS", detail: "Only points that reached the visible workspace can be saved. Wait for a point to appear, or start a presentation first.")
            }
            guard pointsToSave.count <= 200 else { throw Failure(code: "LIMIT_REACHED", detail: "A saved explanation can contain at most 200 displayed points.") }
            let sourceAtStart = sourceRevision(tab)
            let liveSchema = try await SchemaReviewCapture.snapshot(document: documentURL)
            guard workspaces.tabs.contains(where: { $0.id == tab.id }), sourceID(tab) == target.identity,
                  sourceAtStart == sourceRevision(tab), schemaMatchesLiveWorkspace(liveSchema, tab: tab) else {
                throw Failure(code: "STALE_SOURCE", detail: "The source changed while its explanation was being captured. Retry after reading the current view.")
            }
            var schema = liveSchema
            // Schema definitions can contain literal defaults or embedded secrets. The
            // historical model needs keys, types, and relations, so omit those values.
            for tableIndex in schema.tables.indices {
                schema.tables[tableIndex].metadata = [:]
                for columnIndex in schema.tables[tableIndex].columns.indices {
                    schema.tables[tableIndex].columns[columnIndex].defaultSQL = nil
                }
            }
            let included = try captureIncludedRows(args["included_result_scope"], workspace: tab,
                                                   clientID: clientID, contextID: context.id)
            guard sourceAtStart == sourceRevision(tab) else {
                throw Failure(code: "STALE_SOURCE", detail: "The source changed while the selected historical rows were being copied. Retry the capture from the current view.")
            }
            let savedPoints = try pointsToSave.map { try historicalPoint($0, state: state) }
            let now = Date()
            let artifact = HistoricalExplanationArtifact(
                id: UUID(), title: string(args, "title") ?? state.title, capturedAt: now,
                engine: schema.engine, sourceIdentityHash: sha256(sourceID(tab)),
                sourceRevisionHash: sha256(sourceAtStart), schema: schema, points: savedPoints,
                queryResults: included.results, tablePages: included.pages,
                warnings: ["Historical snapshot captured at \(now.formatted(.iso8601)). Only the selected displayed rows are saved.",
                           "Offline replay restores graph and layout actions with the captured table/query pages referenced by each point. Other saved pages remain available in the manual historical view."]
            )
            let destination = try explanationDestination(args, extension: "sgexplanation")
            let url = try HistoricalExplanationStore.write(artifact, to: destination)
            let id = try registerArtifact(url, context: context)
            return ["artifact_id": id, "path": url.path, "kind": "historical_explanation",
                    "title": artifact.title, "captured_at": now.formatted(.iso8601),
                    "source_identity_hash": artifact.sourceIdentityHash, "historical": true,
                    "saved_displayed_points": savedPoints.count, "query_results": included.results.count,
                    "table_pages": included.pages.count, "captured_rows": included.rowCount,
                    "omitted_rows": included.omittedRows,
                    "warning": "The source locator and connection credentials were excluded. Replay shows only captured table/query pages referenced by each point and never queries the original source."]
        case "studio_open_explanation":
            let url = try artifactURL(args, context: context)
            let artifact = try HistoricalExplanationStore.load(url)
            guard string(args, "start_mode").map({ ["replay", "manual"].contains($0) }) ?? true else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "start_mode must be replay or manual.")
            }
            guard bool(args, "create_workspace") != false else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "Historical explanations open in a dedicated offline workspace so they cannot replace or query a live source.")
            }
            let returnWorkspaceID = workspaces.activeTabID
            try requireAutomationWorkspaceCapacity(openingDocument: true)
            let tab = workspaces.createTab(kind: .explanation, title: artifact.title, activate: true)
            try claimWorkspace(tab.id, for: context.id)
            tab.session.openHistoricalExplanation(artifact, from: url)
            guard tab.session.historicalExplanationArtifact != nil else {
                let detail = tab.session.presentedError?.message ?? "The historical schema could not be opened."
                await workspaces.closeAndWait(tab.id)
                throw Failure(code: "ARTIFACT_INVALID", detail: detail)
            }
            try bind(context.id, workspace: tab.id)
            var payload: [String: Any] = ["workspace_id": tab.id.uuidString,
                "artifact_id": string(args, "artifact_id") ?? url.path, "title": artifact.title,
                "historical": true, "captured_at": artifact.capturedAt.formatted(.iso8601),
                "source_identity_hash": artifact.sourceIdentityHash,
                "visual_state": visualState(tab), "captured_result_count": artifact.queryResults.count,
                "captured_table_page_count": artifact.tablePages.count,
                "captured_row_count": artifact.queryResults.reduce(0) { $0 + $1.rows.count } + artifact.tablePages.reduce(0) { $0 + $1.rows.count },
                "live_queries_executed": false]
            if string(args, "start_mode") == "replay" {
                let state = try startHistoricalReplay(artifact, workspace: tab, returnTo: returnWorkspaceID,
                                                      context: context)
                currentPresentationIDByWorkspace[tab.id] = state.id
                presentations[state.id] = state
                let points = try artifact.points.map { try livePoint(from: $0, state: state) }
                state.controller.append(points)
                startPresentationLoop(state)
                payload["presentation"] = presentationPayload(state)
                payload["replay_omissions"] = artifact.points.compactMap { point -> [String: Any]? in
                    let liveID = state.controller.pendingPoints.first(where: { state.externalIDs[$0.id] == point.id })?.id
                        ?? state.controller.currentPoint.flatMap({ state.externalIDs[$0.id] == point.id ? $0.id : nil })
                    guard let liveID, let omissions = state.replayOmissions[liveID], !omissions.isEmpty else { return nil }
                    return ["point_id": point.id, "skipped_action_types": omissions]
                }
            } else {
                payload["saved_points"] = artifact.points.map { ["point_id": $0.id, "caption": $0.caption] }
                payload["presentation_state"] = "not_started"
            }
            payload["replay_limitations"] = artifact.warnings
            return payload
        case "studio_prepare_explanation_refresh":
            let oldURL = try artifactURL(["artifact_id": try requiredString(args, "artifact_id")], context: context)
            let oldArtifact = try HistoricalExplanationStore.load(oldURL)
            let requestedSource = try requiredString(args, "source_id")
            let tab = try refreshSourceWorkspace(args, sourceID: requestedSource, context: context)
            guard let documentURL = tab.session.databaseURL, let target = tab.session.databaseTarget else {
                throw Failure(code: "SOURCE_REQUIRED", detail: "Open the explicitly selected current source before preparing a refresh.")
            }
            let sourceAtStart = sourceRevision(tab)
            var freshSchema = try await SchemaReviewCapture.snapshot(document: documentURL)
            guard workspaces.tabs.contains(where: { $0.id == tab.id }), sourceID(tab) == target.identity,
                  sourceAtStart == sourceRevision(tab) else {
                throw Failure(code: "STALE_SOURCE", detail: "The selected source changed during refresh preparation. Read its current schema and retry.")
            }
            for tableIndex in freshSchema.tables.indices {
                freshSchema.tables[tableIndex].metadata = [:]
                for columnIndex in freshSchema.tables[tableIndex].columns.indices {
                    freshSchema.tables[tableIndex].columns[columnIndex].defaultSQL = nil
                }
            }
            let captured = try await captureRefreshTables(args["refresh_scope"], workspace: tab, schema: freshSchema)
            guard sourceAtStart == sourceRevision(tab) else {
                throw Failure(code: "STALE_SOURCE", detail: "The selected source changed while refresh rows were being captured. Read the current view and retry.")
            }
            let priorFingerprint = try SchemaPreview.fingerprint(oldArtifact.schema)
            let freshFingerprint = try SchemaPreview.fingerprint(freshSchema)
            let diff = SchemaReviewDocument(title: oldArtifact.title, baseRef: "Saved historical capture",
                headRef: "Fresh source capture", before: oldArtifact.schema, after: freshSchema)
            let changed = diff.changes.filter { $0.kind != .unchanged }.map { change in
                "\(change.kind.label): \(change.id) (\(change.added.count) fields added, \(change.removed.count) removed, \(change.modified.count) modified)"
            } + diff.relationChanges.filter { $0.kind != .unchanged }.map { "\($0.kind.label) relation: \($0.relation.source) → \($0.relation.target)" }
            let draft = HistoricalExplanationRefreshDraft(
                id: UUID(), title: oldArtifact.title + " refresh draft", preparedAt: Date(),
                parentArtifactHash: sha256(try Data(contentsOf: oldURL)), engine: freshSchema.engine,
                sourceIdentityHash: sha256(sourceID(tab)), sourceRevisionHash: sha256(sourceAtStart),
                priorSchemaFingerprint: priorFingerprint, freshSchemaFingerprint: freshFingerprint,
                freshSchema: freshSchema, queryResults: [], tablePages: captured.pages,
                schemaChanges: changed, warnings: ["This is a separate fresh-data draft. Historical captions and narration were deliberately not copied.",
                    "Rewrite claims using this schema and the explicitly captured rows before starting or saving a new explanation."])
            let destination = try explanationDestination(args, extension: "sgrefresh")
            let draftURL = try HistoricalExplanationStore.write(draft, to: destination)
            let draftID = try registerArtifact(draftURL, context: context)
            return ["draft_id": draftID, "path": draftURL.path, "kind": "historical_explanation_refresh_draft",
                    "parent_artifact_id": string(args, "artifact_id")!, "old_artifact_unchanged": true,
                    "historical_narration_reused": false, "requires_rewritten_claims": true,
                    "source_identity_hash": draft.sourceIdentityHash, "source_revision_hash": draft.sourceRevisionHash,
                    "prior_schema_fingerprint": priorFingerprint, "fresh_schema_fingerprint": freshFingerprint,
                    "schema_changes": changed, "captured_table_pages": captured.pages.count,
                    "captured_rows": captured.rowCount, "omitted_rows": captured.omittedRows,
                    "warning": "No old narration was applied to the fresh source."]
        case "studio_start_presentation":
            let tab = try workspace(args, context: context)
            guard let rawPoints = args["points"] as? [[String: Any]], !rawPoints.isEmpty else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "Provide at least one freeform presentation point.")
            }
            let narrationMode = string(args, "narration_mode") ?? "app_default"
            guard ["app_default", "enabled", "disabled"].contains(narrationMode) else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "narration_mode must be app_default, enabled, or disabled.")
            }
        let localNarrator = StudioSpeechNarrator()
            let narrationRequested = narrationMode == "enabled" ||
                (narrationMode == "app_default" && prefersNarration(for: tab))
            let narration = narrationRequested && localNarrator.isSpeechAvailable
            let state = PresentationState(ownerClientID: clientID, ownerContextID: context.id,
                                          workspaceID: tab.id, title: string(args, "title") ?? "Explore the data model",
                                          narrator: narration ? localNarrator : nil)
            state.returnCheckpointID = captureView(tab)
            if (string(args, "activation_intent") == "foreground" || bool(args, "activate") == true),
               let activeWorkspace = workspaces.activeTabID, activeWorkspace != tab.id {
                state.returnWorkspaceID = activeWorkspace
            }
            let points = try rawPoints.map { try makePoint($0, state: state, narration: narration) }
            for active in Array(presentations.values) where active.workspaceID == tab.id {
                active.controller.end()
                presentationTasks.removeValue(forKey: active.id)?.cancel()
                clearHistoricalReplaySelection(for: active)
                presentations.removeValue(forKey: active.id)
            }
            if string(args, "activation_intent") == "foreground" || bool(args, "activate") == true {
                workspaces.activate(tab.id)
                NSApp.activate(ignoringOtherApps: true)
            }
            presentations[state.id] = state
            currentPresentationIDByWorkspace[tab.id] = state.id
            try bind(context.id, workspace: tab.id)
            state.controller.append(points)
            startPresentationLoop(state)
            var payload = presentationPayload(state)
            if !narration && narrationRequested {
                payload["speech_warning"] = "Local speech is unavailable; this presentation continues with captions."
            }
            return payload
        case "studio_update_presentation":
            let state = try presentation(args, context: context)
            guard state.controller.status != .interrupted else {
                throw Failure(code: "INVALID_STATE", detail: "This presentation has ended. Start a new presentation to continue.")
            }
            if let expected = args["expected_revision"] as? Int, expected != state.revision {
                throw Failure(code: "STALE_VIEW", detail: "The presentation changed. Read studio_get_presentation and revise the pending points.")
            }
            let rawPoints = args["points"] as? [[String: Any]] ?? []
            let points = try rawPoints.map { try makePoint($0, state: state, narration: state.narrationEnabled) }
            let wasCompleted = state.controller.status == .completed
            switch string(args, "operation") ?? "append" {
            case "append": state.controller.append(points)
            case "replace_pending": state.controller.replacePending(with: points)
            case "replace_current_and_pending":
                state.controller.replaceCurrentAndPending(with: points)
                startPresentationLoop(state)
            default: throw Failure(code: "INVALID_ARGUMENT", detail: "Invalid presentation update operation.")
            }
            if wasCompleted && string(args, "operation") != "replace_current_and_pending" {
                startPresentationLoop(state)
            }
            if bool(args, "finish_after_queue") == true { state.controller.finishInput() }
            state.revision += 1
            return presentationPayload(state)
        case "studio_control_presentation":
            let state = try presentation(args, context: context)
            let hadCompleted = state.controller.status == .completed
            let priorPointID = state.controller.currentPoint?.id
            switch string(args, "control") ?? "" {
            case "pause": state.controller.pause()
            case "continue": state.controller.resume()
            case "back": state.controller.back()
            case "next": state.controller.next()
            case "repeat": state.controller.retryCurrent()
            case "end":
                state.controller.end()
                presentationTasks.removeValue(forKey: state.id)?.cancel()
                clearHistoricalReplaySelection(for: state)
            case "return":
                state.controller.end()
                presentationTasks.removeValue(forKey: state.id)?.cancel()
                clearHistoricalReplaySelection(for: state)
                let returnTab = workspaces.tabs.first(where: { $0.id == state.workspaceID })
                let canReturnWorkspace = state.returnWorkspaceID.flatMap { prior in
                    workspaces.tabs.contains(where: { $0.id == prior }) ? prior : nil
                }
                guard (state.returnCheckpointID != nil && returnTab != nil) || canReturnWorkspace != nil else {
                    throw Failure(code: "OBJECT_NOT_FOUND", detail: "The view before this presentation is unavailable.")
                }
                if let checkpointID = state.returnCheckpointID, let returnTab {
                    try restoreView(checkpointID, in: returnTab)
                }
                if let canReturnWorkspace { workspaces.activate(canReturnWorkspace) }
            case "set_speed":
                throw Failure(code: "TOOL_UNAVAILABLE", detail: "Live narration speed changes are not available in this speech provider build.")
            default: throw Failure(code: "INVALID_ARGUMENT", detail: "Unknown presentation control.")
            }
            if let pointID = state.controller.currentPoint?.id, pointID != priorPointID {
                state.captionRendered.remove(pointID)
                state.requiredRenderRevision.removeValue(forKey: pointID)
            }
            if hadCompleted && ["back", "next", "repeat"].contains(string(args, "control") ?? "") {
                startPresentationLoop(state)
            }
            state.revision += 1
            return presentationPayload(state)
        case "studio_get_presentation":
            return presentationPayload(try presentation(args, context: context))
        case "studio_wait_events":
            if args["presentation_id"] != nil || args["job_id"] != nil {
                throw Failure(code: "TOOL_UNAVAILABLE", detail: "This build waits for workspace view and current-presentation changes only. Use studio_get_presentation or studio_get_job for an exact presentation or job; ID-specific event filters are unavailable.")
            }
            let tab = try workspace(args, context: context)
            let previous = string(args, "after_cursor")
            let waitMS = min(10_000, max(1, args["wait_ms"] as? Int ?? args["wait_timeout_ms"] as? Int ?? 1_000))
            let clock = ContinuousClock()
            let started = clock.now
            while previous == eventCursor(tab) && started.duration(to: clock.now) < .milliseconds(waitMS) {
                try await Task.sleep(for: .milliseconds(100))
            }
            let cursor = eventCursor(tab)
            return ["cursor": cursor, "timed_out": cursor == previous,
                    "view": viewPayload(tab), "presentation": nullable(currentPresentationIDByWorkspace[tab.id].flatMap { presentations[$0] }.map(presentationPayload))]
        default:
            throw Failure(code: "TOOL_UNAVAILABLE", detail: "\(name) is described in the MCP catalog but has not been implemented in this app build.")
        }
    }

    private func startExport(_ args: [String: Any], context: Context, clientID: String) async throws -> [String: Any] {
        let rawFormat = try requiredString(args, "format").lowercased()
        guard let format = DataTransferFormat(rawValue: rawFormat) else {
            throw Failure(code: "TOOL_UNAVAILABLE", detail: "This build exports CSV and JSON data only. Graph images and explanation packages are not available through this tool.")
        }
        guard let scope = args["scope"] as? [String: Any] else {
            throw Failure(code: "INVALID_ARGUMENT", detail: "Provide scope.kind as displayed, captured, or all_matching.")
        }
        let scopeKind = try requiredString(scope, "kind")
        guard ["displayed", "captured", "all_matching"].contains(scopeKind) else {
            throw Failure(code: "INVALID_ARGUMENT", detail: "scope.kind must be displayed, captured, or all_matching.")
        }
        let objectType = try requiredString(args, "object_type")
        guard ["table_rows", "query_result", "transcript"].contains(objectType) else {
            throw Failure(code: "TOOL_UNAVAILABLE", detail: "Supported export objects are table rows, a captured query result, or a visible explanation transcript. Graph images and explanation packages are unavailable.")
        }

        let rawPath = NSString(string: try requiredString(args, "destination")).expandingTildeInPath
        guard rawPath.hasPrefix("/") else { throw Failure(code: "INVALID_ARGUMENT", detail: "destination must be an absolute local file path or begin with ~/.") }
        let destination = URL(fileURLWithPath: rawPath).standardizedFileURL
        guard destination.pathExtension.lowercased() == format.fileExtension else {
            throw Failure(code: "INVALID_ARGUMENT", detail: "The destination extension must be .\(format.fileExtension) for \(format.rawValue) output.")
        }
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue else {
            throw Failure(code: "DESTINATION_DIRECTORY_MISSING", detail: "The destination folder does not exist. Choose an existing local folder.")
        }
        let overwrite = bool(args, "overwrite") == true
        let timeoutSeconds = bounded(args, "timeout_seconds", default: 300, maximum: 300)
        var destinationIsDirectory: ObjCBool = false
        let destinationExists = fileManager.fileExists(atPath: destination.path, isDirectory: &destinationIsDirectory)
        guard !destinationIsDirectory.boolValue else { throw Failure(code: "INVALID_ARGUMENT", detail: "destination must be a file path, not a folder.") }
        if destinationExists && !overwrite {
            throw Failure(code: "DESTINATION_EXISTS", detail: "A file already exists at the destination. Choose another path or set overwrite=true explicitly.")
        }

        let tab = try workspace(args, context: context)
        var capturedSourceID = sourceID(tab)
        var capturedSourceRevision = sourceRevision(tab)
        var sourceResultTruncated = false
        let work: ExportWork

        switch objectType {
        case "table_rows":
            guard scopeKind == "displayed" || scopeKind == "all_matching" else {
                throw Failure(code: "TOOL_UNAVAILABLE", detail: "For table rows, choose displayed for the currently loaded page or all_matching for every row matching the table's current filters and sort.")
            }
            let sourceTab = try sourceWorkspace(args, context: context)
            try requireRows(in: sourceTab)
            let tableID = try requiredString(args, "object_id")
            guard let table = sourceTab.session.openTabs.first(where: { $0.descriptor.id == tableID || $0.descriptor.name == tableID }) else {
                if scopeKind == "displayed" {
                    throw Failure(code: "OBJECT_NOT_FOUND", detail: "Open this table with studio_open_table first; displayed scope exports only its currently loaded page.")
                }
                // all_matching has an explicit full-row scope and can use the default table query when no grid is open.
                let reader = try await readOnlyService(for: sourceTab)
                let descriptor = try await reader.fetchDescriptor(named: tableID)
                guard let target = sourceTab.session.databaseTarget else { throw Failure(code: "SOURCE_REQUIRED", detail: "No database is open.") }
                work = .matchingTableRows(reader: reader, target: target, query: TableQueryState(), descriptor: descriptor)
                capturedSourceID = sourceID(sourceTab)
                capturedSourceRevision = sourceRevision(sourceTab)
                break
            }
            capturedSourceID = sourceID(sourceTab)
            capturedSourceRevision = sourceRevision(sourceTab)
            if scopeKind == "displayed" {
                guard !table.chunk.rows.contains(where: { !$0.omittedColumnIndices.isEmpty }) else {
                    throw Failure(code: "SCOPE_INCOMPLETE", detail: "Displayed rows contain omitted large values. Export all matching rows from the source, or use a narrower projection; omitted values cannot be exported as NULL.")
                }
                work = .retainedRows(names: table.descriptor.columns.map(\.name), rows: table.chunk.rows.map(\.values))
            } else {
                let reader = try await readOnlyService(for: sourceTab)
                let descriptor = try await reader.fetchDescriptor(named: table.descriptor.name)
                guard let target = sourceTab.session.databaseTarget else { throw Failure(code: "SOURCE_REQUIRED", detail: "No database is open.") }
                work = .matchingTableRows(reader: reader, target: target, query: table.queryState, descriptor: descriptor)
            }
        case "query_result":
            guard scopeKind == "displayed" || scopeKind == "captured" else {
                throw Failure(code: "TOOL_UNAVAILABLE", detail: "Query exports use displayed for the last fetched result page or captured for the complete bounded result returned by studio_run_query. A query is never silently rerun as all_matching.")
            }
            let resultID = try requiredString(scope, "result_id")
            guard let saved = results[resultID], saved.workspace == tab.id,
                  saved.ownerContextID == context.id else {
                throw Failure(code: "OBJECT_NOT_FOUND", detail: "That captured query result does not belong to this workspace or is no longer available.")
            }
            guard saved.sourceID == sourceID(tab), saved.sourceRevision == sourceRevision(tab) else {
                throw Failure(code: "STALE_SOURCE", detail: "This query result belongs to an earlier source revision. Run the query again before exporting it.")
            }
            capturedSourceID = saved.sourceID
            capturedSourceRevision = saved.sourceRevision
            sourceResultTruncated = saved.result.isTruncated
            let selectedRows: [QueryResultRow]
            if scopeKind == "captured" {
                selectedRows = saved.result.rows
            } else {
                let offset = max(0, saved.displayedOffset)
                let limit = min(100, max(1, saved.displayedLimit))
                selectedRows = Array(saved.result.rows.dropFirst(offset).prefix(limit))
            }
            work = .retainedRows(names: saved.result.columns.map(\.name), rows: selectedRows.map(\.values))
        case "transcript":
            guard scopeKind == "displayed" || scopeKind == "captured" else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "Transcript scope must be displayed or captured.")
            }
            let presentationID = string(scope, "presentation_id") ?? currentPresentationIDByWorkspace[tab.id]
            guard let presentationID, let state = presentations[presentationID],
                  state.workspaceID == tab.id, state.ownerContextID == context.id else {
                throw Failure(code: "OBJECT_NOT_FOUND", detail: "Choose a presentation in this workspace, or start one before exporting its transcript.")
            }
            let points: [LivePresentationController.Point]
            if scopeKind == "displayed" {
                guard let current = state.controller.currentPoint, state.captionRendered.contains(current.id) else {
                    throw Failure(code: "OBJECT_NOT_FOUND", detail: "There is no currently visible explanation caption to export.")
                }
                points = [current]
            } else {
                let currentPoints = state.controller.currentPoint.map { state.captionRendered.contains($0.id) ? [$0] : [] } ?? []
                points = state.controller.displayedHistory + currentPoints
            }
            guard !points.isEmpty else { throw Failure(code: "OBJECT_NOT_FOUND", detail: "This presentation has no visible captions yet.") }
            work = .retainedRows(names: ["point_id", "caption", "narration"], rows: points.map { point in
                [DatabaseResultValue.text(point.id.uuidString), .text(point.caption), point.narration.map(DatabaseResultValue.text) ?? .null]
            })
        default:
            throw Failure(code: "TOOL_UNAVAILABLE", detail: "This export object is not available in this build.")
        }

        let jobID = "job:" + UUID().uuidString
        let objectID = string(args, "object_id") ?? string(scope, "result_id") ?? string(scope, "presentation_id")
        let job = ExportJobState(id: jobID, clientID: clientID, contextID: context.id, workspaceID: tab.id,
                                 sourceID: capturedSourceID, sourceRevision: capturedSourceRevision,
                                 destination: destination, format: format, scope: scopeKind,
                                 objectType: objectType, objectID: objectID, overwrite: overwrite,
                                 sourceResultTruncated: sourceResultTruncated, timeoutSeconds: timeoutSeconds)
        exportJobs[jobID] = job
        job.task = Task { [weak self] in await self?.performExport(jobID: jobID, work: work) }
        return exportJobPayload(job)
    }

    private func performExport(jobID: String, work: ExportWork) async {
        guard let job = exportJobs[jobID] else { return }
        if Task.isCancelled || job.cancellation.isCancelled { job.status = "cancelled"; return }
        job.status = "running"
        do {
            let progress: @Sendable (Int) -> Void = { [weak self] count in
                Task { @MainActor [weak self] in
                    guard let self, let current = self.exportJobs[jobID], current.status == "running" else { return }
                    current.rowsWritten = max(current.rowsWritten, count)
                }
            }
            let count: Int
            switch work {
            case .retainedRows(let names, let rows):
                count = try await StreamingRowExport.write(names: names, rows: rows, to: job.destination,
                                                           format: job.format, cancellation: job.cancellation,
                                                           failIfExists: !job.overwrite, progress: progress)
            case .matchingTableRows(let reader, let target, let query, let descriptor):
                count = try await reader.exportTableRows(query: query, descriptor: descriptor,
                                                         to: job.destination, format: job.format,
                                                         timeoutSeconds: TimeInterval(job.timeoutSeconds), expectedTarget: target,
                                                         cancellation: job.cancellation,
                                                         failIfExists: !job.overwrite, progress: progress)
            }
            job.rowsWritten = count
            job.rowCount = count
            job.status = "completed"
        } catch {
            if error is CancellationError || job.cancellation.isCancelled || Task.isCancelled {
                job.status = "cancelled"
                job.error = nil
            } else {
                job.status = "failed"
                job.error = String(error.localizedDescription.prefix(1000))
            }
        }
    }

    private func performQueryJob(_ jobID: String) async {
        guard let job = queryJobs[jobID], job.status == "queued" else { return }
        job.status = "running"
        do {
            guard let tab = workspaces.tabs.first(where: { $0.id == job.workspaceID }),
                  queryJobIsCurrent(job, tab: tab) else {
                job.status = "cancelled"
                return
            }
            let reader = try await readOnlyService(for: tab)
            guard queryJobIsCurrent(job, tab: tab) else {
                if job.status == "running" { job.status = "cancelled" }
                return
            }
            let result = try await reader.executeReadOnlyQuery(
                sql: job.sql, rowLimit: job.rowLimit, timeoutSeconds: TimeInterval(job.timeoutSeconds)
            )
            guard queryJobIsCurrent(job, tab: tab) else {
                if job.status == "running" { job.status = "cancelled" }
                return
            }
            let resultID = "result:" + UUID().uuidString
            results[resultID] = (tab.id, job.sql, result, job.sourceID, job.sourceRevision,
                                 0, 100, job.clientID, job.contextID)
            job.resultID = resultID
            job.status = "completed"
        } catch {
            if job.status == "cancelled" || Task.isCancelled {
                job.status = "cancelled"
                job.resultID = nil
            } else {
                job.status = "failed"
                job.error = String(error.localizedDescription.prefix(1_000))
            }
        }
    }

    private func queryJobIsCurrent(_ job: QueryJobState, tab: WorkspaceTab) -> Bool {
        guard queryJobs[job.id] === job, job.status == "running",
              workspaces.tabs.contains(where: { $0 === tab }),
              workspaceOwners[job.workspaceID] == job.contextID,
              let context = contexts[job.contextID], context.clientID == job.clientID,
              context.workspaceID == job.workspaceID,
              sourceID(tab) == job.sourceID, sourceRevision(tab) == job.sourceRevision else { return false }
        return true
    }

    private func getExportJob(_ args: [String: Any], context: Context, clientID: String) throws -> [String: Any] {
        let jobID = try requiredString(args, "job_id")
        guard let job = exportJobs[jobID], job.contextID == context.id else {
            throw Failure(code: "OBJECT_NOT_FOUND", detail: "That export job is unavailable to this coding task.")
        }
        try validateJobWorkspace(job, args: args, context: context)
        return exportJobPayload(job)
    }

    private func getJob(_ args: [String: Any], context: Context, clientID: String) throws -> [String: Any] {
        let jobID = try requiredString(args, "job_id")
        if let job = speechJobs[jobID] {
            guard job.clientID == clientID, job.ownerContextID == context.id else {
                throw Failure(code: "OBJECT_NOT_FOUND", detail: "That speech job is unavailable to this client.")
            }
            try validateSpeechJobWorkspace(job, args: args, context: context)
            return speechJobPayload(job)
        }
        if let job = queryJobs[jobID] {
            guard job.contextID == context.id else {
                throw Failure(code: "OBJECT_NOT_FOUND", detail: "That query job is unavailable to this coding task.")
            }
            try validateQueryJobWorkspace(job, args: args)
            return queryJobPayload(job)
        }
        return try getExportJob(args, context: context, clientID: clientID)
    }

    private func validateQueryJobWorkspace(_ job: QueryJobState, args: [String: Any]) throws {
        if let explicit = explicitWorkspace(args), explicit != job.workspaceID {
            throw Failure(code: "OBJECT_NOT_FOUND", detail: "That query job belongs to a different workspace.")
        }
    }

    private func cancelExportJob(_ args: [String: Any], context: Context, clientID: String) throws -> [String: Any] {
        let jobID = try requiredString(args, "job_id")
        guard let job = exportJobs[jobID], job.contextID == context.id else {
            throw Failure(code: "OBJECT_NOT_FOUND", detail: "That export job is unavailable to this coding task.")
        }
        try validateJobWorkspace(job, args: args, context: context)
        if job.status == "queued" || job.status == "running" {
            job.status = "cancelling"
            job.cancellation.cancel()
            job.task?.cancel()
        }
        return exportJobPayload(job)
    }

    private func cancelJob(_ args: [String: Any], context: Context, clientID: String) async throws -> [String: Any] {
        let jobID = try requiredString(args, "job_id")
        if let job = queryJobs[jobID] {
            guard job.contextID == context.id else {
                throw Failure(code: "OBJECT_NOT_FOUND", detail: "That query job is unavailable to this coding task.")
            }
            try validateQueryJobWorkspace(job, args: args)
            if job.status == "queued" || job.status == "running" {
                job.status = "cancelled"
                job.task?.cancel()
                // Query cancellation waits for the database backend to tear
                // down its active read before returning the final receipt.
                await job.task?.value
            }
            return queryJobPayload(job)
        }
        guard let job = speechJobs[jobID] else {
            return try cancelExportJob(args, context: context, clientID: clientID)
        }
        guard job.clientID == clientID, job.ownerContextID == context.id else {
            throw Failure(code: "OBJECT_NOT_FOUND", detail: "That speech job is unavailable to this client.")
        }
        try validateSpeechJobWorkspace(job, args: args, context: context)
        guard job.status == "queued" || job.status == "running" else {
            return speechJobPayload(job)
        }
        job.status = "cancelling"
        if job.kind == "speech_asset_install" {
            speechAssetManager.cancel()
            job.task?.cancel()
        } else {
            job.narrator?.stop()
            job.task?.cancel()
        }
        return speechJobPayload(job)
    }

    private func validateSpeechJobWorkspace(
        _ job: SpeechOperationJob,
        args: [String: Any],
        context: Context
    ) throws {
        guard job.ownerContextID == context.id else {
            throw Failure(code: "OBJECT_NOT_FOUND", detail: "That speech job is unavailable in this context.")
        }
        guard let workspaceID = job.workspaceID else { return }
        if let explicit = explicitWorkspace(args), explicit != workspaceID {
            throw Failure(code: "OBJECT_NOT_FOUND", detail: "That speech job belongs to a different workspace.")
        }
        if context.workspaceID != workspaceID, explicitWorkspace(args) == nil {
            throw Failure(code: "AMBIGUOUS_WORKSPACE", detail: "Pass the workspace_id returned with the job to inspect it from another workspace context.")
        }
    }

    private func manageSpeechAssets(
        _ args: [String: Any],
        context: Context,
        clientID: String
    ) async throws -> [String: Any] {
        let packageID = try requiredString(args, "package_id")
        guard packageID == PocketTTSSpeechAssets.packageID else {
            throw Failure(code: "PACKAGE_NOT_FOUND", detail: "The only supported speech package is \(PocketTTSSpeechAssets.packageID). Arbitrary model URLs and package IDs are not accepted.")
        }
        let action = try requiredString(args, "action")
        let workspaceID = explicitWorkspace(args) ?? context.workspaceID

        switch action {
        case "offer":
            speechAssetManager.refresh()
            return speechAssetOfferPayload(action: action, workspaceID: workspaceID)

        case "install":
            return startSpeechAssetInstall(clientID: clientID, contextID: context.id, workspaceID: workspaceID)

        case "retry":
            if let priorJobID = string(args, "job_id") {
                guard let prior = speechJobs[priorJobID], prior.clientID == clientID,
                      prior.ownerContextID == context.id,
                      prior.kind == "speech_asset_install", prior.packageID == packageID else {
                    throw Failure(code: "OBJECT_NOT_FOUND", detail: "That speech installation job is unavailable to this client.")
                }
                try validateSpeechJobWorkspace(prior, args: args, context: context)
                guard ["failed", "cancelled", "paused"].contains(prior.status) else {
                    throw Failure(code: "JOB_NOT_RETRYABLE", detail: "Retry is available only after an installation has failed or been paused.")
                }
            }
            return startSpeechAssetInstall(clientID: clientID, contextID: context.id, workspaceID: workspaceID)

        case "cancel":
            let jobID = try requiredString(args, "job_id")
            guard let job = speechJobs[jobID], job.clientID == clientID,
                  job.ownerContextID == context.id,
                  job.kind == "speech_asset_install", job.packageID == packageID else {
                throw Failure(code: "OBJECT_NOT_FOUND", detail: "That speech installation job is unavailable to this client.")
            }
            try validateSpeechJobWorkspace(job, args: args, context: context)
            guard job.status == "queued" || job.status == "running" else {
                return speechJobPayload(job)
            }
            job.status = "cancelling"
            speechAssetManager.cancel()
            job.task?.cancel()
            return speechJobPayload(job)

        default:
            throw Failure(code: "INVALID_ARGUMENT", detail: "action must be offer, install, cancel, or retry.")
        }
    }

    private func startSpeechAssetInstall(clientID: String, contextID: String, workspaceID: UUID?) -> [String: Any] {
        speechAssetManager.refresh()
        if let active = speechJobs.values.first(where: {
            $0.kind == "speech_asset_install" && ["queued", "running", "cancelling"].contains($0.status)
        }) {
            if active.clientID == clientID, active.ownerContextID == contextID { return speechJobPayload(active) }
            return ["package_id": PocketTTSSpeechAssets.packageID, "status": "install_in_progress",
                    "message": "A verified speech package install is already running. Use studio_get_speech to check package readiness."]
        }
        guard speechAssetManager.canOfferDownload else {
            return speechAssetOfferPayload(action: "install", workspaceID: workspaceID)
        }

        let job = SpeechOperationJob(
            id: "job:" + UUID().uuidString,
            clientID: clientID,
            ownerContextID: contextID,
            kind: "speech_asset_install",
            packageID: PocketTTSSpeechAssets.packageID
        )
        speechJobs[job.id] = job
        job.task = Task { [weak self, weak job] in
            guard let self, let job else { return }
            job.status = "running"
            await self.speechAssetManager.download()
            if Task.isCancelled || job.status == "cancelling" {
                job.status = "cancelled"
            } else {
                switch self.speechAssetManager.state {
                case .assetsInstalled:
                    job.status = "completed"
                case .failed(_, let message):
                    job.status = "failed"
                    job.error = message
                case .paused:
                    job.status = "paused"
                case .unavailable(let message):
                    job.status = "unavailable"
                    job.error = message
                case .available, .downloading, .verifying:
                    job.status = "failed"
                    job.error = "The asset manager stopped before completing the verified package install."
                }
            }
        }
        return speechJobPayload(job)
    }

    private func speechAssetOfferPayload(action: String, workspaceID: UUID?) -> [String: Any] {
        let readiness = speechAssetManager.readiness
        let status: String
        switch speechAssetManager.state {
        case .unavailable:
            switch readiness {
            case .ready: status = "ready"
            case .workerAdapterUnavailable: status = "assets_installed"
            case .runtimeNotPackaged, .presetAssetsMissing: status = "unavailable"
            }
        case .available: status = "available"
        case .downloading: status = "downloading"
        case .verifying: status = "verifying"
        case .paused: status = "paused"
        case .assetsInstalled: status = readiness.canUsePocketTTS ? "ready" : "assets_installed"
        case .failed: status = "failed"
        }
        return [
            "action": action,
            "package_id": PocketTTSSpeechAssets.packageID,
            "status": status,
            "can_install": speechAssetManager.canOfferDownload,
            "asset_bytes": PocketTTSSpeechAssets.combinedDownloadSizeBytes,
            "asset_count": PocketTTSSpeechAssets.assets.count,
            "assets_installed": status == "assets_installed" || status == "ready",
            "speech_ready": readiness.canUsePocketTTS,
            "pocket_tts_status": readiness.explanation,
            "requires_explicit_install_action": true,
            "workspace_id": nullable(workspaceID?.uuidString),
        ]
    }

    private func speechJobPayload(_ job: SpeechOperationJob) -> [String: Any] {
        if job.kind == "speech_asset_install" {
            if job.status == "completed" { speechAssetManager.refresh() }
            var payload = speechAssetOfferPayload(action: "install", workspaceID: job.workspaceID)
            payload["asset_status"] = payload["status"]
            payload["job_id"] = job.id
            payload["kind"] = job.kind
            payload["context_id"] = job.ownerContextID
            payload["status"] = job.status
            payload["error"] = nullable(job.error)
            if case .downloading(let assetID, let assetBytes, let assetTotal, let totalBytes, let totalTotal) = speechAssetManager.state {
                payload["asset_id"] = assetID
                payload["asset_bytes_received"] = assetBytes
                payload["asset_bytes_total"] = assetTotal
                payload["total_bytes_received"] = totalBytes
                payload["total_bytes_total"] = totalTotal
                payload["progress"] = totalTotal == 0 ? 0 : Double(totalBytes) / Double(totalTotal)
            } else if case .verifying(let assetID) = speechAssetManager.state {
                payload["asset_id"] = assetID
            } else if case .paused(let assetID, let resumableBytes) = speechAssetManager.state {
                payload["asset_id"] = nullable(assetID)
                payload["resumable_bytes"] = resumableBytes
            }
            return payload
        }

        return [
            "job_id": job.id,
            "kind": job.kind,
            "context_id": job.ownerContextID,
            "status": job.status,
            "workspace_id": nullable(job.workspaceID?.uuidString),
            "voice_id": nullable(job.voiceID),
            "sample_character_count": nullable(job.sampleCharacterCount),
            "stage": speechStage(job.progress),
            "provider_name": nullable(job.providerName),
            "provider_id": nullable(job.providerID),
            "error": nullable(job.error),
        ]
    }

    private func startSpeechTest(
        _ args: [String: Any],
        context: Context,
        clientID: String
    ) throws -> [String: Any] {
        let tab = try workspace(args, context: context)
        guard hasVisibleAppWindow else {
            throw Failure(code: "APP_WINDOW_NOT_VISIBLE", detail: "Speech samples play only while a Graph Studio window is visible. Bring the app onscreen, then retry.")
        }
        guard workspaces.activeTabID == tab.id else {
            throw Failure(code: "WORKSPACE_NOT_VISIBLE", detail: "Speech samples play only for the visible workspace. Activate this workspace, then retry.")
        }
        guard !hasNarrationInProgress() else {
            throw Failure(code: "AUDIO_IN_USE", detail: "A presentation is already speaking. Pause or end it before testing another speech sample.")
        }
        guard !speechJobs.values.contains(where: {
            $0.kind == "speech_test" && ["queued", "running", "cancelling"].contains($0.status)
        }) else {
            throw Failure(code: "AUDIO_IN_USE", detail: "A speech sample is already running. Check or cancel its job before starting another.")
        }

        let voiceID = string(args, "voice_id") ?? "app_default"
        let narrator: StudioSpeechNarrator
        switch voiceID {
        case "app_default":
            narrator = StudioSpeechNarrator()
        case "macos":
            narrator = StudioSpeechNarrator(provider: SystemStreamingSpeechProvider())
        case "alba":
            let pocket = PocketTTSStreamingSpeechProvider()
            guard pocket.isAvailable else {
                return ["status": "unavailable", "voice_id": "alba", "workspace_id": tab.id.uuidString,
                        "pocket_tts_status": PocketTTSRuntimeInspector.bundledDefault().inspect().explanation]
            }
            narrator = StudioSpeechNarrator(provider: pocket)
        default:
            throw Failure(code: "INVALID_ARGUMENT", detail: "voice_id must be app_default, macos, or alba.")
        }

        let text = (string(args, "text") ?? "This is a short local speech test.")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let maximum = args["max_characters"] as? Int ?? 280
        guard maximum > 0, maximum <= 280, !text.isEmpty, text.count <= maximum else {
            throw Failure(code: "INVALID_ARGUMENT", detail: "Provide nonempty sample text within max_characters; the limit is 280 characters.")
        }
        if let diagnosticID = string(args, "diagnostic_id"), diagnosticID != "short_sample" {
            throw Failure(code: "INVALID_ARGUMENT", detail: "The only supported diagnostic_id is short_sample.")
        }

        let job = SpeechOperationJob(
            id: "job:" + UUID().uuidString,
            clientID: clientID,
            ownerContextID: context.id,
            kind: "speech_test",
            workspaceID: tab.id,
            voiceID: voiceID,
            sampleCharacterCount: text.count,
            narrator: narrator
        )
        speechJobs[job.id] = job
        job.task = Task { [weak job] in
            guard let job else { return }
            job.status = "running"
            job.progress = .generating
            let completed = await narrator.playStreamed(text) { status in
                job.progress = status
                job.providerName = narrator.speechProviderName
                job.providerID = narrator.speechProviderIdentifier
                if case .failed(let message) = status { job.error = message }
            }
            job.providerName = narrator.speechProviderName
            job.providerID = narrator.speechProviderIdentifier
            if Task.isCancelled || job.status == "cancelling" {
                job.status = "cancelled"
                job.error = nil
            } else if completed {
                job.status = "completed"
                job.error = nil
            } else {
                job.status = "failed"
                if job.error == nil { job.error = "Speech did not produce an audible PCM stream." }
            }
        }
        return speechJobPayload(job)
    }

    private func activeSpeechNarrator() -> StudioSpeechNarrator? {
        for state in presentations.values where state.narrationEnabled {
            switch state.controller.status {
            case .generatingAudio, .speaking, .waitingForSpeech:
                return state.narrator
            default:
                continue
            }
        }
        return speechJobs.values.first(where: {
            $0.kind == "speech_test" && ["queued", "running"].contains($0.status)
        })?.narrator
    }

    private func hasNarrationInProgress() -> Bool {
        presentations.values.contains { state in
            guard state.narrationEnabled else { return false }
            switch state.controller.status {
            case .generatingAudio, .speaking, .waitingForSpeech: return true
            default: return false
            }
        }
    }

    private func stopSpeechTestsForHiddenWindow() {
        for job in speechJobs.values where job.kind == "speech_test"
            && ["queued", "running", "cancelling"].contains(job.status) {
            job.status = "cancelling"
            job.narrator?.stop()
            job.task?.cancel()
        }
    }

    private func speechStage(_ status: SpeechPlaybackStatus) -> String {
        switch status {
        case .idle: "idle"
        case .installRequired: "install_required"
        case .installing: "installing"
        case .preparing: "preparing"
        case .generating: "generating"
        case .speaking: "speaking"
        case .failed: "failed"
        }
    }

    private func validateJobWorkspace(_ job: ExportJobState, args: [String: Any], context: Context) throws {
        if let explicit = explicitWorkspace(args), explicit != job.workspaceID {
            throw Failure(code: "OBJECT_NOT_FOUND", detail: "That job belongs to a different workspace.")
        }
        if context.workspaceID != job.workspaceID {
            throw Failure(code: "CONTEXT_WORKSPACE_MISMATCH", detail: "Reconnect this coding task to the export job's workspace before inspecting it.")
        }
    }

    private func exportJobPayload(_ job: ExportJobState) -> [String: Any] {
        ["job_id": job.id, "kind": "export", "status": job.status,
         "workspace_id": job.workspaceID.uuidString, "source_id": job.sourceID,
         "source_revision": job.sourceRevision, "object_type": job.objectType,
         "object_id": nullable(job.objectID), "scope": job.scope, "format": job.format.rawValue,
         "destination": job.destination.path,
         "rows_written": job.rowsWritten, "row_count": nullable(job.rowCount),
         "source_result_truncated": job.sourceResultTruncated,
         "timeout_seconds": job.timeoutSeconds,
         "overwrite": job.overwrite, "error": nullable(job.error)]
    }

    private func ownedContext(_ id: String?, clientID: String) throws -> Context {
        guard let id, let context = contexts[id], context.clientID == clientID else {
            throw Failure(code: "CONTEXT_REQUIRED", detail: "Call studio_connect_context first, then pass its context_id.")
        }
        return context
    }

    private func verifyContextUnchanged(_ context: Context) throws {
        guard let current = contexts[context.id], current.clientID == context.clientID,
              current.workspaceID == context.workspaceID else {
            throw Failure(code: "STALE_VIEW", detail: "The coding task disconnected or switched workspaces while this request was opening. Retry from the current context.")
        }
    }

    private func explicitWorkspace(_ args: [String: Any]) -> UUID? {
        string(args, "workspace_id").flatMap(UUID.init(uuidString:))
    }

    private func inferredWorkspaceKind(for url: URL) -> WorkspaceTabKind {
        switch url.pathExtension.lowercased() {
        case "sgpreview": .preview
        case "sgreview": .comparison
        case "sgexplanation": .explanation
        default: .workspace
        }
    }

    private func availableWorkspaces(for contextID: String) -> [WorkspaceTab] {
        workspaces.tabs.filter { workspaceOwners[$0.id].map { $0 == contextID } ?? true }
    }

    private func visibleActiveWorkspaceID(for contextID: String) -> Any {
        guard let active = workspaces.activeTabID,
              workspaceOwners[active].map({ $0 == contextID }) ?? true else { return NSNull() }
        return active.uuidString
    }

    private func claimWorkspace(_ id: UUID, for contextID: String) throws {
        guard workspaces.tabs.contains(where: { $0.id == id }) else {
            throw Failure(code: "OBJECT_NOT_FOUND", detail: "That workspace is not open.")
        }
        guard workspaceOwners[id].map({ $0 == contextID }) ?? true else {
            throw Failure(code: "WORKSPACE_IN_USE", detail: "This workspace belongs to another coding task. The user can release the foreground tab from Graph Studio's Coding Agents menu, then retry.")
        }
        workspaceOwners[id] = contextID
    }

    /// Automation can be driven by several coding tasks at once. Bound the tabs it
    /// creates so repeated source changes cannot restore or keep opening an
    /// unbounded number of database connections and graph canvases.
    private func requireAutomationWorkspaceCapacity(openingDocument: Bool = false) throws {
        let ownedCount = workspaces.tabs.reduce(into: 0) { count, tab in
            if workspaceOwners[tab.id] != nil { count += 1 }
        }
        guard ownedCount < 12, workspaces.tabs.count < 32 else {
            throw Failure(code: "WORKSPACE_LIMIT_REACHED", detail: "Graph Studio has too many open workspaces for another automated tab. Reuse the current workspace or close unused tabs before opening another source.")
        }
        if openingDocument, workspaces.liveDocumentCount >= WorkspaceTabController.maximumLiveDocuments {
            throw documentLimitFailure()
        }
    }

    private func documentLimitFailure() -> Failure {
        Failure(code: "WORKSPACE_LIMIT_REACHED", detail: "Graph Studio already has four loaded documents across coding tasks. Reuse a source tab or close an unused source tab before opening another.")
    }

    private func workspace(_ args: [String: Any], context: Context) throws -> WorkspaceTab {
        let id = explicitWorkspace(args) ?? context.workspaceID
        guard let id, let tab = workspaces.tabs.first(where: { $0.id == id }) else {
            throw Failure(code: "AMBIGUOUS_WORKSPACE", detail: "Select an exact workspace_id from studio_list_workspaces.")
        }
        guard workspaceOwners[id] == context.id else {
            throw Failure(code: "WORKSPACE_IN_USE", detail: "This workspace is not bound to this coding task. Use studio_connect_context to attach an available workspace.")
        }
        return tab
    }

    private func sourceWorkspace(_ args: [String: Any], context: Context) throws -> WorkspaceTab {
        let tab = try workspace(args, context: context)
        guard tab.session.databaseTarget != nil else { throw Failure(code: "SOURCE_REQUIRED", detail: "Open a live database source in this workspace first. Historical explanation workspaces remain offline.") }
        if let requested = string(args, "source_id"), requested != sourceID(tab) {
            throw Failure(code: "STALE_SOURCE", detail: "The requested source_id is no longer attached to this workspace.")
        }
        if let expected = string(args, "source_revision"), expected != sourceRevision(tab) {
            throw Failure(code: "STALE_SOURCE", detail: "The source changed since this request was prepared. Refresh or describe the current schema before retrying.")
        }
        return tab
    }

    private func bind(_ contextID: String?, workspace: UUID) throws {
        guard let contextID else { return }
        guard contexts[contextID] != nil else {
            throw Failure(code: "CONTEXT_EXPIRED", detail: "This coding task context expired while the workspace was opening. Connect a new context before continuing.")
        }
        try requireWorkspaceOwnership(workspace, contextID: contextID)
        contexts[contextID]?.workspaceID = workspace
    }

    private func requireWorkspaceOwnership(_ workspace: UUID, contextID: String) throws {
        guard workspaceOwners[workspace] == contextID else {
            throw Failure(code: "WORKSPACE_OWNERSHIP_RELEASED", detail: "The workspace was released to another coding task while it was opening. The handoff was preserved; connect to an available workspace to continue.")
        }
    }

    private func readOnlyService(for tab: WorkspaceTab) async throws -> DatabaseService {
        guard let target = tab.session.databaseTarget else { throw Failure(code: "SOURCE_REQUIRED", detail: "No database is open.") }
        try requireRows(in: tab)
        if let reader = readers[tab.id], readerTargets[tab.id] == target.identity { return reader }
        if let previous = readers.removeValue(forKey: tab.id) { await previous.close() }
        let reader = DatabaseService()
        do {
            switch target {
            case .sqlite(let url): try await reader.open(url: url, readOnly: true, includeRowCounts: false)
            case .postgres(let configuration): try await reader.open(postgres: configuration)
            case .postgresDump:
                throw Failure(code: "TOOL_UNAVAILABLE", detail: "Bounded row reads from restored PostgreSQL dumps are unavailable through this bridge build.")
            case .migrations:
                throw Failure(code: "SCHEMA_ONLY_SOURCE", detail: "Migration replay provides schema only. Open a database to inspect rows or run queries.")
            }
        } catch {
            await reader.close()
            throw error
        }
        guard workspaces.tabs.contains(where: { $0 === tab }),
              tab.session.databaseTarget?.identity == target.identity else {
            await reader.close()
            throw Failure(code: "STALE_SOURCE", detail: "The workspace closed or changed source while its read-only reader opened.")
        }
        if let openedByAnotherCall = readers[tab.id], readerTargets[tab.id] == target.identity {
            await reader.close()
            return openedByAnotherCall
        }
        readers[tab.id] = reader
        readerTargets[tab.id] = target.identity
        return reader
    }

    private func sourceID(_ tab: WorkspaceTab) -> String { tab.session.databaseTarget?.identity ?? "none" }

    private func requireRows(in tab: WorkspaceTab) throws {
        guard tab.session.databaseCapabilities.canBrowseRows else {
            throw Failure(code: "SCHEMA_ONLY_SOURCE", detail: "This migration source contains schema only. Open a database to inspect, filter, or export rows.")
        }
    }

    private func requireQueries(in tab: WorkspaceTab) throws {
        guard tab.session.databaseCapabilities.canRunQueries else {
            throw Failure(code: "SCHEMA_ONLY_SOURCE", detail: "This migration source contains schema only. Open a database to prepare or run queries.")
        }
    }

    private func verifySource(_ tab: WorkspaceTab, id: String, revision: String, context: Context) throws {
        guard workspaces.tabs.contains(where: { $0 === tab }),
              sourceID(tab) == id, sourceRevision(tab) == revision,
              contexts[context.id]?.workspaceID == tab.id else {
            throw Failure(code: "STALE_SOURCE", detail: "The workspace closed or its source changed while the read-only request was running. Read the current view and retry.")
        }
    }

    private func captureView(_ tab: WorkspaceTab) -> String {
        let session = tab.session
        let id = "view:" + UUID().uuidString
        checkpoints[id] = ViewCheckpoint(
            workspace: tab.id,
            sourceID: sourceID(tab),
            selected: session.selectedGraphNodeIDs,
            expanded: session.expandedGraphNodeIDs,
            visible: session.automationVisibleTableIDs,
            zoom: session.graphZoom,
            pan: session.graphPan,
            positions: session.graphLayout.snapshot(for: session.graph),
            nodeSizeMetric: session.graphNodeSizeMetric,
            leftPane: session.paneState(for: .left).kind,
            rightPane: session.paneState(for: .right).kind,
            activePaneSide: session.activePaneSide,
            activeTableTabID: session.activeTabID,
            openTableTabIDs: Set(session.openTabs.map(\.id)),
            activeQueryID: session.queryWorkspace.activeQueryID,
            showsAllGraphTableCards: session.showAllGraphTableCards,
            splitFraction: session.workspaceSplitFraction,
            maximizedPane: session.maximizedPaneSide,
            annotations: viewAnnotations.annotations(in: tab.id)
        )
        return id
    }

    private func restoreView(_ id: String, in tab: WorkspaceTab) throws {
        guard let point = checkpoints[id], point.workspace == tab.id else {
            throw Failure(code: "OBJECT_NOT_FOUND", detail: "This view checkpoint is unavailable in the selected workspace.")
        }
        guard point.sourceID == sourceID(tab) else {
            throw Failure(code: "STALE_SOURCE", detail: "The source changed since this view was captured. Open the original source to restore it.")
        }
        let session = tab.session
        let valid = Set(session.graph.nodes.map(\.id))
        session.setAutomationVisibleTableIDs(point.visible?.intersection(valid))
        session.setGraphSelection(point.selected.intersection(valid))
        session.expandedGraphNodeIDs = point.expanded.intersection(valid)
        session.graphZoom = point.zoom
        session.graphPan = point.pan
        session.requestAutomationViewport(fitVisibleTables: false, transitionMilliseconds: 0)
        session.showAllGraphTableCards = point.showsAllGraphTableCards
        session.restoreAutomationGraphLayout(point.positions)
        session.setGraphNodeSizeMetric(point.nodeSizeMetric, persist: false)
        session.setPaneContent(point.leftPane, for: .left)
        session.setPaneContent(point.rightPane, for: .right)
        session.setActivePaneSide(point.activePaneSide)
        for openedTab in session.openTabs where !point.openTableTabIDs.contains(openedTab.id) {
            session.closeTab(id: openedTab.id)
        }
        if let activeTableTabID = point.activeTableTabID,
           session.openTabs.contains(where: { $0.id == activeTableTabID }) {
            session.selectTab(id: activeTableTabID)
        } else if point.activeTableTabID == nil {
            session.activeTabID = nil
        }
        if let activeQueryID = point.activeQueryID {
            session.queryWorkspace.selectQuery(id: activeQueryID)
        } else {
            session.queryWorkspace.activeQueryID = nil
        }
        session.workspaceSplitFraction = point.splitFraction
        session.maximizedPaneSide = point.maximizedPane
        viewAnnotations.replace(point.annotations, in: tab.id)
        if point.annotations.isEmpty {
            annotationSourceByWorkspace.removeValue(forKey: tab.id)
        } else {
            annotationSourceByWorkspace[tab.id] = point.sourceID
        }
        session.markAutomationViewChanged()
    }

    private func preferencesKey(for tab: WorkspaceTab) -> String {
        "SQLiteGraphStudio.explanation-preferences.source." + fingerprint(sourceID(tab))
    }

    private func prefersNarration(for tab: WorkspaceTab) -> Bool {
        let global = UserDefaults.standard.dictionary(forKey: "SQLiteGraphStudio.explanation-preferences.global") as? [String: String] ?? [:]
        let source = UserDefaults.standard.dictionary(forKey: preferencesKey(for: tab)) as? [String: String] ?? [:]
        switch (source["narration"] ?? global["narration"] ?? "enabled").lowercased() {
        case "disabled", "off", "false", "no", "visual_only": return false
        default: return true
        }
    }

    private func artifactDestination(_ args: [String: Any], ext: String) throws -> URL {
        let url: URL
        if let path = string(args, "destination") {
            url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let directory = support.appendingPathComponent("SQLiteGraphStudio/Artifacts", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw Failure(code: "DESTINATION_EXISTS", detail: "The artifact destination exists. Choose a new destination; it was not overwritten.")
        }
        return url
    }

    private func registerArtifact(_ url: URL, context: Context, fingerprint: String? = nil) throws -> String {
        try verifyContextUnchanged(context)
        let id = "artifact:" + UUID().uuidString
        artifacts[id] = url
        artifactOwners[id] = context.id
        if let fingerprint { artifactFingerprints[id] = fingerprint }
        return id
    }

    private func artifactURL(_ args: [String: Any], context: Context) throws -> URL {
        if let path = string(args, "path") {
            let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { throw Failure(code: "ARTIFACT_NOT_FOUND", detail: "The artifact file does not exist.") }
            return url
        }
        if let id = string(args, "artifact_id"), let url = artifacts[id] {
            guard artifactOwners[id] == context.id else {
                throw Failure(code: "ARTIFACT_NOT_FOUND", detail: "That artifact is unavailable to this coding task. Provide its file path explicitly to import it.")
            }
            return url
        }
        if let id = string(args, "artifact_id"), id.hasPrefix("artifact:") {
            throw Failure(code: "ARTIFACT_NOT_FOUND", detail: "That artifact is unavailable to this coding task. Provide its file path explicitly to import it.")
        }
        if let path = string(args, "artifact_id") {
            let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { throw Failure(code: "ARTIFACT_NOT_FOUND", detail: "The artifact file does not exist.") }
            return url
        }
        throw Failure(code: "ARTIFACT_NOT_FOUND", detail: "Provide artifact_id or path.")
    }

    private func presentation(_ args: [String: Any], context: Context) throws -> PresentationState {
        let id = try requiredString(args, "presentation_id")
        guard let state = presentations[id] else { throw Failure(code: "OBJECT_NOT_FOUND", detail: "The presentation is not active in this app instance.") }
        guard state.ownerContextID == context.id else {
            throw Failure(code: "OBJECT_NOT_FOUND", detail: "This presentation belongs to another coding task.")
        }
        guard (context.workspaceID ?? explicitWorkspace(args)) == state.workspaceID else {
            throw Failure(code: "CONTEXT_WORKSPACE_MISMATCH", detail: "This presentation belongs to another workspace. Connect this coding task to its workspace before controlling or saving it.")
        }
        return state
    }

    private func historicalPoint(_ point: LivePresentationController.Point,
                                 state: PresentationState) throws -> HistoricalExplanationArtifact.Point {
        let actions = try (state.actions[point.id] ?? []).map { try HistoricalJSONValue(any: sanitizedHistoryAction($0)) }
        let timing = state.savedTiming[point.id] ?? (2_000, 0, "automatic")
        return HistoricalExplanationArtifact.Point(
            id: point.id.uuidString,
            caption: point.caption,
            narration: state.savedNarration[point.id],
            minimumVisibleMilliseconds: timing.minimumMS,
            extraHoldMilliseconds: timing.holdMS,
            advance: timing.advance,
            actions: actions,
            evidence: state.savedEvidence[point.id] ?? [],
            replayOmissions: state.replayOmissions[point.id] ?? []
        )
    }

    private func sanitizedHistoryAction(_ action: [String: Any]) throws -> [String: Any] {
        let type = try requiredString(action, "type")
        let fields: Set<String>
        switch type {
        case "show_tables": fields = ["type", "table_ids", "mode"]
        case "select_objects", "expand_tables": fields = ["type", "table_ids"]
        case "focus_keys": fields = ["type", "table_id", "table_ids", "source_column", "target_column", "relation_id"]
        case "set_camera": fields = ["type", "mode", "zoom", "pan_x", "pan_y"]
        case "arrange_tables": fields = ["type", "table_ids", "x", "y"]
        case "set_node_sizing": fields = ["type", "metric"]
        case "set_layout": fields = ["type", "split_fraction", "left_pane", "right_pane"]
        case "open_table": fields = ["type", "table_id"]
        default: throw Failure(code: "INVALID_ARGUMENT", detail: "A displayed point contains an unsupported action that cannot be saved safely.")
        }
        return action.filter { fields.contains($0.key) }
    }

    private func livePoint(from captured: HistoricalExplanationArtifact.Point,
                           state: PresentationState) throws -> LivePresentationController.Point {
        let supported: Set<String> = ["show_tables", "select_objects", "expand_tables", "focus_keys", "set_camera",
                                      "arrange_tables", "set_node_sizing", "set_layout", "open_table"]
        var kept: [[String: Any]] = []
        var omitted = Set(captured.replayOmissions)
        for action in captured.actions {
            guard let object = action.foundationValue as? [String: Any],
                  let type = object["type"] as? String else {
                omitted.insert("malformed_action")
                continue
            }
            if supported.contains(type) { kept.append(object) }
            else { omitted.insert(type) }
        }
        let raw: [String: Any] = [
            "point_id": captured.id,
            "caption": captured.caption,
            "narration": captured.narration ?? "",
            "actions": kept,
            "timing": ["minimum_visible_ms": captured.minimumVisibleMilliseconds,
                       "extra_hold_ms": captured.extraHoldMilliseconds,
                       "advance": captured.advance],
        ]
        let point = try makePoint(raw, state: state, narration: state.narrationEnabled)
        state.externalIDs[point.id] = captured.id
        state.savedNarration[point.id] = captured.narration ?? ""
        state.savedTiming[point.id] = (captured.minimumVisibleMilliseconds, captured.extraHoldMilliseconds, captured.advance)
        state.savedEvidence[point.id] = captured.evidence
        state.replayOmissions[point.id] = omitted.sorted()
        return point
    }

    private func startHistoricalReplay(_ artifact: HistoricalExplanationArtifact,
                                       workspace tab: WorkspaceTab, returnTo workspaceID: UUID?,
                                       context: Context) throws -> PresentationState {
        let preferences = UserDefaults.standard.dictionary(forKey: "SQLiteGraphStudio.explanation-preferences.global") as? [String: String] ?? [:]
        let preference = (preferences["narration"] ?? "enabled").lowercased()
        let narrator = StudioSpeechNarrator()
        let narrationEnabled = !["disabled", "off", "false", "no", "visual_only"].contains(preference) && narrator.isSpeechAvailable
        let state = PresentationState(ownerClientID: context.clientID, ownerContextID: context.id,
                                      workspaceID: tab.id, title: artifact.title,
                                      narrator: narrationEnabled ? narrator : nil)
        // There is no preceding live view inside this isolated offline workspace.
        state.returnCheckpointID = nil
        state.returnWorkspaceID = workspaceID
        return state
    }

    private func evidenceReferences(_ raw: Any?) throws -> [HistoricalExplanationArtifact.EvidenceReference] {
        guard let items = raw as? [[String: Any]] else { return [] }
        guard items.count <= 32 else { throw Failure(code: "LIMIT_REACHED", detail: "A presentation point can save at most 32 evidence references.") }
        return try items.map { item in
            let kind = String((item["kind"] as? String ?? "object").prefix(64))
            let tableID = (item["table_id"] as? String).map { String($0.prefix(500)) }
            let resultID = (item["result_id"] as? String).map { String($0.prefix(300)) }
            let objectID = (item["object_id"] as? String ?? item["id"] as? String ?? resultID ?? tableID ?? "")
            guard !objectID.isEmpty else { throw Failure(code: "INVALID_ARGUMENT", detail: "Each evidence reference needs object_id, result_id, or table_id.") }
            return .init(kind: kind, objectID: String(objectID.prefix(500)), tableID: tableID,
                         resultID: resultID, rowOffset: item["row_offset"] as? Int,
                         columnID: (item["column_id"] as? String).map { String($0.prefix(500)) })
        }
    }

    private func captureIncludedRows(_ raw: Any?, workspace tab: WorkspaceTab, clientID: String, contextID: String) throws
        -> (results: [HistoricalExplanationArtifact.CapturedQueryResult], pages: [HistoricalExplanationArtifact.CapturedTablePage], rowCount: Int, omittedRows: Int) {
        guard let scope = raw as? [String: Any] else { return ([], [], 0, 0) }
        let resultIDs = strings(scope, "result_ids") ?? []
        let rawPages = scope["table_pages"] as? [[String: Any]] ?? []
        guard resultIDs.count <= 40, rawPages.count <= 40,
              Set(resultIDs).count == resultIDs.count else {
            throw Failure(code: "LIMIT_REACHED", detail: "Select at most 40 unique query results and 40 displayed table pages.")
        }
        var capturedResults: [HistoricalExplanationArtifact.CapturedQueryResult] = []
        var capturedPages: [HistoricalExplanationArtifact.CapturedTablePage] = []
        var rowCount = 0
        var omittedRows = 0
        for resultID in resultIDs {
            guard let saved = results[resultID], saved.workspace == tab.id,
                  saved.ownerContextID == contextID,
                  saved.sourceID == sourceID(tab), saved.sourceRevision == sourceRevision(tab) else {
                throw Failure(code: "STALE_SOURCE", detail: "Query result \(resultID) is unavailable to this client, belongs to another workspace, or was captured from an earlier source revision.")
            }
            guard saved.result.columns.count <= 256 else { throw Failure(code: "LIMIT_REACHED", detail: "A captured query result may contain at most 256 columns.") }
            let offset = max(0, saved.displayedOffset)
            let limit = min(100, max(1, saved.displayedLimit))
            let rows = Array(saved.result.rows.dropFirst(offset).prefix(limit))
            rowCount += rows.count
            omittedRows += max(0, saved.result.rows.count - offset - rows.count)
            guard rowCount <= 1_000 else { throw Failure(code: "LIMIT_REACHED", detail: "A saved explanation can capture at most 1,000 rows in total.") }
            let columns = saved.result.columns.map { HistoricalExplanationArtifact.CapturedColumn(name: $0.name, type: $0.typeLabel) }
            capturedResults.append(.init(
                resultID: resultID,
                columns: columns,
                rows: rows.enumerated().map { index, row in
                    .init(ordinal: offset + index, values: capturedCells(row.values, columns: columns))
                },
                displayedOffset: offset,
                omittedRows: max(0, saved.result.rows.count - offset - rows.count),
                sourceWasTruncated: saved.result.isTruncated
            ))
        }
        for item in rawPages {
            let tableID = try requiredString(item, "table_id")
            guard let table = tab.session.openTabs.first(where: { $0.descriptor.id == tableID }) else {
                throw Failure(code: "OBJECT_NOT_FOUND", detail: "Open the requested table in this workspace before saving its displayed rows.")
            }
            let offset = max(0, item["offset"] as? Int ?? table.chunk.offset)
            let limit = min(100, max(1, item["limit"] as? Int ?? 100))
            let end = offset + limit
            guard table.chunk.offset <= offset, end <= table.chunk.rowRange.upperBound else {
                throw Failure(code: "SCOPE_NOT_DISPLAYED", detail: "The requested table page is not fully present in the current displayed cache. Select a page that is already loaded.")
            }
            let selectedRows = table.chunk.rows.enumerated().compactMap { index, row -> (Int, TableRow)? in
                let absolute = table.chunk.offset + index
                return (offset..<end).contains(absolute) ? (absolute, row) : nil
            }
            guard !selectedRows.contains(where: { !$0.1.omittedColumnIndices.isEmpty }) else {
                throw Failure(code: "SCOPE_INCOMPLETE", detail: "Displayed rows contain omitted large values. Capture a narrower table projection or inspect the needed cells in bounded slices before saving evidence.")
            }
            rowCount += selectedRows.count
            omittedRows += max(0, table.chunk.totalRowCount - offset - selectedRows.count)
            guard rowCount <= 1_000 else { throw Failure(code: "LIMIT_REACHED", detail: "A saved explanation can capture at most 1,000 rows in total.") }
            let columns = table.descriptor.columns.map { HistoricalExplanationArtifact.CapturedColumn(name: $0.name, type: $0.declaredType) }
            capturedPages.append(.init(
                tableID: tableID,
                columns: columns,
                rows: selectedRows.map { absolute, row in .init(ordinal: absolute, values: capturedCells(row.values, columns: columns)) },
                displayedOffset: offset,
                omittedRows: max(0, table.chunk.totalRowCount - offset - selectedRows.count)
            ))
        }
        return (capturedResults, capturedPages, rowCount, omittedRows)
    }

    private func captureRefreshTables(_ raw: Any?, workspace tab: WorkspaceTab, schema: SchemaReviewSnapshot) async throws
        -> (pages: [HistoricalExplanationArtifact.CapturedTablePage], rowCount: Int, omittedRows: Int) {
        guard let scope = raw as? [String: Any] else { return ([], 0, 0) }
        let requests = scope["tables"] as? [[String: Any]] ?? []
        guard requests.count <= 40 else { throw Failure(code: "LIMIT_REACHED", detail: "Refresh at most 40 tables in one draft.") }
        var pages: [HistoricalExplanationArtifact.CapturedTablePage] = []
        var rowCount = 0
        var omittedRows = 0
        if !requests.isEmpty {
            let reader = try await readOnlyService(for: tab)
            for request in requests {
                let id = try requiredString(request, "table_id")
                guard schema.tables.contains(where: { $0.id == id }) else {
                    throw Failure(code: "OBJECT_NOT_FOUND", detail: "Table \(id) is not part of the explicitly selected current source.")
                }
                let descriptor = try await reader.fetchDescriptor(named: id)
                let offset = max(0, request["offset"] as? Int ?? 0)
                let limit = min(100, max(1, request["limit"] as? Int ?? 100))
                guard offset <= 1_000_000 else { throw Failure(code: "LIMIT_REACHED", detail: "Refresh page offsets are limited to 1,000,000.") }
                let chunk = try await reader.fetchChunk(query: TableQueryState(offset: offset, limit: limit), descriptor: descriptor)
                rowCount += chunk.rows.count
                omittedRows += max(0, chunk.totalRowCount - offset - chunk.rows.count)
                guard rowCount <= 1_000 else { throw Failure(code: "LIMIT_REACHED", detail: "A refresh draft can capture at most 1,000 rows in total.") }
                let columns = descriptor.columns.map { HistoricalExplanationArtifact.CapturedColumn(name: $0.name, type: $0.declaredType) }
                pages.append(.init(
                    tableID: id,
                    columns: columns,
                    rows: chunk.rows.enumerated().map { index, row in .init(ordinal: offset + index, values: capturedCells(row.values, columns: columns)) },
                    displayedOffset: offset,
                    omittedRows: max(0, chunk.totalRowCount - offset - chunk.rows.count)
                ))
            }
        }
        return (pages, rowCount, omittedRows)
    }

    private func refreshSourceWorkspace(_ args: [String: Any], sourceID requested: String, context: Context) throws -> WorkspaceTab {
        guard let current = context.workspaceID,
              let tab = workspaces.tabs.first(where: { $0.id == current }),
              tab.session.databaseTarget != nil, sourceID(tab) == requested,
              explicitWorkspace(args).map({ $0 == current }) ?? true else {
            throw Failure(code: "STALE_SOURCE", detail: "Connect this coding task to the exact live source workspace before refreshing a historical explanation.")
        }
        return tab
    }

    private func capturedCell(_ value: SQLiteValue) -> HistoricalExplanationArtifact.CapturedCell {
        switch value {
        case .null: return .init(type: "null", value: nil, byteCount: nil, truncated: false)
        case .blob(let bytes): return .init(type: "blob", value: nil, byteCount: bytes.count, truncated: false)
        default:
            let text = value.editorText
            let clipped = String(text.prefix(4_096))
            return .init(type: value.typeLabel.lowercased(), value: clipped, byteCount: nil, truncated: clipped.count < text.count)
        }
    }

    private func capturedCells(_ values: [SQLiteValue], columns: [HistoricalExplanationArtifact.CapturedColumn]) -> [HistoricalExplanationArtifact.CapturedCell] {
        values.enumerated().map { index, value in
            guard columns.indices.contains(index), !isCredentialColumn(columns[index].name) else {
                return .init(type: "redacted", value: nil, byteCount: nil, truncated: false)
            }
            return capturedCell(value)
        }
    }

    private func isCredentialColumn(_ name: String) -> Bool {
        let compact = name.lowercased().filter(\.isLetter)
        return ["password", "passwd", "secret", "token", "credential", "apikey", "privatekey", "accesskey", "authorization"]
            .contains(where: compact.contains)
    }

    private func schemaMatchesLiveWorkspace(_ snapshot: SchemaReviewSnapshot, tab: WorkspaceTab) -> Bool {
        guard Set(snapshot.tables.map(\.id)) == Set(tab.session.tables.map(\.id)) else { return false }
        for table in snapshot.tables {
            guard let descriptor = tab.session.descriptor(named: table.id),
                  table.name == descriptor.objectName,
                  table.schema == descriptor.schemaName,
                  table.kind == descriptor.objectType.rawValue,
                  table.columns.count == descriptor.columns.count,
                  table.columns.allSatisfy({ captured in
                      guard let current = descriptor.columns.first(where: { $0.name == captured.name }) else { return false }
                      return current.declaredType == captured.type && current.notNull == captured.notNull
                          && current.primaryKeyOrdinal == captured.primaryKeyOrdinal
                          && current.hiddenValue == captured.generated && current.identityKind == captured.identity
                  }) else { return false }
        }
        let capturedEdges = snapshot.relations.flatMap { relation in
            zip(relation.sourceColumns, relation.targetColumns).map { sourceColumn, targetColumn in
                "\(relation.source)|\(relation.target)|\(sourceColumn)|\(targetColumn)"
            }
        }.sorted()
        let displayedEdges = tab.session.graph.edges.map {
            "\($0.sourceID)|\($0.targetID)|\($0.sourceColumn)|\($0.targetColumn)"
        }.sorted()
        return capturedEdges == displayedEdges
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func sha256(_ text: String) -> String { sha256(Data(text.utf8)) }

    private func explanationDestination(_ args: [String: Any], extension fileExtension: String) throws -> URL? {
        guard let path = string(args, "destination") else { return nil }
        let expanded = NSString(string: path).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw Failure(code: "INVALID_ARGUMENT", detail: "destination must be an absolute local file path or begin with ~/.")
        }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        guard url.pathExtension.lowercased() == fileExtension else {
            throw Failure(code: "INVALID_ARGUMENT", detail: "Save this artifact with the .\(fileExtension) extension.")
        }
        return url
    }

    private func inspectHistoricalExplanation(_ url: URL, args: [String: Any]) throws -> [String: Any] {
        let artifact = try HistoricalExplanationStore.load(url)
        let needle = string(args, "search")?.lowercased()
        let limit = bounded(args, "limit", default: 25, maximum: 25)
        if string(args, "detail_scope") == "object" {
            let id = try requiredString(args, "object_id")
            if let point = artifact.points.first(where: { $0.id == id }) {
                return ["artifact_id": string(args, "artifact_id") ?? url.path, "kind": "historical_explanation_point",
                        "historical": true, "point_id": point.id, "caption": point.caption,
                        "narration": nullable(point.narration), "evidence": point.evidence.map { evidencePayload($0) },
                        "replay_omissions": point.replayOmissions]
            }
            if let result = artifact.queryResults.first(where: { $0.resultID == id }) {
                return ["artifact_id": string(args, "artifact_id") ?? url.path, "kind": "historical_query_result",
                        "historical": true, "result_id": result.resultID, "columns": result.columns.map { ["name": $0.name, "type": $0.type] },
                        "rows": result.rows.prefix(limit).map { capturedRowPayload($0, maximumColumns: 64, maximumCellCharacters: 256) },
                        "displayed_offset": result.displayedOffset,
                        "omitted_rows": result.omittedRows + max(0, result.rows.count - limit),
                        "columns_truncated": result.columns.count > 64, "source_truncated": result.sourceWasTruncated]
            }
            if let table = artifact.schema.tables.first(where: { $0.id == id }) {
                let pages = artifact.tablePages.filter { $0.tableID == id }
                let relations = artifact.schema.relations.filter { $0.source == id || $0.target == id }
                return ["artifact_id": string(args, "artifact_id") ?? url.path, "kind": "historical_table_schema",
                        "historical": true, "table_id": table.id, "name": table.displayName, "object_kind": table.kind,
                        "columns": table.columns.prefix(256).map { column in
                            ["name": column.name, "type": column.type, "nullable": !column.notNull,
                             "primary_key_ordinal": column.primaryKeyOrdinal,
                             "generated": column.generated != 0, "identity": column.identity] as [String: Any]
                        }, "column_count": table.columns.count,
                        "columns_truncated": table.columns.count > 256,
                        "relations": relations.prefix(limit).map { relation in
                            ["id": relation.id, "source": relation.source, "target": relation.target,
                             "source_columns": relation.sourceColumns, "target_columns": relation.targetColumns] as [String: Any]
                        }, "relation_count": relations.count,
                        "captured_pages": pages.prefix(limit).map { capturedPagePayload($0, limit: limit) },
                        "captured_page_count": pages.count,
                        "captured_row_count": pages.reduce(0) { $0 + $1.rows.count },
                        "captured_data": !pages.isEmpty,
                        "truncated": pages.count > limit]
            }
            throw Failure(code: "OBJECT_NOT_FOUND", detail: "No captured point, query result, or schema table has that object_id.")
        }
        let points = artifact.points.filter { needle == nil || $0.caption.lowercased().contains(needle!) || $0.id.lowercased().contains(needle!) }
        let tables = artifact.schema.tables.filter {
            needle == nil || $0.id.lowercased().contains(needle!) || $0.name.lowercased().contains(needle!)
        }
        return ["artifact_id": string(args, "artifact_id") ?? url.path, "kind": "historical_explanation",
                "title": artifact.title, "historical": true, "captured_at": artifact.capturedAt.formatted(.iso8601),
                "engine": artifact.engine, "source_identity_hash": artifact.sourceIdentityHash,
                "schema_fingerprint": try SchemaPreview.fingerprint(artifact.schema),
                "tables": tables.prefix(limit).map(\.id), "table_count": tables.count, "relations": artifact.schema.relations.count,
                "points": points.prefix(limit).map { ["point_id": $0.id, "caption": $0.caption] },
                "point_count": points.count, "captured_query_results": artifact.queryResults.map(\.resultID),
                "captured_table_pages": artifact.tablePages.map(\.tableID),
                "captured_rows": artifact.queryResults.reduce(0) { $0 + $1.rows.count } + artifact.tablePages.reduce(0) { $0 + $1.rows.count },
                "warnings": artifact.warnings, "truncated": points.count > limit || tables.count > limit]
    }

    private func evidencePayload(_ evidence: HistoricalExplanationArtifact.EvidenceReference) -> [String: Any] {
        ["kind": evidence.kind, "object_id": evidence.objectID, "table_id": nullable(evidence.tableID),
         "result_id": nullable(evidence.resultID), "row_offset": nullable(evidence.rowOffset),
         "column_id": nullable(evidence.columnID)]
    }

    private func capturedPagePayload(_ page: HistoricalExplanationArtifact.CapturedTablePage,
                                     limit: Int) -> [String: Any] {
        ["table_id": page.tableID,
         "columns": page.columns.prefix(64).map { ["name": $0.name, "type": $0.type] },
         "columns_truncated": page.columns.count > 64,
         "rows": page.rows.prefix(limit).map { capturedRowPayload($0, maximumColumns: 64, maximumCellCharacters: 256) },
         "displayed_offset": page.displayedOffset, "captured_row_count": page.rows.count,
         "omitted_rows": page.omittedRows + max(0, page.rows.count - limit)]
    }

    private func capturedRowPayload(_ row: HistoricalExplanationArtifact.CapturedRow,
                                    maximumColumns: Int = 64,
                                    maximumCellCharacters: Int = 256) -> [String: Any] {
        ["ordinal": row.ordinal, "values": row.values.prefix(maximumColumns).map { cell in
            let clipped = cell.value.map { String($0.prefix(maximumCellCharacters)) }
            return ["type": cell.type, "value": nullable(clipped), "byte_count": nullable(cell.byteCount),
                    "truncated": cell.truncated || (clipped?.count ?? 0) < (cell.value?.count ?? 0)] as [String: Any]
        }]
    }

    private func compactSparseAutomationSubset(_ session: AppSession) {
        guard session.automationVisibleTableIDs != nil else { return }
        let ids = session.graphVisibleTableIDs.sorted()
        guard (3...8).contains(ids.count) else { return }
        let points = ids.map { session.graphLayout.position(for: $0) }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return }
        let columns = 2
        let rows = (ids.count + columns - 1) / columns
        // Keep a collapsed bridge view inside a normal window. Expanded cards
        // need more height, and the camera will reduce zoom if that is still
        // too tall for the current pane.
        let rowSpacing: CGFloat = ids.contains(where: { session.expandedGraphNodeIDs.contains($0) }) ? 280 : 210
        let columnSpacing: CGFloat = 540
        let isSparse = maxX - minX > columnSpacing + 180
            || maxY - minY > CGFloat(rows - 1) * rowSpacing + 120
        guard isSparse else { return }
        session.compactGraphTables(ids, columns: columns)
    }

    private func makePoint(_ raw: [String: Any], state: PresentationState, narration: Bool) throws -> LivePresentationController.Point {
        let caption = try requiredString(raw, "caption")
        guard caption.count <= 2_000 else { throw Failure(code: "LIMIT_REACHED", detail: "A presentation point caption must be at most 2,000 characters.") }
        // A caption-only point should still speak when the user's narration
        // preference is enabled. An explicit empty narration stays silent.
        let spoken = narration ? (raw["narration"] == nil ? caption : string(raw, "narration")) : nil
        guard (spoken?.count ?? 0) <= 5_000 else { throw Failure(code: "LIMIT_REACHED", detail: "A narration point must be at most 5,000 characters.") }
        var actions = raw["actions"] as? [[String: Any]] ?? []
        if let target = string(raw, "target_table_id") {
            actions.append(["type": "select_objects", "table_ids": [target]])
        }
        guard actions.count <= 12 else { throw Failure(code: "LIMIT_REACHED", detail: "A point can have at most 12 visual actions.") }
        let timing = raw["timing"] as? [String: Any] ?? [:]
        let readingTime = min(15_000, max(2_000, caption.split(whereSeparator: \.isWhitespace).count * 333 + 500))
        let defaultMinimum = spoken?.isEmpty == false ? 2_000 : readingTime
        let minimum = min(60_000, max(0, timing["minimum_visible_ms"] as? Int ?? defaultMinimum))
        let hold = min(60_000, max(0, timing["extra_hold_ms"] as? Int ?? 0))
        let point = LivePresentationController.Point(caption: caption, narration: spoken,
            minimumVisibleTime: .milliseconds(minimum), additionalHold: .milliseconds(hold),
            advancePolicy: string(timing, "advance") == "manual" ? .manual : .automatic)
        state.actions[point.id] = actions
        state.pointsByID[point.id] = point
        state.externalIDs[point.id] = string(raw, "point_id") ?? point.id.uuidString
        state.savedNarration[point.id] = spoken ?? ""
        state.savedTiming[point.id] = (minimum, hold, string(timing, "advance") == "manual" ? "manual" : "automatic")
        state.savedEvidence[point.id] = try evidenceReferences(raw["evidence_refs"])
        return point
    }

    private func startPresentationLoop(_ state: PresentationState) {
        presentationTasks[state.id]?.cancel()
        presentationTasks[state.id] = Task { @MainActor [weak self] in
            var handledPoint: UUID?
            while !Task.isCancelled {
                guard let self, self.presentations[state.id] === state else { return }
                if case .preparing(let pointID) = state.controller.status {
                    if handledPoint != pointID {
                        handledPoint = pointID
                        await self.applyPoint(state, pointID: pointID)
                    }
                } else {
                    handledPoint = nil
                }
                self.maybeMarkPointVisible(state)
                if state.controller.status == .completed || state.controller.status == .interrupted { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func isCurrentPoint(_ state: PresentationState, id: UUID) -> Bool {
        guard !Task.isCancelled, presentations[state.id] === state,
              currentPresentationIDByWorkspace[state.workspaceID] == state.id,
              state.controller.currentPoint?.id == id,
              case .preparing(let currentID) = state.controller.status else { return false }
        return currentID == id
    }

    private func applyPoint(_ state: PresentationState, pointID: UUID) async {
        guard let tab = workspaces.tabs.first(where: { $0.id == state.workspaceID }),
              isCurrentPoint(state, id: pointID) else { return }
        let session = tab.session
        let actions = state.actions[pointID] ?? []
        let checkpointID = captureView(tab)
        defer { checkpoints.removeValue(forKey: checkpointID) }
        do {
            let allowed: Set<String> = ["show_tables", "select_objects", "expand_tables", "focus_keys", "set_camera",
                                        "arrange_tables", "set_node_sizing", "set_layout", "open_table"]
            let validIDs = Set(session.graph.nodes.map(\.id))
            for action in actions {
                let type = try requiredString(action, "type")
                guard allowed.contains(type) else { throw Failure(code: "INVALID_ARGUMENT", detail: "Unsupported point action \(type). Use a dedicated MCP tool before this point.") }
                let ids = Set(strings(action, "table_ids") ?? (string(action, "table_id").map { [$0] } ?? []))
                guard ids.isSubset(of: validIDs) else { throw Failure(code: "OBJECT_NOT_FOUND", detail: "A point names a table that is not in this source.") }
                if type == "focus_keys" {
                    guard let tableID = string(action, "table_id") ?? strings(action, "table_ids")?.first,
                          validIDs.contains(tableID) else {
                        throw Failure(code: "OBJECT_NOT_FOUND", detail: "The focused table must exist in this source.")
                    }
                    if action["relation_id"] != nil || action["source_column"] != nil || action["target_column"] != nil {
                        guard session.graph.edges.contains(where: { edge in
                            guard edge.sourceID == tableID || edge.targetID == tableID else { return false }
                            if let relationID = string(action, "relation_id"), edge.id != relationID { return false }
                            if let sourceColumn = string(action, "source_column"), edge.sourceColumn != sourceColumn { return false }
                            if let targetColumn = string(action, "target_column"), edge.targetColumn != targetColumn { return false }
                            return true
                        }) else {
                            throw Failure(code: "OBJECT_NOT_FOUND", detail: "The focused key or relation must be a declared edge of the selected table.")
                        }
                    }
                }
                if type == "set_camera" {
                    _ = try cameraTransitionMilliseconds(action)
                    let mode = string(action, "mode") ?? "absolute"
                    guard ["absolute", "fit_visible"].contains(mode),
                          mode != "fit_visible" || (action["zoom"] == nil && action["pan_x"] == nil && action["pan_y"] == nil),
                          (action["pan_x"] == nil) == (action["pan_y"] == nil),
                          mode == "fit_visible" || action["zoom"] != nil || action["pan_x"] != nil else {
                        throw Failure(code: "INVALID_ARGUMENT", detail: "A point camera needs fit_visible or bounded zoom/pan coordinates.")
                    }
                    for key in ["zoom", "pan_x", "pan_y"] where action[key] != nil {
                        guard let value = number(action, key), value.isFinite,
                              key == "zoom" || abs(value) <= 1_000_000 else {
                            throw Failure(code: "INVALID_ARGUMENT", detail: "A point camera coordinate is outside the usable range.")
                        }
                    }
                }
                if type == "arrange_tables" {
                    let ids = strings(action, "table_ids") ?? []
                    guard !ids.isEmpty, Set(ids).count == ids.count else {
                        throw Failure(code: "INVALID_ARGUMENT", detail: "A point arrangement needs distinct table IDs.")
                    }
                    for key in ["x", "y"] where action[key] != nil {
                        guard let value = number(action, key), value.isFinite, abs(value) <= 1_000_000 else {
                            throw Failure(code: "INVALID_ARGUMENT", detail: "A point arrangement coordinate is outside the usable range.")
                        }
                    }
                }
            }
            var needsGraphRender = false
            var lastVisualIntent: PaneContentKind = .schema
            for action in actions {
                guard isCurrentPoint(state, id: pointID) else { return }
                let actionType = string(action, "type")!
                if actionType == "open_table" {
                    lastVisualIntent = .tables
                } else if actionType != "set_layout" {
                    lastVisualIntent = .schema
                }
                switch actionType {
                case "show_tables":
                    let ids = Set(strings(action, "table_ids") ?? [])
                    let all = Set(session.graph.nodes.map(\.id))
                    let existing = session.automationVisibleTableIDs ?? all
                    session.requestAutomationFocusReset()
                    switch string(action, "mode") ?? "replace" {
                    case "replace": session.setAutomationVisibleTableIDs(ids)
                    case "add": session.setAutomationVisibleTableIDs(existing.union(ids))
                    case "remove": session.setAutomationVisibleTableIDs(existing.subtracting(ids))
                    case "all": session.setAutomationVisibleTableIDs(nil)
                    default: throw Failure(code: "INVALID_ARGUMENT", detail: "Invalid show_tables mode.")
                    }
                    compactSparseAutomationSubset(session)
                    session.requestAutomationViewport(fitVisibleTables: true)
                    needsGraphRender = true
                case "select_objects":
                    session.setGraphSelection(Set(strings(action, "table_ids") ?? []))
                    needsGraphRender = true
                case "expand_tables":
                    session.expandedGraphNodeIDs = Set(strings(action, "table_ids") ?? [])
                    session.requestAutomationViewport(fitVisibleTables: true)
                    needsGraphRender = true
                case "focus_keys":
                    guard let tableID = string(action, "table_id") ?? strings(action, "table_ids")?.first else {
                        throw Failure(code: "INVALID_ARGUMENT", detail: "focus_keys needs a table_id.")
                    }
                    let matchingEdges = session.graph.edges.filter { edge in
                        guard edge.sourceID == tableID || edge.targetID == tableID else { return false }
                        if let relationID = string(action, "relation_id"), edge.id != relationID { return false }
                        if let sourceColumn = string(action, "source_column"), edge.sourceColumn != sourceColumn { return false }
                        if let targetColumn = string(action, "target_column"), edge.targetColumn != targetColumn { return false }
                        return true
                    }
                    let focusedIDs = Set([tableID]).union(matchingEdges.flatMap { [$0.sourceID, $0.targetID] })
                    let currentIDs = session.automationVisibleTableIDs ?? Set(session.graph.nodes.map(\.id))
                    session.setAutomationVisibleTableIDs(currentIDs.union(focusedIDs))
                    session.setAutomationFocusCommand(AutomationGraphFocusCommand(tableID: tableID,
                        sourceColumn: string(action, "source_column"), targetColumn: string(action, "target_column"),
                        relationID: string(action, "relation_id")))
                    needsGraphRender = true
                case "set_camera":
                    let cameraMode = string(action, "mode") ?? "absolute"
                    let transitionMilliseconds = try cameraTransitionMilliseconds(action)
                    guard ["absolute", "fit_visible"].contains(cameraMode) else {
                        throw Failure(code: "INVALID_ARGUMENT", detail: "Camera mode must be absolute or fit_visible.")
                    }
                    if cameraMode == "absolute" {
                        if let zoom = number(action, "zoom") { session.graphZoom = min(4, max(0.2, zoom)) }
                        if let x = number(action, "pan_x"), let y = number(action, "pan_y") { session.graphPan = CGSize(width: x, height: y) }
                    }
                    session.requestAutomationViewport(fitVisibleTables: cameraMode == "fit_visible",
                                                      transitionMilliseconds: transitionMilliseconds)
                    needsGraphRender = true
                case "arrange_tables":
                    let ids = strings(action, "table_ids") ?? []
                    let origin = CGPoint(x: number(action, "x") ?? 0, y: number(action, "y") ?? 0)
                    session.compactGraphTables(ids, around: origin)
                    session.requestAutomationViewport(fitVisibleTables: true)
                    needsGraphRender = true
                case "set_node_sizing":
                    guard let metric = string(action, "metric").flatMap(GraphNodeSizeMetric.init(rawValue:)) else {
                        throw Failure(code: "INVALID_ARGUMENT", detail: "Invalid node sizing metric.")
                    }
                    session.setGraphNodeSizeMetric(metric, persist: false)
                    needsGraphRender = true
                case "set_layout":
                    if let fraction = number(action, "split_fraction") { session.workspaceSplitFraction = min(0.85, max(0.15, fraction)) }
                    if let left = string(action, "left_pane").flatMap(PaneContentKind.init(rawValue:)) { session.setPaneContent(left, for: .left) }
                    if let right = string(action, "right_pane").flatMap(PaneContentKind.init(rawValue:)) { session.setPaneContent(right, for: .right) }
                    lastVisualIntent = session.paneState(for: session.activePaneSide).kind
                    needsGraphRender = true
                case "open_table":
                    let id = try requiredString(action, "table_id")
                    if session.historicalExplanationArtifact != nil {
                        // Historical workspaces have no database service. Select the
                        // captured schema object and let the artifact-backed pane show
                        // any rows that were explicitly saved for this point.
                        session.selectGraphNode(id)
                        needsGraphRender = true
                        continue
                    }
                    guard let table = session.openTable(named: id, autoLoad: false) else { throw Failure(code: "OBJECT_NOT_FOUND", detail: "Table \(id) could not be opened.") }
                    session.revealSchemaForAutomation()
                    session.revealPaneForAutomation(.tables)
                    if let visible = session.automationVisibleTableIDs, !visible.contains(id) {
                        session.setAutomationVisibleTableIDs(visible.union([id]))
                        session.requestAutomationViewport(fitVisibleTables: true)
                    }
                    session.selectGraphNode(id)
                    await table.reload()
                    guard isCurrentPoint(state, id: pointID) else { return }
                    if let message = table.inlineErrorMessage {
                        throw Failure(code: "QUERY_FAILED", detail: "Table \(id) could not load: \(message)")
                    }
                    needsGraphRender = true
                default: break
                }
            }
            guard isCurrentPoint(state, id: pointID) else { return }
            let isHistoricalReplay = session.historicalExplanationArtifact != nil
            if isHistoricalReplay {
                session.selectHistoricalExplanationPoint(externalPointID: state.externalIDs[pointID])
                // The frame change must be part of the point's render acknowledgement,
                // so playback cannot advance before its saved rows have appeared.
                needsGraphRender = true
            }
            if needsGraphRender {
                if !isHistoricalReplay {
                    session.revealPaneForAutomation(lastVisualIntent, preferredSide: lastVisualIntent == .schema ? .left : .right)
                }
                session.markAutomationViewChanged()
                if session.isSchemaPaneVisiblyDisplayed {
                    state.requiredRenderRevision[pointID] = session.automationViewRevision
                }
            }
            guard isCurrentPoint(state, id: pointID) else { return }
            state.controller.markApplied(pointID: pointID)
            maybeMarkPointVisible(state)
        } catch {
            if isCurrentPoint(state, id: pointID) {
                try? restoreView(checkpointID, in: tab)
                state.controller.markFailed(pointID: pointID, message: error.localizedDescription)
            }
        }
    }

    private func maybeMarkPointVisible(_ state: PresentationState) {
        guard let point = state.controller.currentPoint,
              state.captionRendered.contains(point.id),
              hasVisibleAppWindow,
              workspaces.activeTabID == state.workspaceID,
              let tab = workspaces.tabs.first(where: { $0.id == state.workspaceID }) else { return }
        if let required = state.requiredRenderRevision[point.id], tab.session.automationRenderedViewRevision != required { return }
        state.controller.markVisible(pointID: point.id)
        switch state.controller.status {
        case .visible, .generatingAudio, .speaking, .waitingForSpeech, .waitingForHold, .waitingForNext, .waitingForPoints, .paused:
            if state.displayedPointIDs.insert(point.id).inserted { state.displayedPointOrder.append(point.id) }
        default:
            break
        }
    }

    private func presentationPayload(_ state: PresentationState) -> [String: Any] {
        let current = state.controller.currentPoint
        let tab = workspaces.tabs.first(where: { $0.id == state.workspaceID })
        return ["presentation_id": state.id, "workspace_id": state.workspaceID.uuidString,
                "title": state.title, "revision": state.revision, "status": statusLabel(state.controller.status),
                "current_point_id": nullable(current.map { state.externalIDs[$0.id] ?? $0.id.uuidString }),
                "current_caption": nullable(current?.caption),
                "narration_enabled": state.narrationEnabled,
                "current_point_has_audio": current?.narration?.isEmpty == false,
                "pending_point_ids": state.controller.pendingPoints.map { state.externalIDs[$0.id] ?? $0.id.uuidString },
                "completed_point_ids": state.controller.displayedHistory.map { state.externalIDs[$0.id] ?? $0.id.uuidString },
                "visual_state": tab.map(visualState) ?? "workspace_closed"]
    }

    private func statusLabel(_ status: LivePresentationController.Status) -> String {
        switch status {
        case .idle: "idle"
        case .preparing: "preparing"
        case .applied: "applied_waiting_for_render"
        case .visible: "visible"
        case .generatingAudio: "generating_audio"
        case .speaking: "speaking"
        case .waitingForSpeech: "waiting_for_speech"
        case .waitingForHold: "waiting_for_hold"
        case .waitingForNext: "waiting_for_next"
        case .waitingForPoints: "waiting_for_points"
        case .paused: "paused"
        case .completed: "completed"
        case .interrupted: "interrupted"
        case .failed: "failed"
        }
    }

    private func eventCursor(_ tab: WorkspaceTab) -> String {
        let presentation = currentPresentationIDByWorkspace[tab.id].flatMap { presentations[$0] }
        return fingerprint(viewRevision(tab) + ":" + String(tab.session.automationRenderedViewRevision ?? -1)
                           + ":" + (presentation.map { statusLabel($0.controller.status) + String($0.revision) } ?? "none"))
    }

    /// The stricter MCP policy runs before the database backend's own read-only
    /// transaction and, for SQLite, its separate read-only file connection.
    private func validateAutomationSQL(_ sql: String) throws {
        do { try MCPReadOnlySQLPolicy.validate(sql) }
        catch { throw Failure(code: "READ_ONLY_VIOLATION", detail: error.localizedDescription) }
    }

    private func sourceRevision(_ tab: WorkspaceTab) -> String {
        let session = tab.session
        var parts = [sourceID(tab), String(session.tables.count), String(session.graph.edges.count)]
        parts.append(contentsOf: session.tables.map { "\($0.id):\($0.columnCount):\($0.objectType.rawValue)" }.sorted())
        parts.append(contentsOf: session.graph.edges.map { "\($0.id):\($0.sourceID):\($0.targetID):\($0.sourceColumn):\($0.targetColumn)" }.sorted())
        if let set = session.migrationSet {
            parts.append("migration_version:\(session.selectedMigrationVersion ?? "latest")")
            // The replayed schema is authoritative for this workspace. Include
            // its full definitions so an equally sized, timestamp-preserving
            // edit still produces a new revision after the model is refreshed.
            parts.append(contentsOf: session.tables.compactMap { session.descriptor(named: $0.id) }
                .map { String(reflecting: $0) }.sorted())
            parts.append(contentsOf: session.migrationDiagnostics.map { String(reflecting: $0) }.sorted())
            for file in set.files(through: session.selectedMigrationVersion) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: file.url.path)
                let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                parts.append("\(file.url.path):\(modified):\(size)")
            }
        }
        if let url = session.databaseURL, let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            parts.append(String((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))
            parts.append(String((attrs[.size] as? NSNumber)?.int64Value ?? 0))
        }
        return fingerprint(parts.joined(separator: "|"))
    }

    private func viewRevision(_ tab: WorkspaceTab) -> String {
        let session = tab.session
        return fingerprint([tab.id.uuidString, sourceID(tab), session.leftPane.kind.rawValue, session.rightPane.kind.rawValue,
                            String(Double(session.workspaceSplitFraction)), session.maximizedPaneSide?.rawValue ?? "split",
                            session.activePaneSide.rawValue,
                            session.selectedGraphNodeIDs.sorted().joined(separator: ","),
                            session.expandedGraphNodeIDs.sorted().joined(separator: ","),
                            (session.automationVisibleTableIDs ?? []).sorted().joined(separator: ","),
                            String(Double(session.graphZoom)), String(Double(session.graphPan.width)), String(Double(session.graphPan.height)),
                            session.graphNodeSizeMetric.rawValue, String(session.automationViewRevision),
                            session.activeTab?.id.uuidString ?? "no-table",
                            String(describing: session.activeTab?.queryState),
                            session.queryWorkspace.activeQueryID?.uuidString ?? "no-query",
                            session.records.current?.id ?? "no-record",
                            session.records.isPresented ? "record-visible" : "record-hidden"].joined(separator: "|"))
    }

    private func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func makeResumeToken() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func resumeTokenHash(_ token: String) -> Data {
        Data(SHA256.hash(data: Data(token.utf8)))
    }

    private func matchesResumeToken(_ token: String, hash: Data) -> Bool {
        let candidate = resumeTokenHash(token)
        guard candidate.count == hash.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(candidate, hash) { difference |= left ^ right }
        return difference == 0
    }

    private func contextPayload(_ id: String, _ context: Context, resumeToken: String) -> [String: Any] {
        ["context_id": id, "client_task_id": context.taskID, "workspace_id": nullable(context.workspaceID?.uuidString),
         "resume_token": resumeToken, "recovery_status": context.recoveryStatus,
         "workspaces": availableWorkspaces(for: id).map(workspacePayload)]
    }

    private func workspacePayload(_ tab: WorkspaceTab) -> [String: Any] {
        ["workspace_id": tab.id.uuidString, "title": tab.title, "kind": tab.kind.rawValue,
         "source_id": nullable(tab.session.databaseTarget?.identity), "source_label": nullable(tab.sourceLabel),
         "source_revision": sourceRevision(tab),
         "schema_only": tab.session.databaseTarget != nil && !tab.session.databaseCapabilities.canBrowseRows,
         "can_browse_rows": tab.session.databaseCapabilities.canBrowseRows,
         "can_run_queries": tab.session.databaseCapabilities.canRunQueries,
         "active": workspaces.activeTabID == tab.id, "view_revision": viewRevision(tab)]
    }

    private func viewPayload(_ tab: WorkspaceTab) -> [String: Any] {
        let session = tab.session
        let isForeground = workspaces.activeTabID == tab.id && hasVisibleAppWindow
        let singlePaneSide = session.maximizedPaneSide ?? session.compactVisibleSide
        return ["workspace_id": tab.id.uuidString, "source_id": sourceID(tab), "source_revision": sourceRevision(tab),
                "view_revision": viewRevision(tab), "active": workspaces.activeTabID == tab.id,
                "window_visible": isForeground, "graph_visible": isForeground && session.isSchemaPaneVisiblyDisplayed,
                "visible_pane": singlePaneSide.map { session.paneState(for: $0).kind.rawValue } ?? "split",
                "left_pane": session.leftPane.kind.rawValue, "right_pane": session.rightPane.kind.rawValue,
                "split_fraction": Double(session.workspaceSplitFraction), "maximized_pane": nullable(session.maximizedPaneSide?.rawValue),
                "selected_table_ids": session.selectedGraphNodeIDs.sorted(), "expanded_table_ids": session.expandedGraphNodeIDs.sorted(),
                "visible_table_ids": session.graphVisibleTableIDs.sorted(), "zoom": Double(session.graphZoom),
                "rendered_table_ids": session.automationRenderedTableIDs.sorted(), "visual_state": visualState(tab),
                "pan": ["x": Double(session.graphPan.width), "y": Double(session.graphPan.height)],
                "node_sizing": session.graphNodeSizeMetric.rawValue,
                "node_sizing_data": nodeSizingDataPayload(session),
                "annotations": viewAnnotations.annotations(in: tab.id).map(\.payload),
                "active_table": nullable(session.activeTab?.descriptor.name),
                "active_query_id": nullable(session.queryWorkspace.activeQueryID?.uuidString)]
    }

    private func visualState(_ tab: WorkspaceTab) -> String {
        guard workspaces.activeTabID == tab.id, hasVisibleAppWindow else { return "applied_in_background" }
        guard tab.session.isSchemaPaneVisiblyDisplayed else { return "graph_not_visible" }
        return tab.session.automationRenderedViewRevision == tab.session.automationViewRevision ? "rendered_in_foreground" : "applied_waiting_for_render"
    }

    private func nodeSizingDataPayload(_ session: AppSession) -> [String: Any] {
        let data = session.graphNodeSizeData
        return ["scope": "full_catalog", "object_count": data.objectCount,
                "fields": ["minimum": nullable(data.minimumFields), "maximum": nullable(data.maximumFields)],
                "rows": ["available_count": data.availableRowCounts,
                         "minimum": nullable(data.minimumRows), "maximum": nullable(data.maximumRows)],
                "relations": ["connected_objects": data.connectedObjects,
                              "maximum": data.maximumRelations]]
    }

    private func descriptorPayload(_ descriptor: EditableTableDescriptor, session: AppSession) -> [String: Any] {
        ["id": descriptor.id, "name": descriptor.name, "kind": descriptor.objectType.rawValue,
         "description": nullable(session.tableDescription(for: descriptor.name)), "primary_key_columns": descriptor.primaryKeyColumns,
         "row_count_estimate": nullable(descriptor.rowCount),
         "columns": descriptor.columns.map { column in
             ["id": column.name, "name": column.name, "type": column.declaredType, "not_null": column.notNull,
              "primary_key_ordinal": column.primaryKeyOrdinal, "generated": column.isGenerated,
              "description": nullable(session.columnDescription(for: descriptor.name, column: column.name))] as [String: Any]
         },
         "constraints": descriptor.constraints.map { ["id": $0.id, "kind": $0.kind.rawValue, "columns": $0.columns, "detail": $0.detail] },
         "indexes": descriptor.indexes.map { ["name": $0.name, "columns": $0.columns, "unique": $0.isUnique] }]
    }

    private func edgePayload(_ edge: GraphEdge, recordRelationships: [RecordRelationship]) -> [String: Any] {
        let recordRelation = recordRelationships.first { relation in
            guard relation.sourceDescriptor?.id == edge.sourceID,
                  relation.targetDescriptor?.id == edge.targetID else { return false }
            return zip(relation.sourceColumns, relation.targetColumns).contains { source, target in
                source == edge.sourceColumn && target == edge.targetColumn
            }
        }
        return ["id": edge.id, "record_relation_id": nullable(recordRelation?.id),
                "source_table_id": edge.sourceID, "source_column": edge.sourceColumn,
                "target_table_id": edge.targetID, "target_column": edge.targetColumn,
                "cardinality": edge.cardinality.rawValue,
                "evidence": "declared_database_relation"]
    }

    private func recordGraphMappingPayload(_ mapping: RecordGraphMapping, index: Int, status: String,
                                           validationError: String?) -> [String: Any] {
        let id = boundedMappingText(mapping.id, maxUTF8Bytes: 1_024)
        let name = boundedMappingText(mapping.name, maxUTF8Bytes: 512)
        let nodeName = boundedMappingText(mapping.nodeTable.objectName, maxUTF8Bytes: 512)
        let nodeSchema = mapping.nodeTable.schemaName.map { boundedMappingText($0, maxUTF8Bytes: 512) }
        let nodeDisplayName = boundedMappingText(mapping.nodeTable.displayName, maxUTF8Bytes: 1_024)
        let edgeName = boundedMappingText(mapping.edgeTable.objectName, maxUTF8Bytes: 512)
        let edgeSchema = mapping.edgeTable.schemaName.map { boundedMappingText($0, maxUTF8Bytes: 512) }
        let edgeDisplayName = boundedMappingText(mapping.edgeTable.displayName, maxUTF8Bytes: 1_024)
        let nodeColumns = boundedMappingColumns(mapping.nodeIDColumns)
        let sourceColumns = boundedMappingColumns(mapping.sourceColumns)
        let targetColumns = boundedMappingColumns(mapping.targetColumns)
        let label = mapping.labelColumn.map { boundedMappingText($0, maxUTF8Bytes: 512) }
        let type = mapping.typeColumn.map { boundedMappingText($0, maxUTF8Bytes: 512) }
        let error = validationError.map { boundedMappingText($0, maxUTF8Bytes: 512) }
        let followable = status == "usable" && !id.truncated
        let mappingIDValue: Any = id.truncated ? NSNull() : id.value
        let mappingIDPrefix: Any = id.truncated ? id.value : NSNull()

        return [
            "mapping_id": mappingIDValue,
            "mapping_id_prefix": mappingIDPrefix,
            "mapping_id_truncated": id.truncated,
            "name": name.value,
            "name_truncated": name.truncated,
            "node_table": [
                "schema_name": nullable(nodeSchema?.value),
                "schema_name_truncated": nodeSchema?.truncated ?? false,
                "object_name": nodeName.value,
                "object_name_truncated": nodeName.truncated,
                "display_name": nodeDisplayName.value,
                "display_name_truncated": nodeDisplayName.truncated
            ],
            "node_id_columns": nodeColumns.values,
            "node_id_columns_count": mapping.nodeIDColumns.count,
            "node_id_columns_truncated": nodeColumns.truncated,
            "label_column": nullable(label?.value),
            "label_column_truncated": label?.truncated ?? false,
            "edge_table": [
                "schema_name": nullable(edgeSchema?.value),
                "schema_name_truncated": edgeSchema?.truncated ?? false,
                "object_name": edgeName.value,
                "object_name_truncated": edgeName.truncated,
                "display_name": edgeDisplayName.value,
                "display_name_truncated": edgeDisplayName.truncated
            ],
            "source_columns": sourceColumns.values,
            "source_columns_count": mapping.sourceColumns.count,
            "source_columns_truncated": sourceColumns.truncated,
            "target_columns": targetColumns.values,
            "target_columns_count": mapping.targetColumns.count,
            "target_columns_truncated": targetColumns.truncated,
            "type_column": nullable(type?.value),
            "type_column_truncated": type?.truncated ?? false,
            "directed": mapping.isDirected,
            "node_scope": boundedMappingFilters(mapping.nodeScope),
            "edge_scope": boundedMappingFilters(mapping.edgeScope),
            "validation_status": status,
            "followable": followable,
            "validation_error": nullable(error?.value),
            "validation_error_truncated": error?.truncated ?? false,
            "provenance": ["kind": "source_sidecar", "field": "recordGraphMappings", "index": index]
        ]
    }

    private func boundedMappingColumns(_ columns: [String]) -> (values: [String], truncated: Bool) {
        let entries = columns.prefix(16).map { boundedMappingText($0, maxUTF8Bytes: 512) }
        return (entries.map { $0.value }, columns.count > 16 || entries.contains { $0.truncated })
    }

    private func boundedMappingFilters(_ filters: [RecordMappingFilter]) -> [[String: Any]] {
        filters.prefix(16).map { filter in
            let column = boundedMappingText(filter.column, maxUTF8Bytes: 512)
            var payload: [String: Any] = [
                "column": column.value,
                "column_truncated": column.truncated
            ]
            switch filter.value {
            case .null:
                payload["type"] = "null"
                payload["value"] = NSNull()
            case .integer(let value):
                payload["type"] = "integer"
                payload["value"] = value
            case .double(let value):
                payload["type"] = "double"
                if value.isFinite { payload["value"] = value }
                else { payload["value"] = String(value) }
            case .boolean(let value):
                payload["type"] = "boolean"
                payload["value"] = value
            case .text(let value):
                addBoundedMappingString(value, type: "text", to: &payload)
            case .exactNumeric(let value):
                addBoundedMappingString(value, type: "exactNumeric", to: &payload)
            case .uuid(let value):
                addBoundedMappingString(value, type: "uuid", to: &payload)
            case .dateTime(let value):
                addBoundedMappingString(value, type: "dateTime", to: &payload)
            case .json(let value):
                addBoundedMappingString(value, type: "json", to: &payload)
            case .array(let value):
                addBoundedMappingString(value, type: "array", to: &payload)
            case .blob(let value):
                payload["type"] = "blob"
                payload["value"] = NSNull()
                payload["value_omitted"] = true
                payload["byte_count"] = value.count
            }
            return payload
        }
    }

    private func addBoundedMappingString(_ value: String, type: String, to payload: inout [String: Any]) {
        let bounded = boundedMappingText(value, maxUTF8Bytes: 512)
        payload["type"] = type
        payload["value"] = bounded.value
        payload["value_truncated"] = bounded.truncated
        if bounded.truncated { payload["value_utf8_bytes_at_least"] = 513 }
    }

    private func boundedMappingText(_ value: String, maxUTF8Bytes: Int) -> (value: String, truncated: Bool) {
        var result = ""
        var byteCount = 0
        for scalar in value.unicodeScalars {
            let scalarBytes = scalar.utf8.count
            guard byteCount + scalarBytes <= maxUTF8Bytes else { return (result, true) }
            result.unicodeScalars.append(scalar)
            byteCount += scalarBytes
        }
        return (result, false)
    }

    private func positionPayload(_ tab: WorkspaceTab, ids: [String]) -> [[String: Any]] {
        ids.map { id in let point = tab.session.graphLayout.position(for: id)
            return ["table_id": id, "x": Double(point.x), "y": Double(point.y)] }
    }

    private func groupHints(_ raw: [[String: Any]], session: AppSession) throws -> [SchemaSidecar.ClusterHint] {
        let valid = Set(session.graph.nodes.map(\.id))
        var seen = Set<String>()
        return try raw.map { item in
            let id = try requiredString(item, "id")
            guard seen.insert(id).inserted else {
                throw Failure(code: "INVALID_ARGUMENT", detail: "Group IDs must be unique in one update.")
            }
            let tables = strings(item, "table_ids") ?? strings(item, "tables") ?? []
            guard Set(tables).isSubset(of: valid) else {
                throw Failure(code: "OBJECT_NOT_FOUND", detail: "Group \(id) contains a table outside this source.")
            }
            return SchemaSidecar.ClusterHint(id: id, label: string(item, "label"), tables: tables,
                                             color: string(item, "color"))
        }
    }

    private func groupPayload(_ session: AppSession) -> [[String: Any]] {
        session.graphGrouping.groups.map { group in
            ["id": group.id, "label": group.label, "table_ids": group.nodeIDs,
             "color": group.colorHex, "inferred": group.isInferred] as [String: Any]
        }
    }

    private func recordDirections(_ args: [String: Any], allowBoth: Bool = false) throws -> [RecordDirection] {
        switch string(args, "direction") ?? "outgoing" {
        case "outgoing": return [.outgoing]
        case "incoming": return [.incoming]
        case "both" where allowBoth: return [.outgoing, .incoming]
        default: throw Failure(code: "INVALID_ARGUMENT", detail: allowBoth
            ? "direction must be incoming, outgoing, or both."
            : "Follow one relationship direction at a time: incoming or outgoing.")
        }
    }

    private func relationIsIncident(_ relation: RecordRelationship, to record: RecordSnapshot,
                                    direction: RecordDirection) -> Bool {
        guard let table = record.table else { return false }
        return direction == .outgoing ? relation.sourceTable == table : relation.targetTable == table
    }

    private func tablePayload(_ table: TableTabModel, workspace: WorkspaceTab) -> [String: Any] {
        ["workspace_id": workspace.id.uuidString, "table_id": table.descriptor.id, "table_tab_id": table.id.uuidString,
         "schema_only": !workspace.session.databaseCapabilities.canBrowseRows,
         "loaded_rows": table.chunk.rows.count, "offset": table.chunk.offset, "has_more": table.chunk.hasMore,
         "error": nullable(table.inlineErrorMessage), "view_revision": viewRevision(workspace)]
    }

    private func queryPayload(_ result: QueryResult, id: String, tab: WorkspaceTab, offset: Int = 0, limit: Int = 100) -> [String: Any] {
        let page = Array(result.rows.dropFirst(offset).prefix(limit))
        return ["result_id": id, "workspace_id": tab.id.uuidString, "row_count": result.rows.count,
         "offset": offset, "returned_rows": page.count, "has_more": offset + page.count < result.rows.count,
         "source_truncated": result.isTruncated,
         "columns": result.columns.map { ["id": $0.id, "name": $0.name, "type": $0.typeLabel] as [String: Any] },
         "rows": page.map { ["id": $0.id, "values": $0.values.map(valuePayload)] as [String: Any] }]
    }

    private func queryJobPayload(_ job: QueryJobState) -> [String: Any] {
        var payload: [String: Any] = [
            "job_id": job.id, "kind": "query", "status": job.status,
            "workspace_id": job.workspaceID.uuidString, "source_id": job.sourceID,
            "source_revision": job.sourceRevision, "timeout_seconds": job.timeoutSeconds,
            "row_limit": job.rowLimit, "result_id": nullable(job.resultID),
            "error": nullable(job.error),
        ]
        if let resultID = job.resultID,
           let saved = results[resultID], saved.workspace == job.workspaceID,
           saved.ownerContextID == job.contextID,
           let tab = workspaces.tabs.first(where: { $0.id == job.workspaceID }),
           saved.sourceID == sourceID(tab), saved.sourceRevision == sourceRevision(tab) {
            payload["result_preview"] = queryJobResultPreview(saved.result, id: resultID, tab: tab)
        } else if job.status == "completed" {
            if let resultID = job.resultID { results.removeValue(forKey: resultID) }
            job.resultID = nil
            job.status = "failed"
            job.error = "The source or workspace changed before the result could be read. Run the query again against the current source."
            payload["status"] = job.status
            payload["result_id"] = NSNull()
            payload["error"] = job.error ?? "The query result is no longer available."
        }
        return payload
    }

    /// Keep polling responses small even when the original query selected many
    /// columns or very long values. The immutable result remains available via
    /// studio_fetch_query_results and can be displayed in the native grid.
    private func queryJobResultPreview(_ result: QueryResult, id: String, tab: WorkspaceTab) -> [String: Any] {
        let columnLimit = 20
        let rowLimit = 10
        let cellTextLimit = 256
        let columns = Array(result.columns.prefix(columnLimit))
        let rows = Array(result.rows.prefix(rowLimit))
        let rowPayload: [[String: Any]] = rows.map { row in
            let values = row.values.prefix(columnLimit).map { value -> [String: Any] in
                switch value {
                case .null: return ["type": "null", "value": NSNull()]
                case .blob(let data): return ["type": "blob", "byte_count": data.count, "value": NSNull()]
                default:
                    let text = value.editorText
                    return ["type": value.typeLabel.lowercased(), "value": String(text.prefix(cellTextLimit)),
                            "truncated": text.count > cellTextLimit]
                }
            }
            return ["id": row.id, "values": values,
                    "omitted_value_count": max(0, row.values.count - columnLimit)]
        }
        return ["result_id": id, "workspace_id": tab.id.uuidString,
                "row_count": result.rows.count, "returned_rows": rows.count,
                "has_more_rows": result.rows.count > rows.count,
                "source_truncated": result.isTruncated,
                "columns": columns.map { ["id": $0.id, "name": $0.name, "type": $0.typeLabel] as [String: Any] },
                "omitted_column_count": max(0, result.columns.count - columns.count),
                "rows": rowPayload]
    }

    private func valuePayload(_ value: SQLiteValue) -> [String: Any] {
        switch value {
        case .null: return ["type": "null", "value": NSNull()]
        case .blob(let data): return ["type": "blob", "byte_count": data.count, "value": NSNull()]
        default:
            let text = value.editorText
            return ["type": value.typeLabel.lowercased(), "value": String(text.prefix(4096)), "truncated": text.count > 4096]
        }
    }

    private func boundedCellPayload(_ read: BoundedCellRead) -> [String: Any] {
        var payload: [String: Any] = ["type": read.storageType, "is_null": read.isNull]
        switch read.value {
        case .null:
            payload["value"] = NSNull()
            if read.isBinary { payload["value_base64"] = NSNull() }
        case .blob(let data):
            payload["value"] = NSNull()
            payload["value_base64"] = data.base64EncodedString()
        default:
            payload["value"] = read.value.editorText
        }
        return payload
    }

    private func requiredString(_ args: [String: Any], _ key: String, alternative: String? = nil) throws -> String {
        if let value = string(args, key) ?? alternative.flatMap({ string(args, $0) }), !value.isEmpty { return value }
        throw Failure(code: "INVALID_ARGUMENT", detail: "Provide \(key).")
    }

    private func cameraTransitionMilliseconds(_ args: [String: Any]) throws -> Int {
        guard args["transition_ms"] != nil else { return 420 }
        guard let value = number(args, "transition_ms"), value.isFinite,
              value.rounded(.towardZero) == value, (0...1_200).contains(value) else {
            throw Failure(code: "INVALID_ARGUMENT", detail: "transition_ms must be a whole number from 0 to 1200.")
        }
        return Int(value)
    }

    private func string(_ args: [String: Any], _ key: String) -> String? { args[key] as? String }
    private func nullable(_ value: Any?) -> Any { value ?? NSNull() }
    private func strings(_ args: [String: Any], _ key: String) -> [String]? { args[key] as? [String] }
    private func bool(_ args: [String: Any], _ key: String) -> Bool? { args[key] as? Bool }
    private func number(_ args: [String: Any], _ key: String) -> Double? { (args[key] as? NSNumber)?.doubleValue }
    private func bounded(_ args: [String: Any], _ key: String, default fallback: Int, maximum: Int) -> Int {
        min(maximum, max(1, args[key] as? Int ?? fallback))
    }

    private func recovery(for code: String) -> String {
        switch code {
        case "CONTEXT_REQUIRED": "Call studio_connect_context."
        case "CONTEXT_EXPIRED": "Create a new context and explicitly select the intended workspace; the prior task state expired."
        case "CONTEXT_IN_USE": "Close the other MCP connection for this task before resuming it."
        case "RESUME_DENIED": "Use the resume_token and client_task_id returned to this task when it connected, or start a new context."
        case "AMBIGUOUS_WORKSPACE": "Call studio_list_workspaces and pass workspace_id."
        case "PROJECT_SELECTION_REQUIRED": "Call studio_scan_project, choose one exact candidate source_path, and call studio_open_source with a new request_id."
        case "SCHEMA_ONLY_SOURCE": "Use schema and graph tools for this migration model, or open a database source to inspect rows and run queries."
        case "WORKSPACE_IN_USE": "Use an available tab or ask the user to release the foreground tab from Graph Studio's Coding Agents menu."
        case "WORKSPACE_LIMIT_REACHED": "Reuse this task's current source, or close unused Graph Studio tabs before opening another workspace."
        case "STALE_SOURCE": "Call studio_get_view and use its current source_id."
        case "METADATA_CONFLICT": "Call studio_get_annotations again, merge the user's intended changes, and retry with the returned metadata_revision and a new request_id."
        case "TOOL_UNAVAILABLE": "Use an available Graph Studio action or perform this step directly in the app."
        default: "Inspect the current workspace and correct the request."
        }
    }

    private static func result(_ message: String, _ structured: [String: Any], error: Bool = false) -> Data {
        let response: [String: Any] = ["content": [["type": "text", "text": message]], "structuredContent": structured, "isError": error]
        guard let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) else {
            return Data("{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"Result serialization failed.\"}]}".utf8)
        }
        guard data.count <= 1_048_576 else {
            return Data("{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"The tool response exceeded 1 MiB. Narrow the tables, columns, or row limit and retry.\"}],\"structuredContent\":{\"error\":{\"code\":\"LIMIT_REACHED\",\"recovery\":\"Narrow the request and retry.\"}}}".utf8)
        }
        return data
    }
}
