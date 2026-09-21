import Foundation

/// Live state of a project-folder search, shown while it runs.
public struct ProjectScanState: Sendable, Equatable {
    public let root: URL
    public var progress: ProjectScanProgress

    public init(root: URL, progress: ProjectScanProgress = ProjectScanProgress()) {
        self.root = root
        self.progress = progress
    }

    public var title: String { "Searching \(root.lastPathComponent)" }

    public var detail: String {
        let directories = "\(progress.directoriesVisited) folder\(progress.directoriesVisited == 1 ? "" : "s")"
        let files = "\(progress.filesInspected) file\(progress.filesInspected == 1 ? "" : "s")"
        return "\(directories) · \(files) · \(progress.candidatesFound) found"
    }
}

/// A finished scan that found more than one thing to open.
public struct ProjectCandidateChoice: Identifiable, Sendable {
    public let id = UUID()
    public let root: URL
    public let candidates: [ProjectCandidate]
    public let summary: String

    public init(root: URL, candidates: [ProjectCandidate], summary: String) {
        self.root = root
        self.candidates = candidates
        self.summary = summary
    }
}

/// Coalesces scan progress so a deep tree cannot flood the main actor.
final class ProjectScanReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPosted = Date.distantPast
    private let sink: @Sendable (ProjectScanProgress) -> Void

    init(sink: @escaping @Sendable (ProjectScanProgress) -> Void) {
        self.sink = sink
    }

    func report(_ progress: ProjectScanProgress) {
        let shouldPost: Bool = lock.withLock {
            guard Date().timeIntervalSince(lastPosted) >= 0.06 else { return false }
            lastPosted = Date()
            return true
        }
        guard shouldPost else { return }
        sink(progress)
    }
}
