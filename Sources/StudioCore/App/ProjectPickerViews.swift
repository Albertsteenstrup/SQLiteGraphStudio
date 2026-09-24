import SwiftUI

/// Shown while a chosen project folder is being searched. Deep trees take a
/// moment, so the running counts make it clear the search is progressing and
/// the Cancel button stays reachable throughout.
struct ProjectScanOverlayView: View {
    let state: ProjectScanState
    let onCancel: () -> Void

    @State private var sweep = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(StudioPalette.borderSoft, lineWidth: 3)
                    .frame(width: 46, height: 46)
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(StudioPalette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 46, height: 46)
                    .rotationEffect(.degrees(sweep ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: sweep)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StudioPalette.secondaryText)
            }
            .onAppear { sweep = true }

            VStack(spacing: 6) {
                Text(state.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(StudioPalette.primaryText)
                Text(state.detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(StudioPalette.secondaryText)
                Text(state.progress.currentRelativePath.isEmpty ? " " : state.progress.currentRelativePath)
                    .font(.caption2)
                    .foregroundStyle(StudioPalette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 360)
                    .animation(nil, value: state.progress.currentRelativePath)
            }

            Button("Cancel", action: onCancel)
                .controlSize(.regular)
        }
        .padding(28)
        .frame(minWidth: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(StudioPalette.border, lineWidth: 1)
        }
        .shadow(color: StudioPalette.shadow, radius: 24, y: 12)
    }
}

/// Presented when a search found more than one thing to open. A migration set
/// can be opened at any of its versions; the newest one is preselected.
struct ProjectCandidatePickerView: View {
    @Bindable var session: AppSession
    let choice: ProjectCandidateChoice

    @State private var selectedID: String?
    @State private var version: String?
    @Environment(\.dismiss) private var dismiss

    private var selected: ProjectCandidate? {
        choice.candidates.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Open from \(choice.root.lastPathComponent)")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(StudioPalette.primaryText)
                Text(choice.summary)
                    .font(.caption)
                    .foregroundStyle(StudioPalette.secondaryText)
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 14)

            Divider()

            List(selection: $selectedID) {
                ForEach(ProjectCandidateKind.allCases, id: \.self) { kind in
                    let matches = choice.candidates.filter { $0.kind == kind }
                    if !matches.isEmpty {
                        Section(kind.displayName) {
                            ForEach(matches) { candidate in
                                ProjectCandidateRow(candidate: candidate)
                                    .tag(candidate.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { open(candidate) }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 260)

            Divider()

            HStack(spacing: 12) {
                if let candidate = selected, let set = candidate.migrationSet, set.files.count > 1 {
                    MigrationVersionPicker(set: set, selection: $version, label: "Open at")
                } else {
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                Button("Cancel") {
                    session.dismissProjectCandidates()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Open") {
                    if let candidate = selected { open(candidate) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
        }
        .frame(width: 640, height: 480)
        .onAppear {
            // With multiple choices, require an actual selection instead of
            // making Return silently open the first migration set.
            if choice.candidates.count == 1 {
                selectedID = choice.candidates.first?.id
                version = choice.candidates.first?.migrationSet?.latest?.version
            }
        }
        .onChange(of: selectedID) { _, _ in
            version = selected?.migrationSet?.latest?.version
        }
    }

    private func open(_ candidate: ProjectCandidate) {
        session.openCandidate(candidate, migrationVersion: candidate.migrationSet == nil ? nil : version)
        dismiss()
    }
}

private struct ProjectCandidateRow: View {
    let candidate: ProjectCandidate

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: candidate.kind.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StudioPalette.secondaryText)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudioPalette.primaryText)
                    .lineLimit(1)
                Text(candidate.relativePath)
                    .font(.caption)
                    .foregroundStyle(StudioPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text(candidate.detail)
                .font(.caption.monospacedDigit())
                .foregroundStyle(StudioPalette.tertiaryText)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

/// The list of versions, newest first. Long histories are grouped so a menu
/// over hundreds of migrations stays navigable.
struct MigrationVersionMenuContent: View {
    let set: MigrationSet
    let select: (String) -> Void

    private static let groupSize = 40

    var body: some View {
        let files = Array(set.files.reversed())
        if files.count <= Self.groupSize {
            ForEach(files) { file in button(for: file) }
        } else {
            ForEach(Array(stride(from: 0, to: files.count, by: Self.groupSize)), id: \.self) { start in
                let group = Array(files[start..<min(start + Self.groupSize, files.count)])
                Menu(groupTitle(group)) {
                    ForEach(group) { file in button(for: file) }
                }
            }
        }
    }

    private func groupTitle(_ group: [MigrationFile]) -> String {
        guard let newest = group.first, let oldest = group.last else { return "" }
        return newest.version == oldest.version ? newest.version : "\(newest.version) … \(oldest.version)"
    }

    private func button(for file: MigrationFile) -> some View {
        Button(file.version == set.latest?.version ? "\(file.displayLabel)  (latest)" : file.displayLabel) {
            select(file.version)
        }
    }
}

/// Chooses which migration a model is replayed through. The newest is the
/// default everywhere; picking an older one shows the schema as it stood then.
struct MigrationVersionPicker: View {
    let set: MigrationSet
    @Binding var selection: String?
    var label: String = "Open at"

    private var resolved: MigrationFile? {
        self.set.files.first { $0.version == selection } ?? self.set.latest
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(StudioPalette.secondaryText)
            Menu {
                MigrationVersionMenuContent(set: set) { selection = $0 }
            } label: {
                Text(resolved.map { $0.version == set.latest?.version ? "\($0.displayLabel)  (latest)" : $0.displayLabel } ?? "—")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Replay the migrations up to and including this one")
        }
    }
}

/// The in-app version control. It sits in the pane header next to the document
/// name so the schema can be stepped through without reopening the folder.
struct MigrationVersionControl: View {
    @Bindable var session: AppSession

    private var set: MigrationSet? { session.migrationSet }

    private var appliedIndex: Int? {
        guard let set else { return nil }
        guard let version = session.selectedMigrationVersion else { return set.files.count - 1 }
        return set.index(ofVersion: version)
    }

    var body: some View {
        if let set, let appliedIndex {
            HStack(spacing: 6) {
                Button {
                    session.selectMigrationVersion(set.files[appliedIndex - 1].version)
                } label: {
                    Image(systemName: "chevron.left").font(.caption2.weight(.bold))
                }
                .buttonStyle(.plain)
                .disabled(appliedIndex == 0 || session.isRefreshing)
                .help("Step back one migration")

                Menu {
                    MigrationVersionMenuContent(set: set) { session.selectMigrationVersion($0) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.caption2.weight(.semibold))
                        Text("\(appliedIndex + 1) / \(set.files.count)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(session.migrationReplaySummary ?? "Choose which migration to replay through")

                Button {
                    session.selectMigrationVersion(set.files[appliedIndex + 1].version)
                } label: {
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                }
                .buttonStyle(.plain)
                .disabled(appliedIndex >= set.files.count - 1 || session.isRefreshing)
                .help("Step forward one migration")
            }
            .foregroundStyle(StudioPalette.primaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(StudioPalette.chromeFillStrong))
            .overlay { Capsule().stroke(StudioPalette.border, lineWidth: 1) }
        }
    }
}
