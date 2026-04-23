import SwiftUI

public struct StudioCommands: Commands {
    private let session: AppSession

    public init(session: AppSession) {
        self.session = session
    }

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Database…") {
                session.presentOpenDatabasePanel()
            }
            .keyboardShortcut("o")

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
        }
    }
}
