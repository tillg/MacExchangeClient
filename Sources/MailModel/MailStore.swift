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
    /// Last sync problem or notice, shown under the window title.
    public var status: String?
    public private(set) var isRefreshing = false

    private var backends: [UUID: any MailBackend] = [:]
    private var remoteFolders: [UUID: [RemoteFolder]] = [:]
    private var syncTokens: [String: String] = [:]

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

    /// Every local action goes through here or `delete`. Server messages stay unchanged
    /// until changes are written back to the server.
    private func update(_ ids: Set<Message.ID>, _ f: (inout Message) -> Void) {
        let ids = localOnly(ids)
        for i in messages.indices where ids.contains(messages[i].id) { f(&messages[i]) }
    }

    private func localOnly(_ ids: Set<Message.ID>) -> Set<Message.ID> {
        let remote = Set(messages.filter { ids.contains($0.id) && $0.remoteID != nil }.map(\.id))
        if !remote.isEmpty { status = "Changes to Exchange messages aren't saved to the server yet" }
        return ids.subtracting(remote)
    }

    public func move(_ ids: Set<Message.ID>, to box: MailboxKind) { update(ids) { $0.mailbox = box } }

    public func delete(_ ids: Set<Message.ID>) {
        let ids = localOnly(ids)
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
        update(Set(messages.filter { contains(ref, $0) }.map(\.id))) { $0.isRead = true }
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

    // MARK: Server sync

    /// Adds a server account. Its mail arrives with the next `refresh()`.
    public func add(_ account: Account, backend: any MailBackend) {
        accounts.append(account)
        backends[account.id] = backend
    }

    /// Drops accounts without a server (the sample data) and their local messages.
    public func removeLocalAccounts() {
        let local = Set(accounts.filter { backends[$0.id] == nil }.map(\.id))
        accounts.removeAll { local.contains($0.id) }
        messages.removeAll { local.contains($0.accountID) && $0.remoteID == nil }
        selection = []
        selectedMailbox = .smart(.allInboxes)
    }

    public func syncToken(_ account: UUID, _ box: MailboxKind) -> String? { syncTokens[key(account, box)] }

    private func key(_ account: UUID, _ box: MailboxKind) -> String { "\(account)/\(box.rawValue)" }

    /// Merges server changes into one mailbox. Known messages keep their local ID, selection and loaded body.
    public func apply(_ r: SyncResult, account: UUID, mailbox: MailboxKind) {
        let gone = Set(r.deletedRemoteIDs)
        if !gone.isEmpty {
            let ids = Set(messages.filter { $0.accountID == account && $0.remoteID.map(gone.contains) == true }.map(\.id))
            messages.removeAll { ids.contains($0.id) }
            selection.subtract(ids)
        }
        var index = [String: Int]()
        for (i, m) in messages.enumerated() where m.accountID == account { if let r = m.remoteID { index[r] = i } }
        for var m in r.upserts {
            m.accountID = account
            m.mailbox = mailbox
            if let rid = m.remoteID, let i = index[rid] {
                let old = messages[i]
                m.id = old.id
                if old.bodyLoaded && !m.bodyLoaded { m.body = old.body; m.attachments = old.attachments; m.bodyLoaded = true }
                messages[i] = m
            } else {
                messages.append(m)
                if let rid = m.remoteID { index[rid] = messages.count - 1 }
            }
        }
        if !r.readChanges.isEmpty {
            for i in messages.indices where messages[i].accountID == account {
                if let rid = messages[i].remoteID, let read = r.readChanges[rid] { messages[i].isRead = read }
            }
        }
        syncTokens[key(account, mailbox)] = r.token
    }

    public func setBody(_ b: MessageBody, for id: Message.ID) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].body = b.text
        messages[i].attachments = b.attachments
        messages[i].hasAttachments = !b.attachments.isEmpty
        messages[i].bodyLoaded = true
        if let f = b.from { messages[i].from = f }
        if let to = b.to { messages[i].to = to }
        if let cc = b.cc { messages[i].cc = cc }
    }

    /// Fetches the body of a server message the first time it is shown.
    public func loadBody(_ id: Message.ID) async {
        guard let m = message(id), !m.bodyLoaded, let rid = m.remoteID, let backend = backends[m.accountID] else { return }
        do { setBody(try await backend.body(remoteID: rid), for: id) } catch { status = "Couldn't load message: \(error.localizedDescription)" }
    }

    /// Pulls changes for every server account. The first run shows the newest messages first, then syncs fully.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        for (acct, backend) in backends {
            do {
                if remoteFolders[acct] == nil { remoteFolders[acct] = try await backend.folders() }
                for folder in remoteFolders[acct] ?? [] {
                    if syncToken(acct, folder.role) == nil {
                        let first = try await backend.newest(in: folder, limit: 200)
                        apply(SyncResult(upserts: first, deletedRemoteIDs: [], token: "", more: false),
                              account: acct, mailbox: folder.role)
                        syncTokens[key(acct, folder.role)] = nil
                    }
                    var more = true
                    while more {
                        let r = try await backend.sync(folder, token: syncToken(acct, folder.role))
                        apply(r, account: acct, mailbox: folder.role)
                        more = r.more
                    }
                }
                status = nil
            } catch {
                status = "\(account(acct)?.name ?? "Account"): \(error.localizedDescription)"
            }
        }
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
        guard backends[acct.id] == nil else { status = "Sending from Exchange accounts isn't supported yet"; return }
        messages.append(Message(accountID: acct.id, mailbox: .sent, from: Contact(name: acct.name, email: acct.address),
                                to: Contact.parseList(d.to), cc: Contact.parseList(d.cc), subject: d.subject,
                                body: d.body, date: .now, isRead: true))
    }

    public func saveDraft(_ d: Draft) {
        let acct = account(d.accountID) ?? accounts[0]
        guard backends[acct.id] == nil else { status = "Saving drafts to Exchange isn't supported yet"; return }
        messages.append(Message(accountID: acct.id, mailbox: .drafts, from: Contact(name: acct.name, email: acct.address),
                                to: Contact.parseList(d.to), subject: d.subject.isEmpty ? "(No Subject)" : d.subject,
                                body: d.body, date: .now, isRead: true))
    }
}
