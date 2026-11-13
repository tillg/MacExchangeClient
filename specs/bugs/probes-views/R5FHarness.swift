// R5F view-layer harness: the app's real views and MailCommands (all of Sources/MailReplica except
// MailReplicaApp.swift), in an App that mirrors MailReplicaApp's scenes, with sample data only (never the real
// account: own binary name = own empty defaults domain, and the store is SampleData's). It drives the app with real
// key events through NSApp.sendEvent and prints "R5F ..." lines. Build/run: specs/bugs/probes-views/run-harness.sh.
import AppKit
import MailModel
import SwiftUI

final class HarnessDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor enum Harness {
    static let scenario = ProcessInfo.processInfo.environment["R5F_SCENARIO"] ?? ""
    static func makeStore() -> MailStore {
        if scenario == "accounts7" {
            return MailStore(accounts: (1...7).map { Account(name: "Acct \($0)", address: "me\($0)@x.com") }, messages: [])
        }
        return SampleData.store()
    }

    static func key(_ code: UInt16, _ mods: NSEvent.ModifierFlags, in win: NSWindow) {
        // From the key code, as the keyboard sends it: the system fills in the characters for the current layout.
        // (Creating a CGEvent needs no permission; only posting one does.)
        guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) else { return }
        var flags = CGEventFlags()
        if mods.contains(.command) { flags.insert(.maskCommand) }
        if mods.contains(.shift) { flags.insert(.maskShift) }
        cg.flags = flags
        guard let e = NSEvent(cgEvent: cg) else { return }
        print("R5F key event from key code \(code): characters \(e.characters?.unicodeScalars.map { String($0.value, radix: 16) } ?? []), ignoring modifiers \(e.charactersIgnoringModifiers?.unicodeScalars.map { String($0.value, radix: 16) } ?? [])")
        // The app was started from a shell and can't become active, so NSApp has no key window and sendEvent drops
        // key equivalents. This is sendEvent's documented order for a key equivalent: the key window's view
        // hierarchy first, then the menu bar; only if neither takes it does it go to the first responder as keyDown.
        // As when a menu would track: SwiftUI brings its items' enabled state up to date in menuNeedsUpdate.
        for top in NSApp.mainMenu?.items ?? [] { if let sm = top.submenu { sm.delegate?.menuNeedsUpdate?(sm); sm.update() } }
        if win.performKeyEquivalent(with: e) { print("R5F key handled by the window's views") }
        else if NSApp.mainMenu?.performKeyEquivalent(with: e) == true { print("R5F key handled by the menu bar") }
        else { win.firstResponder?.keyDown(with: e); print("R5F key went to the first responder as keyDown") }
    }

    static func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
}

