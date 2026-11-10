import AppKit
import MailModel
import SwiftUI

/// Verification hook: `MAIL_SNAPSHOT=/path/out.png` selects the first message, writes a PNG of the
/// main window (titlebar + toolbar included) and quits. Lets us check the UI without screen-recording rights.
struct DebugSnapshot: ViewModifier {
    @Environment(MailStore.self) private var store

    func body(content: Content) -> some View {
        content.task {
            guard let out = ProcessInfo.processInfo.environment["MAIL_SNAPSHOT"] else { return }
            if let first = store.visibleMessages.first { store.selection = [first.id] }
            if let f = ProcessInfo.processInfo.environment["MAIL_SNAPSHOT_PROGRESS"].flatMap(Double.init) {
                store.progress = SyncProgress(text: "Checking for Mail…", fraction: f)
            }
            try? await Task.sleep(for: .seconds(2))
            guard let win = NSApp.windows.first(where: { $0.isVisible && $0.title != "New Message" }),
                  let view = win.contentView?.superview else { exit(2) }
            let appearance = ProcessInfo.processInfo.environment["MAIL_SNAPSHOT_DARK"] != nil ? "Dark" : "Aqua"
            NSApp.appearance = NSAppearance(named: appearance == "Dark" ? .darkAqua : .aqua)
            try? await Task.sleep(for: .milliseconds(500))
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(3) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            exit(0)
        }
    }
}
