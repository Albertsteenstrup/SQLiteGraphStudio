import Foundation

/// Standalone Foundation regression suite: no app launch or package dependency build.
@main
enum PreferencesMigrationTests {
    static func main() throws {
        let defaults = UserDefaults.standard
        let prefix = "SQLiteGraphStudio.migration-test.\(UUID().uuidString)"
        let source = "\(prefix).legacy"
        let destination = "\(prefix).canonical"
        defer {
            defaults.removePersistentDomain(forName: source)
            defaults.removePersistentDomain(forName: destination)
        }

        let savedKey = "SQLiteGraphStudio.saved-queries./fixture.sqlite"
        let historyKey = "SQLiteGraphStudio.query-history./fixture.sqlite"
        let layoutKey = "SQLiteGraphStudio.graph-layout.v2./fixture.sqlite"
        let storyKey = "SQLiteGraphStudio.story-graph-layout./fixture.sqlite"
        let recentKey = "SQLiteGraphStudio.recent-databases"
        let legacy: [String: Any] = [
            savedKey: Data("legacy saved".utf8), historyKey: Data("legacy history".utf8),
            layoutKey: Data("legacy layout".utf8), storyKey: Data("legacy story layout".utf8),
            recentKey: ["/fixture.sqlite"], "unrelated.preference": "do not copy",
            "SQLiteGraphStudio.graph-layout.v1./fixture.sqlite": Data("unsupported version".utf8)
        ]
        defaults.setPersistentDomain(legacy, forName: source)
        defaults.setPersistentDomain([savedKey: Data("current saved".utf8), "existing": false], forName: destination)
        PreferenceDomainMigration.migrate(defaults: defaults, destinationDomain: destination, legacyDomain: source)
        let merged = defaults.persistentDomain(forName: destination) ?? [:]
        try expect(merged[historyKey] as? Data == legacy[historyKey] as? Data, "copies missing query history")
        try expect(merged[layoutKey] as? Data == legacy[layoutKey] as? Data, "copies compatible graph layout")
        try expect(merged[storyKey] as? Data == legacy[storyKey] as? Data, "copies story layout")
        try expect(merged[recentKey] as? [String] == ["/fixture.sqlite"], "copies recent documents")
        try expect(merged[savedKey] as? Data == Data("current saved".utf8), "keeps existing canonical saved queries")
        try expect(merged["existing"] as? Bool == false, "preserves unrelated existing values")
        try expect(merged["unrelated.preference"] == nil, "does not import unrelated legacy settings")
        try expect(merged["SQLiteGraphStudio.graph-layout.v1./fixture.sqlite"] == nil, "does not migrate obsolete layout versions")
        try expect(NSDictionary(dictionary: defaults.persistentDomain(forName: source) ?? [:]).isEqual(to: legacy), "leaves legacy domain intact")

        var edited = merged
        edited.removeValue(forKey: historyKey)
        defaults.setPersistentDomain(edited, forName: destination)
        PreferenceDomainMigration.migrate(defaults: defaults, destinationDomain: destination, legacyDomain: source)
        try expect(defaults.persistentDomain(forName: destination)?[historyKey] == nil, "does not resurrect intentionally removed preferences on later launch")

        defaults.removePersistentDomain(forName: destination)
        PreferenceDomainMigration.migrate(defaults: defaults, destinationDomain: destination, legacyDomain: source)
        try expect(defaults.persistentDomain(forName: destination)?[savedKey] as? Data == legacy[savedKey] as? Data, "migrates saved queries on first canonical launch")
        print("PASS: preference migration preserves existing state, imports compatible keys, and runs once")
    }

    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "PreferencesMigrationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
