import AppKit
import MailModel
import SwiftUI
import WebKit

/// Verification hook: `MAIL_SNAPSHOT=/path/out.png` selects the first message, writes a PNG of the
/// main window (titlebar + toolbar included) and quits. Lets us check the UI without screen-recording rights.
struct DebugSnapshot: ViewModifier {
    @Environment(MailStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            guard let out = ProcessInfo.processInfo.environment["MAIL_SNAPSHOT"] else { return }
            // MAIL_SNAPSHOT_SUBJECT picks a message by subject; otherwise the first one.
            let wanted = ProcessInfo.processInfo.environment["MAIL_SNAPSHOT_SUBJECT"]
            if let wanted, let m = store.messages.first(where: { $0.subject == wanted }) { store.category = m.category }
            if let m = store.visibleMessages.first(where: { wanted == nil || $0.subject == wanted }) {
                store.selection = [m.id]
                // MAIL_SNAPSHOT_HTML=file.html shows that HTML as the message's body, to check how a mail renders.
                if let file = ProcessInfo.processInfo.environment["MAIL_SNAPSHOT_HTML"],
                   let html = try? String(contentsOfFile: file, encoding: .utf8) {
                    store.setBody(MessageBody(text: m.body, attachments: m.attachments, html: html), for: m.id)
                }
            }
            if let f = ProcessInfo.processInfo.environment["MAIL_SNAPSHOT_PROGRESS"].flatMap(Double.init) {
                store.progress = SyncProgress(text: "Checking for Mail…", fraction: f)
            }
            // MAIL_SNAPSHOT_ANSWER=accept|tentative|decline|propose opens the answer window for the selected
            // invite and captures that window instead.
            var windowTitle: String?
            if let answer = ProcessInfo.processInfo.environment["MAIL_SNAPSHOT_ANSWER"], let id = store.selection.first {
                let draft = answer == "propose" ? store.answerDraft(.decline, to: id, proposing: true)
                    : store.answerDraft(InviteResponse(rawValue: answer) ?? .decline, to: id)
                openWindow(id: "compose", value: draft)
                windowTitle = draft.subject
            }
            try? await Task.sleep(for: .seconds(2))
            guard let win = NSApp.windows.first(where: { $0.isVisible && (windowTitle.map($0.title.hasPrefix) ?? ($0.title != "New Message")) }),
                  let view = win.contentView?.superview else { exit(2) }
            let appearance = ProcessInfo.processInfo.environment["MAIL_SNAPSHOT_DARK"] != nil ? "Dark" : "Aqua"
            NSApp.appearance = NSAppearance(named: appearance == "Dark" ? .darkAqua : .aqua)
            try? await Task.sleep(for: .milliseconds(500))
            // HTML bodies load in another process; wait for them (up to 15s) and for their height to settle.
            for _ in 0..<150 where webViews(in: view).contains(where: { $0.isLoading || $0.frame.height <= 1 }) { try? await Task.sleep(for: .milliseconds(100)) }
            if !webViews(in: view).isEmpty { try? await Task.sleep(for: .seconds(1)) }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(3) }
            view.cacheDisplay(in: view.bounds, to: rep)
            await drawWebViews(in: view, onto: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            exit(0)
        }
    }

    /// Web content is drawn in another process, so `cacheDisplay` leaves HTML bodies blank. Paint their snapshots in.
    private func drawWebViews(in root: NSView, onto rep: NSBitmapImageRep) async {
        for w in webViews(in: root) {
            guard let image = try? await w.takeSnapshot(configuration: nil) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSBezierPath(rect: root.convert(w.visibleRect, from: w)).addClip()  // only what the scroll view shows
            image.draw(in: root.convert(w.bounds, from: w))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func webViews(in root: NSView) -> [WKWebView] {
        var stack = [root], found: [WKWebView] = []
        while let v = stack.popLast() {
            if let w = v as? WKWebView { found.append(w) } else { stack.append(contentsOf: v.subviews) }
        }
        return found
    }
}
