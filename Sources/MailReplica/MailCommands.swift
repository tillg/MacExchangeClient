import MailModel
import SwiftUI

/// Menu bar, with the key equivalents read from Mail's MainMenu.nib.
struct MailCommands: Commands {
    let store: MailStore
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.attachFiles) private var attachFiles
    @AppStorage("includeAttachmentsWithReplies") private var includeMode = IncludeAttachments.never

    private var hasSelection: Bool { !store.selection.isEmpty }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { openWindow(id: "compose", value: Draft(accountID: store.accounts[0].id)) }
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
        CommandGroup(after: .sidebar) {
            Toggle("Enable Message Filter", isOn: Bindable(store).filterUnread)
                .keyboardShortcut("l")
        }
        CommandMenu("Mailbox") {
            Button("Get New Mail") { Task { await store.refresh() } }.keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Mark All Messages as Read") { store.markAllRead(in: store.selectedMailbox) }
            Divider()
            ForEach(Array(favorites.enumerated()), id: \.offset) { i, ref in
                Button(label(ref)) { store.selectedMailbox = ref }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
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
            Button("Mark as Read/Unread") { store.toggleRead(store.selection) }
                .keyboardShortcut("u", modifiers: [.command, .shift]).disabled(!hasSelection)
            Button("Toggle Flag") {
                let flagged = store.selection.contains { store.message($0)?.flag != nil }
                store.setFlag(flagged ? nil : .red, for: store.selection)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift]).disabled(!hasSelection)
            Menu("Flag") {
                ForEach(FlagColor.allCases, id: \.self) { c in Button(c.title) { store.setFlag(c, for: store.selection) } }
                Divider()
                Button("Clear Flag") { store.setFlag(nil, for: store.selection) }
            }
            .disabled(!hasSelection)
            Divider()
            Button("Archive") { store.archiveSelection() }
                .keyboardShortcut("a", modifiers: [.command, .control]).disabled(!hasSelection)
            Button("Move to Junk") { store.junkSelection() }
                .keyboardShortcut("j", modifiers: [.command, .shift]).disabled(!hasSelection)
            Button("Delete") { store.deleteSelection() }
                .keyboardShortcut(.delete).disabled(!hasSelection)
        }
    }

    /// ⌘1…⌘9 go to favourite mailboxes.
    private var favorites: [MailboxRef] {
        [.smart(.allInboxes), .smart(.vip), .smart(.flagged)] + store.accounts.map { .account($0.id, .inbox) }
    }

    private func label(_ ref: MailboxRef) -> String {
        switch ref {
        case .smart(let s): s == .allInboxes ? "All Inboxes" : s.title
        case let .account(id, k): "\(store.account(id)?.name ?? "") \(k.title)"
        }
    }

    private func reply(_ kind: ReplyKind) {
        guard let m = store.selectedMessage else { return }
        openWindow(id: "compose", value: store.draft(kind, to: m.id, includeAttachments: includeMode))
    }
}
