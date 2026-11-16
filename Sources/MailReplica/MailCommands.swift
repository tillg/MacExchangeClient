import AppKit
import MailModel
import SwiftUI

/// Menu bar, with the key equivalents read from Mail's MainMenu.nib.
struct MailCommands: Commands {
    let store: MailStore
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.attachFiles) private var attachFiles
    @FocusedValue(\.goBack) private var goBack
    @FocusedValue(\.goForward) private var goForward
    @AppStorage("includeAttachmentsWithReplies") private var includeMode = IncludeAttachments.never

    private var hasSelection: Bool { !store.selection.isEmpty }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { openWindow(id: "compose", value: ComposeWindow(Draft(accountID: store.accounts[0].id))) }
                .keyboardShortcut("n")
            Button("New Viewer Window") { openWindow(id: "viewer") }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        // Titles and shortcuts from MainMenu.nib; the position in the menu is estimated.
        CommandGroup(after: .saveItem) {
            Button("Attach Files…") { attachFiles?() }
                .keyboardShortcut("a", modifiers: [.command, .shift]).disabled(attachFiles == nil)
            Button("Save Attachments…") {
                if let m = store.selectedMessage { AttachmentPanels.saveAll(of: m, store: store) }
            }
            .disabled(store.selectedMessage?.attachments.isEmpty ?? true)
            Button("Quick Look Attachments…") {
                if let m = store.selectedMessage { Task { await store.quickLookAttachments(of: m.id) } }
            }
            .keyboardShortcut("y").disabled(store.selectedMessage?.attachments.isEmpty ?? true)
        }
        // Delete is in Mail's Edit menu, after Paste and before Select All (BUG-228). The system's group has its own
        // Delete (no shortcut), and added items can only follow Select All, so the group is written out here: Cut,
        // Copy, Paste and Select All go to the first responder, as the system's items do.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }.keyboardShortcut("x")
            Button("Copy") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }.keyboardShortcut("c")
            Button("Paste") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }.keyboardShortcut("v")
            Button("Delete") {
                // ⌘⌫ is also the text system's "delete to the start of the line". In Mail, Delete goes to the first
                // responder, so typing in a compose window or the search field never deletes mail (BUG-218).
                // Only the key: Edit ▸ Delete chosen with the mouse still deletes mail.
                let mouse: [NSEvent.EventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
                if !mouse.contains(NSApp.currentEvent?.type ?? .keyDown),
                   let text = (NSApp.keyWindow ?? NSApp.orderedWindows.first)?.firstResponder as? NSTextView, text.isEditable {
                    text.deleteToBeginningOfLine(nil)
                } else {
                    store.deleteSelection()
                }
            }
                .keyboardShortcut(.delete).disabled(!hasSelection)
            Button("Select All") { NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil) }.keyboardShortcut("a")
        }
        CommandGroup(after: .textEditing) {
            Picker("Include Attachments With Replies", selection: $includeMode) {
                ForEach(IncludeAttachments.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }
        // There is no help book, so "MailReplica Help" goes; the change log takes its place.
        CommandGroup(replacing: .help) {
            Button("What's New") { openWindow(id: "whats-new") }
        }
        SidebarCommands()
        // View ▸ Back ⇧⌘[, Forward ⇧⌘] and Filter ▸ Enable Message Filter ⌘L, as in MainMenu.nib (BUG-229).
        CommandGroup(after: .sidebar) {
            Button("Back") { goBack?() }
                .keyboardShortcut("[", modifiers: [.command, .shift]).disabled(goBack == nil)
            Button("Forward") { goForward?() }
                .keyboardShortcut("]", modifiers: [.command, .shift]).disabled(goForward == nil)
            Menu("Filter") {
                Toggle("Enable Message Filter", isOn: Bindable(store).filterUnread)
                    .keyboardShortcut("l")
            }
        }
        CommandMenu("Mailbox") {
            Button("Get New Mail") { Task { await store.refresh() } }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Mark All Messages as Read") { store.markAllRead(in: store.selectedMailbox) }
            Divider()
            // Mail's Mailbox ▸ Go to Favorite Mailbox, ⌘1–⌘9 (BUG-230).
            Menu("Go to Favorite Mailbox") {
                ForEach(Array(store.favoriteMailboxes.enumerated()), id: \.offset) { i, ref in
                    Button(label(ref)) { store.selectedMailbox = ref }
                        .keyboardShortcut(MailStore.favoriteKey(at: i).map { KeyboardShortcut(KeyEquivalent($0)) })
                }
            }
        }
        CommandMenu("Message") {
            Button("Send") {}.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(true)
            Divider()
            Button("Reply") { reply(.reply) }.keyboardShortcut("r").disabled(store.selectedMessage == nil)
            Button("Reply All") { reply(.replyAll) }.keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store.selectedMessage == nil)
            Button("Forward") { reply(.forward) }.keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(store.selectedMessage == nil)
            Divider()
            // Mail's order: Mark as Read, Move to Junk, Flag ▸ (… Clear Flag, Toggle Flag), —, Archive (BUG-228).
            let ids = store.withConversations(store.selection)
            Button(store.messages.contains { !$0.isRead && ids.contains($0.id) } || !hasSelection ? "Mark as Read" : "Mark as Unread") {
                store.toggleRead(ids)
            }
                .keyboardShortcut("u", modifiers: [.command, .shift]).disabled(!hasSelection)
            Button(store.isAllJunk(ids) ? "Not Junk" : "Move to Junk") { store.junkSelection() }
                .keyboardShortcut("j", modifiers: [.command, .shift]).disabled(!hasSelection)
            Menu("Flag") {
                ForEach(FlagColor.allCases, id: \.self) { c in Button(c.title) { store.setFlag(c, for: ids) } }
                Divider()
                Button("Clear Flag") { store.setFlag(nil, for: ids) }
                Button("Toggle Flag") { store.toggleFlag(ids) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            .disabled(!hasSelection)
            Divider()
            Button("Archive") { store.archiveSelection() }
                .keyboardShortcut("a", modifiers: [.command, .control]).disabled(!hasSelection)
        }
    }

    private func label(_ ref: MailboxRef) -> String {
        switch ref {
        case .smart(let s): s == .allInboxes ? "All Inboxes" : s.title
        case let .account(id, k): "\(store.account(id)?.name ?? "") \(k.title)"
        }
    }

    private func reply(_ kind: ReplyKind) {
        guard let m = store.selectedMessage else { return }
        // A message not opened yet is loaded first, so the draft has its addresses and text.
        Task { openWindow(id: "compose", value: ComposeWindow(await store.loadedDraft(kind, to: m.id, includeAttachments: includeMode))) }
    }
}
