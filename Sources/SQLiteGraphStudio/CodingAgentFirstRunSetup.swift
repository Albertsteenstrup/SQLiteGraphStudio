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

    private static let reviewedClientsKey = "codingAgentSetupFirstRunReviewedClients"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var reviewedClients: Set<String> {
        Set(defaults.stringArray(forKey: Self.reviewedClientsKey) ?? [])
    }

    var shouldCheck: Bool {
        MCPSetupClient.allCases.contains { !reviewedClients.contains($0.rawValue) }
    }

    func decision(for preview: MCPSetupPreview) -> Decision {
        guard preview.helperPath != nil else { return .deferUntilClientAvailable }
        let availableClients = preview.clients.filter {
            $0.cliPath != nil && !reviewedClients.contains($0.client.rawValue)
        }
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

    func markReviewed(for preview: MCPSetupPreview) {
        let available = preview.clients.compactMap { $0.cliPath == nil ? nil : $0.client.rawValue }
        defaults.set(Array(reviewedClients.union(available)).sorted(), forKey: Self.reviewedClientsKey)
    }
}