struct HarnessProbe: ViewModifier {
    @Environment(MailStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    /// How many times the `.task` on the viewer window's content started (MailReplicaApp puts `pollForMail`,
    /// which begins with `AppSetup.loadMail`, in such a task).
    static var viewerTasks = 0

    func body(content: Content) -> some View {
        content.task {
            Self.viewerTasks += 1
            guard Self.viewerTasks == 1 else { return }
            await run()
        }
    }

    func run() async {
        if Harness.scenario == "two-viewers" {
            try? await Task.sleep(for: .seconds(1))
            print("R5F viewer window tasks started: \(Self.viewerTasks)")
            openWindow(id: "viewer")  // File ▸ New Viewer Window
            try? await Task.sleep(for: .seconds(2))
            print("R5F after New Viewer Window: viewer windows \(NSApp.windows.filter { $0.isVisible && $0.title != "New Message" }.count), viewer window tasks started: \(Self.viewerTasks)")
            if Self.viewerTasks > 1 { print("R5F FAIL: expected loadMail/pollForMail to start once per app, got the window task started \(Self.viewerTasks) times"); exit(1) }
            exit(0)
        }
        try? await Task.sleep(for: .seconds(2))
        guard let win = NSApp.windows.first(where: { $0.isVisible && $0.title != "New Message" }) else { print("R5F no window"); exit(2) }
        win.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(500))
        if Harness.scenario == "menus" {
            store.selection = [store.visibleMessages[0].id]
            try? await Task.sleep(for: .seconds(2))
            print("R5F selection \(store.selection.count), delegate \(String(describing: NSApp.mainMenu?.items.last?.submenu?.delegate))")
            for top in NSApp.mainMenu?.items ?? [] {
                if let sm = top.submenu { sm.delegate?.menuNeedsUpdate?(sm); sm.delegate?.menuWillOpen?(sm); sm.update() }
                for i in top.submenu?.items ?? [] where !i.keyEquivalent.isEmpty {
                    print("R5F menu \(top.title) ▸ \(i.title): key \(i.keyEquivalent.unicodeScalars.map { String($0.value, radix: 16) }) mods \(i.keyEquivalentModifierMask.rawValue) enabled \(i.isEnabled)")
                }
            }
            exit(0)
        }
        if Harness.scenario == "listdate" {
            let cal = Calendar.current
            let weekAgoLate = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: .now))!.addingTimeInterval(23.9 * 3600)
            let nextMonth = Date.now.addingTimeInterval(30 * 86400)
            let today = Date.now.formatted(.dateTime.weekday(.wide))
            print("R5F today is \(today)")
            var failed = false
            for (label, d) in [("7 calendar days ago, 23:54", weekAgoLate), ("30 days in the future", nextMonth)] {
                print("R5F listDate(\(label) = \(d.formatted(date: .numeric, time: .shortened))) = \"\(MessageRow.listDate(d))\"")
                if MessageRow.listDate(d) != d.formatted(date: .numeric, time: .omitted) {
                    failed = true
                    print("R5F FAIL: expected the short date \"\(d.formatted(date: .numeric, time: .omitted))\" for \(label), got \"\(MessageRow.listDate(d))\"")
                }
            }
            exit(failed ? 1 : 0)
        }
        print("R5F scenario \(Harness.scenario), key window: \(NSApp.keyWindow?.title ?? "nil")")
        switch Harness.scenario {
        case "accounts7":
            print("R5F ALIVE with \(store.accounts.count) accounts")
        case "delete-in-search", "delete-in-list":
            let m = store.visibleMessages[0]
            store.selection = [m.id]
            try? await Task.sleep(for: .milliseconds(800))
            let root = win.contentView!.superview!
            if Harness.scenario == "delete-in-search" {
                guard let field = Harness.all(root).compactMap({ $0 as? NSSearchField }).first else { print("R5F no search field"); exit(2) }
                win.makeFirstResponder(field)
                field.stringValue = "hello world"
                (field.currentEditor() as? NSTextView)?.string = "hello world"
                (field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 11, length: 0))
                try? await Task.sleep(for: .milliseconds(300))
                print("R5F first responder: \(type(of: win.firstResponder!)), search text \"\(field.stringValue)\"")
            } else {
                guard let table = Harness.all(root).compactMap({ $0 as? NSTableView }).last else { print("R5F no table"); exit(2) }
                win.makeFirstResponder(table)
                print("R5F first responder: \(type(of: win.firstResponder!))")
            }
            print("R5F before: \"\(m.subject)\" in \(store.message(m.id)?.mailbox.rawValue ?? "gone")")
            // The Delete key with Command, as the keyboard sends it.
            Harness.key(51, [.command], in: win)
            try? await Task.sleep(for: .milliseconds(800))
            print("R5F after ⌘⌫: \"\(m.subject)\" in \(store.message(m.id)?.mailbox.rawValue ?? "gone"); search text \"\(store.searchText)\"")
            if Harness.scenario == "delete-in-search", store.message(m.id)?.mailbox != m.mailbox {
                print("R5F FAIL: expected ⌘⌫ in the search field to edit the field and leave \"\(m.subject)\" in \(m.mailbox.rawValue), got it in \(store.message(m.id)?.mailbox.rawValue ?? "gone (erased)")")
                exit(1)
            }
        case "send-shortcut", "save-shortcut", "delete-in-compose":
            var selected = store.visibleMessages[0]
            if ProcessInfo.processInfo.environment["R5F_TRASH"] != nil {
                // The message is in Trash, selected there (an earlier Delete, then a look at Trash).
                store.delete([selected.id])
                store.selectedMailbox = .account(selected.accountID, .trash)
                try? await Task.sleep(for: .milliseconds(500))
                selected = store.message(selected.id)!
            }
            store.selection = [selected.id]
            try? await Task.sleep(for: .milliseconds(500))
            let acct = store.accounts.first { $0.name == "Work" }!
            let subject = "R5F \(Harness.scenario)"
            openWindow(id: "compose", value: ComposeWindow(Draft(accountID: acct.id, to: "bob@example.com", subject: subject, body: "Hello")))
            try? await Task.sleep(for: .seconds(1.5))
            guard let cw = NSApp.windows.first(where: { $0.isVisible && $0.title == subject }) else { print("R5F no compose window"); exit(2) }
            cw.makeKeyAndOrderFront(nil)
            if let tv = Harness.all(cw.contentView!).compactMap({ $0 as? NSTextView }).first(where: { $0 is DropTextView }) { cw.makeFirstResponder(tv) }
            try? await Task.sleep(for: .milliseconds(500))
            print("R5F compose key: \(NSApp.keyWindow?.title ?? "nil"), first responder \(cw.firstResponder.map { "\(type(of: $0))" } ?? "nil")")
            if Harness.scenario == "send-shortcut" {
                Harness.key(2, [.command, .shift], in: cw)
            } else if Harness.scenario == "delete-in-compose" {
                let tv = cw.firstResponder as? NSTextView
                tv?.setSelectedRange(NSRange(location: 5, length: 0))
                print("R5F before: compose text \"\(tv?.string ?? "")\", selected \"\(selected.subject)\" in \(selected.mailbox.rawValue)")
                Harness.key(51, [.command], in: cw)
                try? await Task.sleep(for: .milliseconds(800))
                print("R5F after ⌘⌫ in the compose text: compose text \"\(tv?.string ?? "")\", \"\(selected.subject)\" in \(store.message(selected.id)?.mailbox.rawValue ?? "gone")")
                if store.message(selected.id)?.mailbox != selected.mailbox {
                    print("R5F FAIL: expected ⌘⌫ in the compose text to delete text before the insertion point and leave \"\(selected.subject)\" in \(selected.mailbox.rawValue), got text \"\(tv?.string ?? "")\" and the message \(store.message(selected.id)?.mailbox.rawValue ?? "gone (erased)")")
                    exit(1)
                }
            } else {
                Harness.key(1, [.command], in: cw)
            }
            try? await Task.sleep(for: .seconds(1))
            let sent = store.messages.filter { $0.subject == subject }.map { $0.mailbox.rawValue }
            print("R5F after shortcut: messages with that subject in \(sent), compose window open \(cw.isVisible)")
        default:
            print("R5F unknown scenario")
        }
        exit(0)
    }
}

@main
struct R5FHarnessApp: App {
    @NSApplicationDelegateAdaptor(HarnessDelegate.self) var delegate
    @State private var store = Harness.makeStore()

    var body: some Scene {
        WindowGroup("Mail", id: "viewer") {
            MessageViewer()
                .modifier(HarnessProbe())
                .environment(store)
                .frame(minWidth: 900, minHeight: 500)
        }
        .defaultSize(width: 1280, height: 800)
        .commands { MailCommands(store: store) }

        WindowGroup("New Message", id: "compose", for: ComposeWindow.self) { $window in
            ComposeView(draft: window?.draft ?? Draft(accountID: store.accounts[0].id))
                .environment(store)
        }
        .defaultSize(width: 640, height: 520)
    }
}
