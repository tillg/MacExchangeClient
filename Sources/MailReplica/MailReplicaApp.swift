import AppKit
import MailModel
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A bare SwiftPM executable starts as a background process; make it a real app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct MailReplicaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var store = SampleData.store()

    var body: some Scene {
        WindowGroup("Mail", id: "viewer") {
            MessageViewer()
                .modifier(DebugSnapshot())
                .environment(store)
                .frame(minWidth: 900, minHeight: 500)
        }
        .defaultSize(width: 1280, height: 800)
        .commands { MailCommands(store: store) }

        WindowGroup("New Message", id: "compose", for: Draft.self) { $draft in
            ComposeView(draft: draft ?? Draft(accountID: store.accounts[0].id))
                .environment(store)
        }
        .defaultSize(width: 640, height: 520)
    }
}
