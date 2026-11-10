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
    /// Shown at the bottom of the sidebar while checking for mail, like Mail's activity view.
    public var progress: SyncProgress?

    private var backends: [UUID: any MailBackend] = [:]
    private var remoteFolders: [UUID: [RemoteFolder]] = [:]
    private var syncTokens: [String: String] = [:]
    /// Accounts whose messages live on a server (they have a backend or received a sync).
    private var serverAccounts: Set<UUID> = []
    /// Local changes not yet written to the server, oldest first.
    public private(set) var outbox: [PendingChange] = []
    private var flushTask: Task<Void, Never>?
    /// IDs per server request, so "Mark All as Read" on a big inbox doesn't send one huge request.
    public static let batchSize = 100

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

    /// Every local action goes through here or `delete`. Server messages change locally at once and
    /// the change is queued for the server.
    private func update(_ ids: Set<Message.ID>, _ f: (inout Message) -> Void) {
        var changed: [(old: Message, new: Message)] = []
        for i in messages.indices where ids.contains(messages[i].id) {
            let old = messages[i]
            f(&messages[i])
            guard old.remoteID != nil, messages[i] != old else { continue }
            if messages[i].accountID != old.accountID {
                messages[i] = old
                status = "Exchange messages can't be moved to another account yet"
                continue
            }
            changed.append((old, messages[i]))
        }
        queue(changed)
    }

    private enum ChangeKind: Hashable { case read(Bool), flagged(Bool), move(MailboxKind) }

    /// Groups changed server messages into batched server changes, in a stable order.
    private func queue(_ changed: [(old: Message, new: Message)]) {
        var order: [(UUID, ChangeKind)] = []
        var groups: [String: [Message]] = [:]
        func add(_ acct: UUID, _ k: ChangeKind, _ old: Message) {
            let key = "\(acct)/\(k)"
            if groups[key] == nil { order.append((acct, k)) }
            groups[key, default: []].append(old)
        }
        for (old, new) in changed {
            if old.isRead != new.isRead { add(old.accountID, .read(new.isRead), old) }
            if (old.flag != nil) != (new.flag != nil) { add(old.accountID, .flagged(new.flag != nil), old) }
            if old.mailbox != new.mailbox { add(old.accountID, .move(new.mailbox), old) }
        }
        for (acct, k) in order {
            enqueue(groups["\(acct)/\(k)"]!, account: acct) { ids in
                switch k {
                case let .read(v): .setRead(ids, v)
                case let .flagged(v): .setFlagged(ids, v)
                case let .move(box): .move(ids, to: box)
                }
            }
        }
    }

    private func enqueue(_ olds: [Message], account: UUID, _ make: ([String]) -> ServerChange) {
        for start in stride(from: 0, to: olds.count, by: Self.batchSize) {
            let chunk = Array(olds[start..<min(start + Self.batchSize, olds.count)])
            outbox.append(PendingChange(account: account, change: make(chunk.compactMap(\.remoteID)), previous: chunk))
        }
        scheduleFlush()
    }

    public func move(_ ids: Set<Message.ID>, to box: MailboxKind) { update(ids) { $0.mailbox = box } }

    public func delete(_ ids: Set<Message.ID>) {
        let erase = messages.filter { ids.contains($0.id) && $0.mailbox == .trash }
        let eraseIDs = Set(erase.map(\.id))
        messages.removeAll { eraseIDs.contains($0.id) }
        for (acct, group) in Dictionary(grouping: erase.filter { $0.remoteID != nil }, by: \.accountID) {
            enqueue(group, account: acct) { .delete($0) }
        }
        move(ids.subtracting(eraseIDs), to: .trash)
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
        var moving = Set(messages.filter { ids.contains($0.id) && !contains(ref, $0) }.map(\.id))
        if case let .account(acct, _) = ref {
            let blocked = messages.filter { moving.contains($0.id) && $0.remoteID != nil && $0.accountID != acct }
            if !blocked.isEmpty { status = "Exchange messages can't be moved to another account yet" }
            moving.subtract(blocked.map(\.id))
        }
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
        serverAccounts.insert(account.id)
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
                if old.flag != nil && m.flag != nil { m.flag = old.flag }  // the server has no colours
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
        serverAccounts.insert(account)
    }

    // MARK: Disk cache

    /// Server mail, sync positions and unsent changes of every server account. Sample data isn't cached.
    public func cache() -> MailCache {
        var out: [UUID: MailCache.AccountState] = [:]
        for acct in serverAccounts {
            var tokens: [MailboxKind: String] = [:]
            for box in MailboxKind.allCases { tokens[box] = syncTokens[key(acct, box)] }
            out[acct] = MailCache.AccountState(messages: messages.filter { $0.accountID == acct && $0.remoteID != nil },
                                               syncTokens: tokens, outbox: outbox.filter { $0.account == acct })
        }
        return MailCache(accounts: out)
    }

    /// Loads cached mail for the accounts this store has, before the first sync, so a launch starts
    /// where the last one stopped and syncs only what changed since.
    public func restore(_ c: MailCache) {
        for acct in accounts.map(\.id) {
            guard let state = c.accounts[acct] else { continue }
            let known = Set(messages.compactMap { $0.accountID == acct ? $0.remoteID : nil })
            messages += state.messages.filter { !known.contains($0.remoteID ?? "") }
            for (box, token) in state.syncTokens { syncTokens[key(acct, box)] = token }
            outbox += state.outbox
            serverAccounts.insert(acct)
        }
        scheduleFlush()
    }

    // MARK: Write-back

    /// Exchange gives moved items new IDs. Updates the messages and the changes still queued.
    public func renameRemote(_ map: [String: String], account: UUID) {
        for i in messages.indices where messages[i].accountID == account {
            if let rid = messages[i].remoteID, let new = map[rid] { messages[i].remoteID = new }
        }
        for i in outbox.indices where outbox[i].account == account { outbox[i].change = outbox[i].change.renamed(map) }
    }

    /// The server refused a change: undo it locally. A message that couldn't be sent is kept in Drafts.
    public func failed(_ p: PendingChange, _ error: String) {
        outbox.removeAll { $0.id == p.id }
        switch p.change {
        case let .send(d), let .saveDraft(d):
            let acct = account(d.accountID)
            messages.append(Message(accountID: d.accountID, mailbox: .drafts,
                                    from: Contact(name: acct?.name ?? "", email: acct?.address ?? ""),
                                    to: Contact.parseList(d.to), cc: Contact.parseList(d.cc),
                                    subject: d.subject.isEmpty ? "(No Subject)" : d.subject,
                                    body: d.body, date: .now, isRead: true))
            status = "Couldn't send “\(d.subject)”: \(error). It's in Drafts on this Mac."
        default:
            for old in p.previous {
                if let i = messages.firstIndex(where: { $0.id == old.id }) {
                    messages[i].mailbox = old.mailbox
                    messages[i].isRead = old.isRead
                    messages[i].flag = old.flag
                } else {
                    messages.append(old)
                }
            }
            status = "Exchange refused a change: \(error)"
        }
    }

    private func scheduleFlush() {
        guard flushTask == nil, outbox.contains(where: { backends[$0.account] != nil }) else { return }
        flushTask = Task {
            await drain()
            flushTask = nil
        }
    }

    /// Writes queued changes in order. When offline, changes stay queued for the next refresh;
    /// a send is never retried, because a timed-out send may have gone out.
    private func drain() async {
        while let p = outbox.first(where: { backends[$0.account] != nil }), let backend = backends[p.account] {
            do {
                try await perform(p, backend)
                outbox.removeAll { $0.id == p.id }
            } catch let e as URLError {
                if case .send = p.change { failed(p, e.localizedDescription); continue }
                status = "Offline – changes will be sent to Exchange later"
                return
            } catch {
                failed(p, error.localizedDescription)
            }
        }
    }

    private func perform(_ p: PendingChange, _ b: any MailBackend) async throws {
        switch p.change {
        case let .setRead(ids, v): try await b.setRead(ids, v)
        case let .setFlagged(ids, v): try await b.setFlagged(ids, v)
        case let .move(ids, box):
            guard let folder = remoteFolders[p.account]?.first(where: { $0.role == box }) else {
                throw MailError("There is no \(box.title) folder on the server")
            }
            renameRemote(try await b.move(ids, to: folder), account: p.account)
        case let .delete(ids): try await b.delete(ids)
        case let .send(d): try await b.send(d)
        case let .saveDraft(d): try await b.saveDraft(d)
        }
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
        // Write first, so the sync doesn't briefly bring back the old state.
        scheduleFlush()
        await flushTask?.value
        defer { progress = nil }
        let all = Array(backends)
        for (a, (acct, backend)) in all.enumerated() {
            do {
                progress = SyncProgress(text: "Checking for Mail…", fraction: Self.checkingFraction(a, all.count, 0, 1, 0))
                if remoteFolders[acct] == nil { remoteFolders[acct] = try await backend.folders() }
                let folders = remoteFolders[acct] ?? []
                for (f, folder) in folders.enumerated() {
                    var pages = 0
                    func step() { progress?.fraction = Self.checkingFraction(a, all.count, f, folders.count, pages) }
                    step()
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
                        pages += 1
                        step()
                    }
                }
                status = nil
            } catch {
                status = "\(account(acct)?.name ?? "Account"): \(error.localizedDescription)"
            }
        }
    }

    /// Account by account, folder by folder. A folder's full sync has no known length, so each page
    /// covers half of what is left of that folder's share.
    nonisolated static func checkingFraction(_ account: Int, _ accounts: Int, _ folder: Int, _ folders: Int, _ pages: Int) -> Double {
        guard accounts > 0, folders > 0 else { return 0 }
        let inFolder = 1 - pow(0.5, Double(pages))
        return (Double(account) + (Double(folder) + inFolder) / Double(folders)) / Double(accounts)
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
        if serverAccounts.contains(acct.id) {
            outbox.append(PendingChange(account: acct.id, change: .send(d), previous: []))
            return scheduleFlush()
        }
        messages.append(Message(accountID: acct.id, mailbox: .sent, from: Contact(name: acct.name, email: acct.address),
                                to: Contact.parseList(d.to), cc: Contact.parseList(d.cc), subject: d.subject,
                                body: d.body, date: .now, isRead: true))
    }

    public func saveDraft(_ d: Draft) {
        let acct = account(d.accountID) ?? accounts[0]
        if serverAccounts.contains(acct.id) {
            outbox.append(PendingChange(account: acct.id, change: .saveDraft(d), previous: []))
            return scheduleFlush()
        }
        messages.append(Message(accountID: acct.id, mailbox: .drafts, from: Contact(name: acct.name, email: acct.address),
                                to: Contact.parseList(d.to), subject: d.subject.isEmpty ? "(No Subject)" : d.subject,
                                body: d.body, date: .now, isRead: true))
    }
}

struct MailError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}
