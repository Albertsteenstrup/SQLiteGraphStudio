import SwiftUI

public struct StudioCommands: Commands {
    private let session: AppSession

    public init(session: AppSession) {
        self.session = session
    }

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open SQLite File…") {
                session.presentOpenDatabasePanel()
            }
            .keyboardShortcut("o")

            Button("Open PostgreSQL Document…") {
                session.presentOpenPostgreSQLDocumentPanel()
            }

            Menu("Open Recent") {
                if session.recentDatabaseURLs.isEmpty {
                    Text("No Recent Databases")
                } else {
                    ForEach(session.recentDatabaseURLs, id: \.path) { url in
                        Button(url.lastPathComponent) {
                            session.openRecentDatabase(url)
                        }
                    }
                }
            }
            .disabled(session.recentDatabaseURLs.isEmpty)

            Button("Close Database") {
                session.closeDatabase()
            }
            .disabled(!session.hasOpenDatabase)
            .keyboardShortcut("w")
        }

        CommandMenu("Database") {
            Button("Refresh Schema") {
                session.refreshSchema()
            }
            .keyboardShortcut("r")
            .disabled(!session.hasOpenDatabase)

            Button("Open Table…") {
                session.showTablePicker()
            }
            .keyboardShortcut("t")
            .disabled(session.tables.isEmpty)

            if session.databaseCapabilities.canCreateTable {
                Button("Create Table…") { session.showCreateTable() }
            }
            if session.databaseCapabilities.canAlterSchema {
                Button("Alter Active Table…") { session.showAlterTable() }
                    .disabled(session.activeTab == nil)
            }
            if session.databaseCapabilities.canImportRows {
                Menu("Import Rows") {
                    Button("CSV…") { session.importRowsIntoActiveTable(format: .csv) }
                    Button("JSON…") { session.importRowsIntoActiveTable(format: .json) }
                }
                .disabled(session.activeTab?.isEditable != true)
            }
            Divider()

            Menu("Export Active Table") {
                Menu("Loaded rows (\(session.activeTab?.chunk.rows.count ?? 0))") {
                    Button("CSV…") { session.exportActiveTableRows(format: .csv, scope: .loadedRows) }
                    Button("JSON…") { session.exportActiveTableRows(format: .json, scope: .loadedRows) }
                }
                Menu("All matching rows…") {
                    Button("CSV…") { session.exportActiveTableRows(format: .csv, scope: .allMatchingRows) }
                    Button("JSON…") { session.exportActiveTableRows(format: .json, scope: .allMatchingRows) }
                }
            }
            .disabled(session.activeTab == nil || session.exportProgress?.isRunning == true)

            Menu("Export Query Results") {
                Text(session.queryExportScopeLabel)
                Button("CSV…") {
                    session.exportActiveQueryResult(format: .csv)
                }
                Button("JSON…") {
                    session.exportActiveQueryResult(format: .json)
                }
            }
            .disabled(session.queryWorkspace.activeQuery?.result.columns.isEmpty != false)

            Divider()

            Button("AI Skills…") {
                session.showSkills()
            }
            .disabled(!session.databaseCapabilities.supportsAIWorkspace)
        }
    }
}
