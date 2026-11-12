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
            if let m = store.visibleMessages.first(where: { wanted == nil || $0.subject == wanted }) {
                store.selection = [m.id]
                // MAIL_SNAPSHOT_HTML=file.html shows that HTML as the message's body, to check how a mail renders.
                if let file = ProcessInfo.processInfo.environment["MAIL_SNAPSHOT_HTML"],
                   let html = try? String(contentsOfFile: file, encoding: .utf8) {
                    store.setBody(MessageBody(text: m.body, attachments: m.attachments, html: html), for: m.id)
                }
            }
            // MAIL_SNAPSHOT_PROGRESS=0.4 shows the activity bar at 40%; "loading" shows the bar of the startup cache load.
            if let p = ProcessInfo.processInfo.environment["MAIL_SNAPSHOT_PROGRESS"] {
                store.progress = p == "loading" ? SyncProgress(text: "Loading Mail…", fraction: nil)
                    : Double(p).map { SyncProgress(text: "Checking for Mail…", fraction: $0) }
            }
            // MAIL_SNAPSHOT_MAXSIZE=50000 gives every account that sending limit in bytes, to show "(maximum …)".
            if let max = ProcessInfo.processInfo.environment["MAIL_SNAPSHOT_MAXSIZE"].flatMap({ Int($0) }) {
                for a in store.accounts { store.setMaxMessageSize(max, for: a.id) }
            }
            // MAIL_SNAPSHOT_ANSWER=accept|tentative|decline|propose|forward opens the answer (or forward) window for the selected
            // invite and captures that window instead.
            var windowTitle: String?
            if let answer = ProcessInfo.processInfo.environment["MAIL_SNAPSHOT_ANSWER"], let id = store.selection.first {
                let draft = answer == "forward" ? store.draft(.forward, to: id)
                    : answer == "propose" ? store.answerDraft(.decline, to: id, proposing: true)
                    : store.answerDraft(InviteResponse(rawValue: answer) ?? .decline, to: id)
                openWindow(id: "compose", value: draft)
                windowTitle = draft.subject
                // MAIL_SNAPSHOT_DROP=a.jpg:b.txt drops those files onto the message text through a real pasteboard,
                // at character MAIL_SNAPSHOT_DROP_AT (default 0).
                if let list = ProcessInfo.processInfo.environment["MAIL_SNAPSHOT_DROP"] {
                    try? await Task.sleep(for: .seconds(1))
                    let pb = NSPasteboard(name: NSPasteboard.Name("MailReplica-SnapshotDrop"))
                    pb.clearContents()
                    pb.writeObjects(list.split(separator: ":").map { URL(fileURLWithPath: String($0)) as NSURL })
                    let at = ProcessInfo.processInfo.environment["MAIL_SNAPSHOT_DROP_AT"].flatMap { Int($0) } ?? 0
                    let view = NSApp.windows.compactMap(\.contentView).flatMap(textViews).first
                    view?.attachFiles(from: pb, at: at)
                    // MAIL_SNAPSHOT_EDIT=move|delete then moves the first file to the end (as a cut and paste,
                    // through RTFD) or deletes it, and prints what the text then holds.
                    if let edit = ProcessInfo.processInfo.environment["MAIL_SNAPSHOT_EDIT"], let view, let storage = view.textStorage {
                        let before = view.content().1
                        var first: NSRange?
                        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { v, r, stop in
                            if v != nil { first = r; stop.pointee = true }
                        }
                        if let first {
                            view.setSelectedRange(first)
                            let clip = NSPasteboard(name: NSPasteboard.Name("MailReplica-SnapshotMove"))
                            clip.clearContents()
                            _ = view.writeSelection(to: clip, types: view.writablePasteboardTypes)
                            view.delete(nil)
                            if edit == "move" {
                                view.setSelectedRange(NSRange(location: storage.length, length: 0))
                                _ = view.readSelection(from: clip)
                            }
                        }
                        let after = view.content().1
                        print("EDIT \(edit): before \(before.map { "\($0.name) \($0.data.count)" }), after \(after.map { "\($0.name) \($0.data.count)" }), "
                              + "same files \(Set(before) == Set(after)), marks \(view.string.filter { $0 == Draft.fileMark }.count), "
                              + "first file at end \(view.string.last == Draft.fileMark)")
                    }
                }
            }
            try? await Task.sleep(for: .seconds(2))
            guard let win = NSApp.windows.first(where: { $0.isVisible && (windowTitle.map($0.title.hasPrefix) ?? ($0.title != "New Message")) }),
                  let view = win.contentView?.superview else { exit(2) }
            // MAIL_SNAPSHOT_SIZE=1280x800 sets the window's size in points first (the README screenshots).
            if let size = ProcessInfo.processInfo.environment["MAIL_SNAPSHOT_SIZE"]?.split(separator: "x").compactMap({ Double($0) }),
               size.count == 2 {
                win.setFrame(NSRect(origin: win.frame.origin, size: NSSize(width: size[0], height: size[1])), display: true)
            }
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

    private func textViews(in root: NSView) -> [DropTextView] {
        var stack = [root], found: [DropTextView] = []
        while let v = stack.popLast() {
            if let t = v as? DropTextView { found.append(t) } else { stack.append(contentsOf: v.subviews) }
        }
        return found
    }

    private func webViews(in root: NSView) -> [WKWebView] {
        var stack = [root], found: [WKWebView] = []
        while let v = stack.popLast() {
            if let w = v as? WKWebView { found.append(w) } else { stack.append(contentsOf: v.subviews) }
        }
        return found
    }
}
