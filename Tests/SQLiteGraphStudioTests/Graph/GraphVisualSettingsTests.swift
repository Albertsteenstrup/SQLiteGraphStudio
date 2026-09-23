import Foundation
import Testing
@testable import StudioCore

/// Covers the graph decoration switches behind View ▸ Graph Visuals.
struct GraphVisualSettingsTests {
    @Test
    func everyVisualShipsSwitchedOn() {
        let settings = GraphVisualSettings.default
        #expect(settings.isDefault)
        #expect(GraphVisual.allCases.allSatisfy { settings.isEnabled($0) })
    }

    @Test
    func switchingOneVisualLeavesTheRestAlone() {
        var settings = GraphVisualSettings.default
        settings.setEnabled(false, for: .relationPulses)

        #expect(!settings.isEnabled(.relationPulses))
        #expect(GraphVisual.allCases.filter { $0 != .relationPulses }.allSatisfy { settings.isEnabled($0) })
        #expect(!settings.isDefault)

        settings.setEnabled(true, for: .relationPulses)
        #expect(settings.isDefault)
    }

    @Test
    func turningEverythingOffAndRestoringDefaultsAreBothReachable() {
        var settings = GraphVisualSettings.default
        settings.disableAll()
        #expect(GraphVisual.allCases.allSatisfy { !settings.isEnabled($0) })

        settings.reset()
        #expect(settings.isDefault)
    }

    @Test
    func choicesSurviveARelaunch() throws {
        let defaults = try makeDefaults()
        var settings = GraphVisualSettings.default
        settings.setEnabled(false, for: .minimap)
        settings.setEnabled(false, for: .cardShadows)
        settings.save(to: defaults)

        let reloaded = GraphVisualSettings.load(from: defaults)
        #expect(reloaded == settings)
        #expect(!reloaded.isEnabled(.minimap))
        #expect(!reloaded.isEnabled(.cardShadows))
        #expect(reloaded.isEnabled(.relationPulses))
    }

    @Test
    func restoringDefaultsClearsTheStoredValueRatherThanWritingAnEmptyOne() throws {
        let defaults = try makeDefaults()
        var settings = GraphVisualSettings.default
        settings.setEnabled(false, for: .groupTitles)
        settings.save(to: defaults)
        #expect(defaults.stringArray(forKey: GraphVisualSettings.storageKey) != nil)

        settings.reset()
        settings.save(to: defaults)
        #expect(defaults.stringArray(forKey: GraphVisualSettings.storageKey) == nil)
        #expect(GraphVisualSettings.load(from: defaults).isDefault)
    }

    @Test
    func aVisualAddedInALaterVersionArrivesSwitchedOn() throws {
        // Storing the switched-off set, rather than the switched-on one, is what makes
        // this true without a migration.
        let defaults = try makeDefaults()
        defaults.set([GraphVisual.minimap.rawValue], forKey: GraphVisualSettings.storageKey)

        let loaded = GraphVisualSettings.load(from: defaults)
        #expect(!loaded.isEnabled(.minimap))
        #expect(GraphVisual.allCases.filter { $0 != .minimap }.allSatisfy { loaded.isEnabled($0) })
    }

    @Test
    func aStoredNameThatNoLongerExistsIsIgnoredRatherThanLosingTheRest() throws {
        // Downgrading after a release that added a visual must not discard the choices
        // that still apply.
        let defaults = try makeDefaults()
        defaults.set(["cardShadows", "somethingRemovedInAFutureVersion"],
                     forKey: GraphVisualSettings.storageKey)

        let loaded = GraphVisualSettings.load(from: defaults)
        #expect(loaded.disabledVisuals == [.cardShadows])
    }

    @Test
    func absentStorageMeansDefaults() throws {
        #expect(GraphVisualSettings.load(from: try makeDefaults()).isDefault)
    }

    @Test
    func everyVisualIsListedInExactlyOneMenuSection() {
        let sectioned = GraphVisual.Section.allCases.flatMap(\.visuals)
        #expect(Set(sectioned) == Set(GraphVisual.allCases))
        #expect(sectioned.count == GraphVisual.allCases.count)
    }

    @Test
    func everyVisualCarriesAMenuTitleAndTooltip() {
        for visual in GraphVisual.allCases {
            #expect(!visual.title.isEmpty)
            #expect(!visual.help.isEmpty)
        }
        #expect(Set(GraphVisual.allCases.map(\.title)).count == GraphVisual.allCases.count)
    }
}

// MARK: - Session integration

@MainActor
struct GraphVisualSessionTests {
    @Test
    func theSessionPersistsAChoiceAndReadsItBackOnTheNextLaunch() throws {
        let defaults = try makeDefaults()
        let session = AppSession(userDefaults: defaults)
        #expect(session.graphVisuals.isEnabled(.relationPulses))

        session.graphVisuals.setEnabled(false, for: .relationPulses)

        let relaunched = AppSession(userDefaults: defaults)
        #expect(!relaunched.graphVisuals.isEnabled(.relationPulses))
        #expect(relaunched.graphVisuals.isEnabled(.minimap))
    }
}

private func makeDefaults() throws -> UserDefaults {
    let suite = "GraphVisualSettingsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    return defaults
}
