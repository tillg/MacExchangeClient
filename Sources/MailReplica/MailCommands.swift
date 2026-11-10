import MailModel
import SwiftUI

/// Menu bar, with the key equivalents read from Mail's MainMenu.nib.
struct MailCommands: Commands {
    let store: MailStore
    @Environment(\.openWindow) private var openWindow

    private var hasSelection: Bool { !store.selection.isEmpty }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { openWindow(id: "compose", value: Draft(accountID: store.accounts[0].id)) }
                .keyboardShortcut("n")
            Button("New Viewer Window") { openWindow(id: "viewer") }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        SidebarCommands()
        CommandGroup(after: .sidebar) {
            Toggle("Show Mail Categories", isOn: Bindable(store).showCategories)
            Toggle("Enable Message Filter", isOn: Bindable(store).filterUnread)
                .keyboardShortcut("l")
            Menu("Go to Mailbox Category") {
                ForEach(Array(MailCategory.allCases.enumerated()), id: \.offset) { i, c in
                    Button(c.title) { store.category = c }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
                }
            }
        }
        CommandMenu("Mailbox") {
            Button("Get New Mail") {}.keyboardShortcut("n", modifiers: [.command, .shift])
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
        openWindow(id: "compose", value: store.draft(kind, to: m.id))
    }
}
