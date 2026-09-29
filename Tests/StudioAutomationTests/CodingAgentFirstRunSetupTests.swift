import Foundation
import StudioMCP
import Testing
@testable import SQLiteGraphStudio

struct CodingAgentFirstRunSetupTests {
    @Test
    func firstLaunchOffersUserWideRegistrationOnceAndRequiresAnExplicitChoice() throws {
        let suite = "CodingAgentFirstRunSetupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let onboarding = CodingAgentFirstRunSetup(defaults: defaults)
        let preview = previewWithCodex(.willRegister)

        #expect(onboarding.shouldCheck)
        #expect(preview.scope == .user)
        #expect(onboarding.decision(for: preview) == .review)
        #expect(onboarding.shouldCheck) // A read-only preview never completes onboarding.

        onboarding.markReviewed() // The app calls this when it presents the review.
        #expect(!onboarding.shouldCheck)
    }

    @Test
    func defersUntilAClientAndBundledHelperAreAvailable() {
        let noClient = MCPSetupPreview(
            helperPath: "/Applications/SQLiteGraphStudio.app/Contents/MacOS/StudioMCP",
            clients: [plan(.codex, .cliUnavailable, cliPath: nil)],
            skills: []
        )
        let noHelper = MCPSetupPreview(
            helperPath: nil,
            clients: [plan(.codex, .helperUnavailable, cliPath: nil)],
            skills: []
        )
        #expect(CodingAgentFirstRunSetup().decision(for: noClient) == .deferUntilClientAvailable)
        #expect(CodingAgentFirstRunSetup().decision(for: noHelper) == .deferUntilClientAvailable)
    }

    @Test
    func avoidsAReviewForAlreadyConfiguredClientButShowsNameConflict() {
        let onboarding = CodingAgentFirstRunSetup()
        #expect(onboarding.decision(for: previewWithCodex(.alreadyRegistered)) == .complete)
        #expect(onboarding.decision(for: previewWithCodex(.nameConflict)) == .review)
    }

    private func previewWithCodex(_ state: MCPSetupClientPlan.State) -> MCPSetupPreview {
        MCPSetupPreview(
            helperPath: "/Applications/SQLiteGraphStudio.app/Contents/MacOS/StudioMCP",
            clients: [plan(.codex, state, cliPath: "/usr/local/bin/codex")],
            skills: []
        )
    }

    private func plan(
        _ client: MCPSetupClient,
        _ state: MCPSetupClientPlan.State,
        cliPath: String?
    ) -> MCPSetupClientPlan {
        MCPSetupClientPlan(client: client, state: state, cliPath: cliPath, message: "test")
    }
}
