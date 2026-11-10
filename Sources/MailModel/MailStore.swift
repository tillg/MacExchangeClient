import Foundation
import Observation

@MainActor
@Observable
public final class MailStore {
    public var accounts: [Account]
    public private(set) var messages: [Message]

    public var selectedMailbox: MailboxRef = .smart(.allInboxes)
    public var selection: Set<Message.ID> = []
    public var filterUnread = false
    public var category: MailCategory = .primary
    public var showCategories = true
    public var searchText = ""

    public init(accounts: [Account], messages: [Message]) {
        self.accounts = accounts
        self.messages = messages
    }

    // MARK: Queries

    public func message(_ id: Message.ID) -> Message? { messages.first { $0.id == id } }

    public func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }

    func contains(_ ref: MailboxRef, _ m: Message) -> Bool {
        switch ref {
        case .smart(.allInboxes): m.mailbox == .inbox
        case .smart(.vip): m.isVIP && m.mailbox == .inbox
        case .smart(.flagged): m.flag != nil && m.mailbox != .trash
        case .smart(.unread): !m.isRead && m.mailbox == .inbox
        case let .account(id, kind): m.accountID == id && m.mailbox == kind
        }
    }

    public func unreadCount(_ ref: MailboxRef) -> Int {
        messages.lazy.filter { !$0.isRead && self.contains(ref, $0) }.count
    }

    public func count(_ ref: MailboxRef) -> Int { messages.lazy.filter { self.contains(ref, $0) }.count }

    /// Messages for the list pane: mailbox (or whole account/all mail while searching),
    /// category, unread filter, newest first.
    public var visibleMessages: [Message] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return messages.filter { m in
            if !q.isEmpty {
                guard inSearchScope(m), m.mailbox != .trash, m.mailbox != .junk else { return false }
                return [m.subject, m.from.name, m.from.email, m.body].contains { $0.lowercased().contains(q) }
            }
            guard contains(selectedMailbox, m) else { return false }
            if filterUnread && m.isRead { return false }
            if showCategories && selectedMailbox.isInbox && m.category != category { return false }
            return true
        }
        .sorted { $0.date > $1.date }
    }

    private func inSearchScope(_ m: Message) -> Bool {
        if case let .account(id, _) = selectedMailbox { return m.accountID == id }
        return true
    }

    public var selectedMessage: Message? { selection.count == 1 ? selection.first.flatMap(message) : nil }

    public var title: String {
        switch selectedMailbox {
        case .smart(let s): s == .allInboxes ? "All Inboxes" : s.title
        case let .account(id, kind):
            kind == .inbox ? "Inbox – \(account(id)?.name ?? "")" : kind.title
        }
    }

    // MARK: Mutations

    private func update(_ ids: Set<Message.ID>, _ f: (inout Message) -> Void) {
        for i in messages.indices where ids.contains(messages[i].id) { f(&messages[i]) }
    }

    public func move(_ ids: Set<Message.ID>, to box: MailboxKind) { update(ids) { $0.mailbox = box } }

    public func delete(_ ids: Set<Message.ID>) {
        let erase = Set(messages.filter { ids.contains($0.id) && $0.mailbox == .trash }.map(\.id))
        messages.removeAll { erase.contains($0.id) }
        move(ids.subtracting(erase), to: .trash)
    }

    public func archive(_ ids: Set<Message.ID>) { move(ids, to: .archive) }

    public func toggleJunk(_ ids: Set<Message.ID>) {
        update(ids) { $0.mailbox = $0.mailbox == .junk ? .inbox : .junk }
    }

    public func setFlag(_ c: FlagColor?, for ids: Set<Message.ID>) { update(ids) { $0.flag = c } }

    public func toggleRead(_ ids: Set<Message.ID>) {
        let anyUnread = messages.contains { ids.contains($0.id) && !$0.isRead }
        update(ids) { $0.isRead = anyUnread }
    }

    public func markSelectionRead() { update(selection) { $0.isRead = true } }

    public func markAllRead(in ref: MailboxRef) {
        for i in messages.indices where contains(ref, messages[i]) { messages[i].isRead = true }
    }

    /// Runs `action` on the selection, then selects the message that followed it in the list – as Mail does.
    public func actOnSelection(_ action: (Set<Message.ID>) -> Void) {
        let list = visibleMessages.map(\.id)
        let lastIdx = list.lastIndex { selection.contains($0) }
        let ids = selection
        action(ids)
        let remaining = Set(visibleMessages.map(\.id))
        if let lastIdx {
            let next = list[(lastIdx + 1)...].first { remaining.contains($0) && !ids.contains($0) }
                ?? list[..<lastIdx].last { remaining.contains($0) && !ids.contains($0) }
            selection = next.map { [$0] } ?? []
        }
    }

    public func deleteSelection() { actOnSelection(delete) }
    public func archiveSelection() { actOnSelection(archive) }
    public func junkSelection() { actOnSelection(toggleJunk) }

    // MARK: Drag & drop

    /// VIPs and Unread are rule-based smart mailboxes; there is nothing a drop could change.
    public func canDrop(on ref: MailboxRef) -> Bool {
        switch ref {
        case .smart(.vip), .smart(.unread): false
        default: true
        }
    }

    /// Drops messages on a sidebar mailbox: an account mailbox moves them there (also across accounts),
    /// Flagged flags them red, All Inboxes moves each back to its own account's Inbox.
    /// Returns false when nothing changed.
    @discardableResult
    public func drop(_ ids: Set<Message.ID>, on ref: MailboxRef) -> Bool {
        guard canDrop(on: ref) else { return false }
        let moving = Set(messages.filter { ids.contains($0.id) && !contains(ref, $0) }.map(\.id))
        guard !moving.isEmpty else { return false }
        let apply: (Set<Message.ID>) -> Void = { ids in
            self.update(ids) { m in
                switch ref {
                case .smart(.flagged): if m.flag == nil { m.flag = .red }
                case .smart(.allInboxes): m.mailbox = .inbox
                case let .account(acct, kind): m.accountID = acct; m.mailbox = kind
                case .smart(.vip), .smart(.unread): break
                }
            }
        }
        if ids == selection { actOnSelection(apply) } else { apply(moving) }
        return true
    }

    // MARK: Compose

    public func draft(_ kind: ReplyKind, to id: Message.ID) -> Draft {
        guard let m = message(id) else { return Draft(accountID: accounts[0].id) }
        let me = account(m.accountID)?.address
        let prefix = kind == .forward ? "Fwd: " : "Re: "
        let subject = m.subject.hasPrefix(prefix) ? m.subject : prefix + m.subject
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        let quoted = m.body.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }
            .joined(separator: "\n")
        let header = kind == .forward
            ? "\n\nBegin forwarded message:\n\nFrom: \(m.from.name) <\(m.from.email)>\nSubject: \(m.subject)\nDate: \(df.string(from: m.date))\n\n"
            : "\n\nOn \(df.string(from: m.date)), \(m.from.name) <\(m.from.email)> wrote:\n\n"
        var to = ""
        switch kind {
        case .reply: to = m.from.email
        case .replyAll:
            to = ([m.from] + m.to + m.cc).map(\.email).filter { $0 != me }.joined(separator: ", ")
        case .forward: break
        }
        return Draft(accountID: m.accountID, to: to, subject: subject, body: header + quoted)
    }

    public func send(_ d: Draft) {
        let acct = account(d.accountID) ?? accounts[0]
        messages.append(Message(accountID: acct.id, mailbox: .sent, from: Contact(name: acct.name, email: acct.address),
                                to: Contact.parseList(d.to), cc: Contact.parseList(d.cc), subject: d.subject,
                                body: d.body, date: .now, isRead: true))
    }

    public func saveDraft(_ d: Draft) {
        let acct = account(d.accountID) ?? accounts[0]
        messages.append(Message(accountID: acct.id, mailbox: .drafts, from: Contact(name: acct.name, email: acct.address),
                                to: Contact.parseList(d.to), subject: d.subject.isEmpty ? "(No Subject)" : d.subject,
                                body: d.body, date: .now, isRead: true))
    }
}
