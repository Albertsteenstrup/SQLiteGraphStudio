import AppKit
import StudioCore
import SwiftUI

final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct SQLiteGraphStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var appDelegate
    @State private var session = AppSession()

    var body: some Scene {
        WindowGroup("SQLite Graph Studio") {
            StudioRootView(session: session)
                .frame(minWidth: 1200, minHeight: 760)
        }
        .commands {
            StudioCommands(session: session)
        }
    }
}
