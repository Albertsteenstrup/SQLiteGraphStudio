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

            Button("Create Table…") {
                session.showCreateTable()
            }
            .disabled(!session.databaseCapabilities.canCreateTable)

            Button("Alter Active Table…") {
                session.showAlterTable()
            }
            .disabled(session.activeTab == nil || !session.databaseCapabilities.canAlterSchema)

            Divider()

            Menu("Import Rows") {
                Button("CSV…") {
                    session.importRowsIntoActiveTable(format: .csv)
                }
                Button("JSON…") {
                    session.importRowsIntoActiveTable(format: .json)
                }
            }
            .disabled(!session.databaseCapabilities.canImportRows || session.activeTab?.isEditable != true)

            Menu("Export Active Table") {
                Button("CSV…") {
                    session.exportActiveTableRows(format: .csv)
                }
                Button("JSON…") {
                    session.exportActiveTableRows(format: .json)
                }
            }
            .disabled(session.activeTab == nil)

            Menu("Export Query Results") {
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
