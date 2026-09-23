import AppKit
import StudioMCP
import SwiftUI

struct CodingAgentSetupSheet: View {
    let scope: MCPSetupScope
    let projectDirectory: URL?
    let preview: MCPSetupPreview?
    let report: MCPSetupReport?
    let isChecking: Bool
    let isInstalling: Bool
    let onReview: (MCPSetupScope, URL?) -> Void
    let onInstall: (MCPSetupScope, URL?) -> Void
    let onDone: () -> Void
    @State private var selectedScope: MCPSetupScope
    @State private var selectedProjectDirectory: URL?

    init(
        scope: MCPSetupScope,
        projectDirectory: URL?,
        preview: MCPSetupPreview?,
        report: MCPSetupReport?,
        isChecking: Bool,
        isInstalling: Bool,
        onReview: @escaping (MCPSetupScope, URL?) -> Void,
        onInstall: @escaping (MCPSetupScope, URL?) -> Void,
        onDone: @escaping () -> Void
    ) {
        self.scope = scope
        self.projectDirectory = projectDirectory
        self.preview = preview
        self.report = report
        self.isChecking = isChecking
        self.isInstalling = isInstalling
        self.onReview = onReview
        self.onInstall = onInstall
        self.onDone = onDone
        _selectedScope = State(initialValue: scope)
        _selectedProjectDirectory = State(initialValue: projectDirectory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: report == nil ? "point.3.connected.trianglepath.dotted" : "checkmark.circle")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(report == nil ? "Set up coding agents" : "Setup results")
                        .font(.title2.weight(.semibold))
                    Text(report == nil
                         ? "Review the selected Codex and Claude Code changes before applying them."
                         : "Here is what the installer changed and what it left alone.")
                        .foregroundStyle(.secondary)
                }
            }

            scopePicker

            if selectedScope == .project && selectedProjectDirectory == nil {
                chooseProjectPrompt
            } else if !previewMatchesSelection && !isChecking && !isInstalling && report == nil {
                ProgressView("Preparing the selected setup review…")
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            } else if isChecking {
                ProgressView("Checking the bundled helper and existing setup…")
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            } else if isInstalling {
                ProgressView("Applying the reviewed setup…")
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            } else if let report {
                resultContent(report)
            } else if let preview {
                reviewContent(preview)
            } else {
                ContentUnavailableView("Setup preview unavailable", systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, minHeight: 160)
            }

            HStack {
                if report == nil && !isChecking && !isInstalling {
                    Button("Cancel", action: onDone)
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Install reviewed changes") {
                        onInstall(selectedScope, selectedScope == .project ? selectedProjectDirectory : nil)
                    }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!previewMatchesSelection || preview?.canInstall != true)
                } else if report != nil {
                    Spacer()
                    Button("Done", action: onDone)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 620, height: 620)
        .interactiveDismissDisabled(isInstalling)
    }

    private var scopePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Setup scope", selection: $selectedScope) {
                ForEach(MCPSetupScope.allCases, id: \.self) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isChecking || isInstalling || report != nil)
            .onChange(of: selectedScope) { _, value in
                if value == .user {
                    selectedProjectDirectory = nil
                    onReview(.user, nil)
                } else if let selectedProjectDirectory {
                    onReview(.project, selectedProjectDirectory)
                }
            }

            if selectedScope == .project {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selectedProjectDirectory?.path ?? "Choose a project folder")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Text("MCP config and skills will be saved in this folder. Codex project config applies after you trust the project.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(selectedProjectDirectory == nil ? "Choose Folder…" : "Change…", action: chooseProjectDirectory)
                        .disabled(isChecking || isInstalling || report != nil)
                }
            }
        }
    }

    private var chooseProjectPrompt: some View {
        ContentUnavailableView {
            Label("Choose a project folder", systemImage: "folder.badge.questionmark")
        } description: {
            Text("The preview is read-only. Select the folder where this project's MCP connection and agent skills should live.")
        } actions: {
            Button("Choose Project Folder…", action: chooseProjectDirectory)
                .disabled(isChecking || isInstalling)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    private var previewMatchesSelection: Bool {
        guard let preview, preview.scope == selectedScope else { return false }
        guard selectedScope == .project else { return true }
        return preview.projectDirectoryPath == selectedProjectDirectory?.standardizedFileURL.path
    }

    private func chooseProjectDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose a project folder"
        panel.message = "SQLite Graph Studio will add project-scoped MCP configuration and skills here after you review the changes."
        panel.prompt = "Use Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        if panel.runModal() == .OK, let url = panel.url {
            selectedProjectDirectory = url.standardizedFileURL
            onReview(.project, selectedProjectDirectory)
        }
    }

    private func reviewContent(_ preview: MCPSetupPreview) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("No changes have been made. Choosing Install will apply only the available items listed below. Existing name conflicts and blocked skill paths will be left untouched.")
                    .font(.callout)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

                section("MCP connections", systemImage: "point.3.connected.trianglepath.dotted") {
                    if let helperPath = preview.helperPath {
                        Text("Helper: \(helperPath)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Bundled StudioMCP helper was not found.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    ForEach(Array(preview.clients.enumerated()), id: \.offset) { _, plan in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(clientName(plan.client)).fontWeight(.medium)
                                Spacer()
                                Text(clientState(plan.state))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(clientColor(plan.state))
                            }
                            Text(plan.message)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            if let cliPath = plan.cliPath {
                                if let cliVersion = plan.cliVersion {
                                    Text("Version: \(cliVersion)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Text("CLI: \(cliPath)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                section("Agent skills", systemImage: "sparkles") {
                    ForEach(Array(preview.skills.enumerated()), id: \.offset) { _, plan in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(clientName(plan.client)) · \(plan.rootPath)")
                                .fontWeight(.medium)
                            Text(plan.summary)
                                .font(.callout)
                                .foregroundStyle(plan.state == .blocked ? Color.orange : Color.secondary)
                            ForEach(Array(plan.blockers.enumerated()), id: \.offset) { _, blocker in
                                Label(blocker, systemImage: "hand.raised.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            let changes = plan.install.map { ("Install", $0) }
                                + plan.update.map { ("Update", $0) }
                                + plan.retiredManaged.map { ("Remove managed retired", $0) }
                            if !changes.isEmpty {
                                DisclosureGroup("Planned skill file changes (\(changes.count))") {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(Array(changes.enumerated()), id: \.offset) { _, item in
                                            Text("\(item.0): \(item.1)")
                                                .font(.caption.monospaced())
                                                .textSelection(.enabled)
                                        }
                                    }
                                    .padding(.top, 6)
                                }
                                .font(.caption)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if !preview.canInstall {
                    Label("There are no safe setup changes available. Close this review after addressing the blockers above.", systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func resultContent(_ report: MCPSetupReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("MCP connections", systemImage: "point.3.connected.trianglepath.dotted") {
                    ForEach(Array(report.clients.enumerated()), id: \.offset) { _, outcome in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(clientName(outcome.client)).fontWeight(.medium)
                                Spacer()
                                Text(outcome.verification?.succeeded == false ? "Check failed" : outcome.state.rawValue.capitalized)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(
                                        outcome.verification?.succeeded == false
                                            ? Color.orange
                                            : (outcome.state == .installed || outcome.state == .alreadyInstalled ? Color.green : Color.orange)
                                    )
                            }
                            Text(outcome.message).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }

                section("Agent skills", systemImage: "sparkles") {
                    Text(report.skills.summary)
                        .font(.callout)
                    skillResults("Installed", report.skills.installed)
                    skillResults("Updated", report.skills.updated)
                    skillResults("Already current", report.skills.alreadyCurrent)
                    skillResults("Customized files preserved", report.skills.customizedPreserved)
                    skillResults("Managed retired files removed", report.skills.retiredRemoved)
                    skillResults("Customized retired files preserved", report.skills.retiredCustomizedPreserved)
                    skillResults("Errors", report.skills.errors)
                }
            }
        }
    }

    @ViewBuilder
    private func skillResults(_ title: String, _ values: [String]) -> some View {
        if !values.isEmpty {
            DisclosureGroup("\(title) (\(values.count))") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(values, id: \.self) { value in
                        Text(value).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                .padding(.top, 5)
            }
            .font(.caption)
        }
    }

    private func section<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.quaternary))
    }

    private func clientName(_ client: MCPSetupClient) -> String {
        client == .codex ? "Codex" : "Claude Code"
    }

    private func clientState(_ state: MCPSetupClientPlan.State) -> String {
        switch state {
        case .willRegister: "Will register"
        case .alreadyRegistered: "Already set up"
        case .nameConflict: "Existing entry preserved"
        case .cliUnavailable: "CLI unavailable"
        case .helperUnavailable: "Helper unavailable"
        case .projectDirectoryRequired: "Choose project folder"
        case .unsafeDestination: "Unsafe destination"
        }
    }

    private func clientColor(_ state: MCPSetupClientPlan.State) -> Color {
        switch state {
        case .willRegister, .alreadyRegistered: .green
        case .nameConflict, .cliUnavailable, .helperUnavailable, .projectDirectoryRequired, .unsafeDestination: .orange
        }
    }
}
