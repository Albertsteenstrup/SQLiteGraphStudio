import Foundation
import StudioMCP

/// A per-user first-launch decision. A missing CLI defers the offer so installing
/// a coding agent later can still trigger the review on a subsequent launch.
struct CodingAgentFirstRunSetup {
    enum Decision: Equatable {
        case review
        case complete
        case deferUntilClientAvailable
    }

    private static let completedKey = "codingAgentSetupFirstRunReviewed"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var shouldCheck: Bool { !defaults.bool(forKey: Self.completedKey) }

    func decision(for preview: MCPSetupPreview) -> Decision {
        guard preview.helperPath != nil else { return .deferUntilClientAvailable }
        let availableClients = preview.clients.filter { $0.cliPath != nil }
        guard !availableClients.isEmpty else { return .deferUntilClientAvailable }
        let actionableClient = availableClients.contains {
            $0.state == .willRegister || $0.state == .nameConflict
        }
        let actionableSkills = preview.skills.contains { skill in
            (skill.hasChanges || skill.state == .blocked || !skill.blockers.isEmpty)
                && availableClients.contains { $0.client == skill.client }
        }
        if actionableClient || actionableSkills {
            return .review
        }
        return .complete
    }

    func markReviewed() {
        defaults.set(true, forKey: Self.completedKey)
    }
}
