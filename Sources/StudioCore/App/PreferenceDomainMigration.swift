import Foundation

public enum PreferenceDomainMigration {
    public static let canonicalBundleIdentifier = "com.albertsteenstrup.sqlitegraphstudio"
    private static let legacyBundleIdentifier = "com.albertsteenstrup.sqlite-graph-studio"
    private static let migrationKey = "SQLiteGraphStudio.preference-domain-migration.v1"

    /// Run before AppSession reads its saved state. Unbundled CLI/test processes
    /// must not change the installed application's preferences.
    public static func migrateIfNeeded() {
        guard Bundle.main.bundleIdentifier == canonicalBundleIdentifier else { return }
        migrate(defaults: .standard, destinationDomain: canonicalBundleIdentifier, legacyDomain: legacyBundleIdentifier)
    }

    /// Imports only supported app-owned preference formats. Existing destination
    /// keys win as complete values; opaque saved-query/layout data is never merged.
    public static func migrate(defaults: UserDefaults, destinationDomain: String, legacyDomain: String) {
        guard destinationDomain != legacyDomain else { return }
        var destination = defaults.persistentDomain(forName: destinationDomain) ?? [:]
        guard destination[migrationKey] == nil else { return }

        let legacy = defaults.persistentDomain(forName: legacyDomain) ?? [:]
        let compatiblePrefixes = [
            "SQLiteGraphStudio.saved-queries.",
            "SQLiteGraphStudio.query-history.",
            "SQLiteGraphStudio.graph-layout.v2.",
            "SQLiteGraphStudio.story-graph-layout.",
        ]
        for (key, value) in legacy where destination[key] == nil {
            if key == "SQLiteGraphStudio.recent-databases" || compatiblePrefixes.contains(where: key.hasPrefix) {
                destination[key] = value
            }
        }
        // Persist even when legacy is absent so deleted values cannot reappear
        // if an older launcher is used after this first canonical launch.
        destination[migrationKey] = true
        defaults.setPersistentDomain(destination, forName: destinationDomain)
    }
}
