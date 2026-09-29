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
        let preview = MCPSetupPreview(
            helperPath: helperPath,
            clients: [
                plan(.codex, .willRegister, cliPath: "/usr/local/bin/codex"),
                plan(.claude, .alreadyRegistered, cliPath: "/usr/local/bin/claude"),
            ],
            skills: []
        )

        #expect(onboarding.shouldCheck)
        #expect(preview.scope == .user)
        #expect(onboarding.decision(for: preview) == .review)
        #expect(onboarding.shouldCheck) // A read-only preview never completes onboarding.

        onboarding.markReviewed(for: preview) // The app calls this when it presents the review.
        #expect(!onboarding.shouldCheck)
    }

    @Test
    func laterCodexInstallStillGetsItsOwnGlobalSetupReview() throws {
        let suite = "CodingAgentFirstRunSetupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let onboarding = CodingAgentFirstRunSetup(defaults: defaults)
        let claudeOnly = MCPSetupPreview(
            helperPath: helperPath,
            clients: [
                plan(.codex, .cliUnavailable, cliPath: nil),
                plan(.claude, .willRegister, cliPath: "/usr/local/bin/claude"),
            ],
            skills: []
        )
        #expect(onboarding.decision(for: claudeOnly) == .review)
        onboarding.markReviewed(for: claudeOnly)
        #expect(onboarding.shouldCheck)
        #expect(onboarding.decision(for: claudeOnly) == .deferUntilClientAvailable)

        let bothInstalled = MCPSetupPreview(
            helperPath: helperPath,
            clients: [
                plan(.codex, .willRegister, cliPath: "/usr/local/bin/codex"),
                plan(.claude, .alreadyRegistered, cliPath: "/usr/local/bin/claude"),
            ],
            skills: []
        )
        #expect(onboarding.decision(for: bothInstalled) == .review)
        onboarding.markReviewed(for: bothInstalled)
        #expect(!onboarding.shouldCheck)
    }

    @Test
    func defersUntilAClientAndBundledHelperAreAvailable() throws {
        let suite = "CodingAgentFirstRunSetupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let onboarding = CodingAgentFirstRunSetup(defaults: defaults)
        let noClient = MCPSetupPreview(
            helperPath: helperPath,
            clients: [plan(.codex, .cliUnavailable, cliPath: nil)],
            skills: []
        )
        let noHelper = MCPSetupPreview(
            helperPath: nil,
            clients: [plan(.codex, .helperUnavailable, cliPath: nil)],
            skills: []
        )
        #expect(onboarding.decision(for: noClient) == .deferUntilClientAvailable)
        #expect(onboarding.decision(for: noHelper) == .deferUntilClientAvailable)
    }

    @Test
    func avoidsAReviewForAlreadyConfiguredClientButShowsNameConflict() throws {
        let suite = "CodingAgentFirstRunSetupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let onboarding = CodingAgentFirstRunSetup(defaults: defaults)
        #expect(onboarding.decision(for: previewWithCodex(.alreadyRegistered)) == .complete)
        #expect(onboarding.decision(for: previewWithCodex(.nameConflict)) == .review)
    }

    private var helperPath: String {
        "/Applications/SQLiteGraphStudio.app/Contents/MacOS/StudioMCP"
    }

    private func previewWithCodex(_ state: MCPSetupClientPlan.State) -> MCPSetupPreview {
        MCPSetupPreview(
            helperPath: helperPath,
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
