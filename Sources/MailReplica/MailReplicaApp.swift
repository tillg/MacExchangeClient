import AppKit
import MailModel
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A bare SwiftPM executable starts as a background process; make it a real app.
        NSApp.setActivationPolicy(.regular)
        AppIcon.install()
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct MailReplicaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var store = AppSetup.makeStore()

    var body: some Scene {
        WindowGroup("Mail", id: "viewer") {
            MessageViewer()
                .modifier(DebugSnapshot())
                .environment(store)
                .frame(minWidth: 900, minHeight: 500)
                .task { await pollForMail() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    AppSetup.saveChanges(store, now: true)
                }
        }
        .defaultSize(width: 1280, height: 800)
        .commands { MailCommands(store: store) }

        WindowGroup("New Message", id: "compose", for: ComposeWindow.self) { $window in
            ComposeView(draft: window?.draft ?? Draft(accountID: store.accounts[0].id))
                .environment(store)
        }
        .defaultSize(width: 640, height: 520)

        Window("What's New", id: "whats-new") {
            WhatsNewView()
        }
        .defaultSize(width: 520, height: 600)

        Settings {
            TabView {
                AccountsSettings().environment(store)
                    .tabItem { Label("Accounts", systemImage: "at") }
                ViewingSettings()
                    .tabItem { Label("Viewing", systemImage: "eyeglasses") }
                PrivacySettings()
                    .tabItem { Label("Privacy", systemImage: "hand.raised") }
            }
        }
    }

    /// Quick check every 15 seconds: one small request per folder on screen (push comes later). The history
    /// sync runs on its own in the background. Off while taking a snapshot.
    private func pollForMail() async {
        guard ProcessInfo.processInfo.environment["MAIL_SNAPSHOT"] == nil else { return }
        // Every viewer window runs this task; one loop polls at a time. Another window takes over when the polling
        // one closes (BUG-219).
        while AppSetup.isPolling {
            guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
        }
        AppSetup.isPolling = true
        defer { AppSetup.isPolling = false }
        await AppSetup.loadMail(into: store)  // before the first check, so it only fetches what changed; once per launch
        while !Task.isCancelled {
            await store.refresh()
            AppSetup.saveChanges(store)
            try? await Task.sleep(for: .seconds(15))
        }
    }
}
