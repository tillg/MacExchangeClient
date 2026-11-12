import CoreServices
import Foundation
import UniformTypeIdentifiers
import Observation

@MainActor
@Observable
public final class MailStore {
    public var accounts: [Account]
    public private(set) var messages: [Message] { didSet { revision &+= 1 } }
    /// Bumped on every change to `messages`; the caches below are valid for one revision.
    @ObservationIgnored private var revision = 0
    /// Changes when the messages change, to skip saving an unchanged cache.
    public var changeCount: Int { revision }
    @ObservationIgnored private var countsCache: (revision: Int, total: [MailboxRef: Int], unread: [MailboxRef: Int])?
    @ObservationIgnored private var listCache: (revision: Int, key: ListKey, list: [Message])?

    public var selectedMailbox: MailboxRef = .smart(.allInboxes) {
        didSet {
            if selectedMailbox != oldValue && !openedUnread.isEmpty { openedUnread = [] }
            if searchScope(selectedMailbox) != searchScope(oldValue) { searchTextChanged() }
        }
    }
    public var selection: Set<Message.ID> = [] {
        didSet { if !openedUnread.isSubset(of: selection) { openedUnread.formIntersection(selection) } }
    }
    public var filterUnread = false { didSet { if filterUnread != oldValue && !openedUnread.isEmpty { openedUnread = [] } } }
    /// Messages that were unread when opened. As in Mail, they stay in the unread-filtered list and in Unread
    /// while selected, and leave once the selection moves on or the filter or mailbox changes.
    private var openedUnread: Set<Message.ID> = []
    public var searchText = "" { didSet { if searchText != oldValue { searchTextChanged() } } }
    /// Searches the mail database's index (words, accounts or nil for all → IDs, newest first). Nil with
    /// sample data or until the index is ready: search then scans memory.
    @ObservationIgnored public var searcher: (@Sendable (String, Set<UUID>?) async throws -> [Message.ID])? {
        didSet {
            // Typed before the index was ready: memory keeps answering until the index's first answer is in.
            guard searcher != nil, !normalizedSearch.isEmpty else { return }
            fallbackQuery = normalizedSearch
            searchAgain()
        }
    }
    /// The index's answer for a query; shown until the next query's answer arrives.
    public private(set) var searchHits: (query: String, ids: Set<Message.ID>)? { didSet { hitsGeneration &+= 1 } }
    @ObservationIgnored private var hitsGeneration = 0
    /// A query the index couldn't answer: memory is scanned for it instead.
    private var fallbackQuery: String?
    @ObservationIgnored private(set) var searchTask: Task<Void, Never>?
    /// Wait after a keystroke before asking the index.
    @ObservationIgnored var searchDebounce: Duration = .milliseconds(150)
    /// Last sync problem or notice, shown under the window title.
    public var status: String?
    public private(set) var isRefreshing = false
    /// Shown at the bottom of the sidebar while checking for mail, like Mail's activity view.
    public var progress: SyncProgress?

    /// Each account's folders of its own, as a tree (see `children(of:account:)`).
    public private(set) var folders: [UUID: [Folder]] = [:] { didSet { foldersChanged = true } }

    private var backends: [UUID: any MailBackend] = [:]
    private var remoteFolders: [UUID: [RemoteFolder]] = [:]
    private var syncTokens: [String: String] = [:] { didSet { syncChanged = true } }
    /// Folders ("account/mailbox") whose full sync has finished; checks then only fetch changes.
    private var complete: Set<String> = [] { didSet { syncChanged = true } }
    private var historyTask: Task<Void, Never>?
    /// Folders whose history sync failed this session; retried after a relaunch.
    private var historyFailed: Set<String> = []
    /// Accounts whose sign-in failed. Nothing is sent for them until the app is relaunched.
    private var paused: Set<UUID> = []
    private var historyError: String?
    /// Folders whose newest 200 the history already fetched this session.
    private var newestLoaded: Set<String> = []
    /// Accounts whose messages live on a server (they have a backend or received a sync).
    private var serverAccounts: Set<UUID> = []
    /// Local changes not yet written to the server, oldest first.
    public private(set) var outbox: [PendingChange] = [] { didSet { outboxChanged = true } }

    // What changed since the last `takeChanges()`, for writing to disk.
    @ObservationIgnored private var changedIDs = Set<Message.ID>()
    @ObservationIgnored private var removedIDs = Set<Message.ID>()
    @ObservationIgnored private var syncChanged = false
    @ObservationIgnored private var foldersChanged = false
    @ObservationIgnored private var outboxChanged = false
    /// Mailboxes whose stored mail is in memory while launch is still loading; nil once everything is.
    @ObservationIgnored private var loadedBoxes: Set<String>?
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

    /// The folders directly in `parent` (nil: at the top of the account), by name as Finder sorts.
    public func children(of parent: MailboxKind?, account: UUID) -> [Folder] {
        (folders[account] ?? []).filter { $0.parent == parent }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The mailbox's name: the standard title, or the folder's own.
    public func name(of box: MailboxKind, in account: UUID) -> String {
        box.isStandard ? box.title : folders[account]?.first { $0.box == box }?.name ?? ""
    }

    /// Sets an account's folder tree (for local accounts; server accounts get theirs from the server).
    public func setFolders(_ f: [Folder], account: UUID) { folders[account] = f }

    /// The server's folder list: the user's own folders become the account's tree.
    func setRemoteFolders(_ remote: [RemoteFolder], account: UUID) {
        remoteFolders[account] = remote
        folders[account] = remote.filter { !$0.role.isStandard }.map { Folder(box: $0.role, name: $0.name, parent: $0.parent) }
    }

    func contains(_ ref: MailboxRef, _ m: Message) -> Bool {
        switch ref {
        case .smart(.allInboxes): m.mailbox == .inbox
        case .smart(.vip): m.isVIP && m.mailbox == .inbox
        case .smart(.flagged): m.flag != nil && m.mailbox != .trash
        case .smart(.unread): !m.isRead && m.mailbox == .inbox
        case let .account(id, kind): m.accountID == id && m.mailbox == kind
        }
    }

    public func unreadCount(_ ref: MailboxRef) -> Int { counts().unread[ref] ?? 0 }

    public func count(_ ref: MailboxRef) -> Int { counts().total[ref] ?? 0 }

    /// Every sidebar count in one pass over the messages, cached until they change.
    private func counts() -> (total: [MailboxRef: Int], unread: [MailboxRef: Int]) {
        _ = messages.count  // registers the dependency for SwiftUI even when the cache answers
        if let c = countsCache, c.revision == revision { return (c.total, c.unread) }
        // Per account and mailbox first (few keys, cheap to hash), smart mailboxes alongside.
        struct Key: Hashable { let account: UUID; let box: MailboxKind }
        // Messages of one mailbox mostly sit together, so the key (a string, long for Exchange folders) is
        // hashed once per run of them, not once per message.
        var keys: [Key] = [], tally: [(total: Int, unread: Int)] = [], slot: [Key: Int] = [:], last = -1
        var smart: [SmartMailbox: (total: Int, unread: Int)] = [:]
        for m in messages {
            let u = m.isRead ? 0 : 1
            if last < 0 || keys[last].account != m.accountID || keys[last].box != m.mailbox {
                let k = Key(account: m.accountID, box: m.mailbox)
                if let i = slot[k] { last = i } else { last = keys.count; slot[k] = last; keys.append(k); tally.append((0, 0)) }
            }
            tally[last].total += 1
            tally[last].unread += u
            if m.mailbox == .inbox {
                smart[.allInboxes, default: (0, 0)].total += 1; smart[.allInboxes, default: (0, 0)].unread += u
                if m.isVIP { smart[.vip, default: (0, 0)].total += 1; smart[.vip, default: (0, 0)].unread += u }
                if u == 1 { smart[.unread, default: (0, 0)].total += 1; smart[.unread, default: (0, 0)].unread += 1 }
            }
            if m.flag != nil && m.mailbox != .trash {
                smart[.flagged, default: (0, 0)].total += 1; smart[.flagged, default: (0, 0)].unread += u
            }
        }
        var total: [MailboxRef: Int] = [:], unread: [MailboxRef: Int] = [:]
        for (k, v) in zip(keys, tally) { total[.account(k.account, k.box)] = v.total; unread[.account(k.account, k.box)] = v.unread }
        for (k, v) in smart { total[.smart(k)] = v.total; unread[.smart(k)] = v.unread }
        countsCache = (revision, total, unread)
        return (total, unread)
    }

    private struct ListKey: Equatable {
        var mailbox: MailboxRef, query: String, filterUnread: Bool, hits: Int, openedUnread: Set<Message.ID>
    }

    /// Messages for the list pane: mailbox (or whole account/all mail while searching),
    /// unread filter, newest first.
    public var visibleMessages: [Message] {
        let typed = normalizedSearch
        // With the index, the list shows its latest answer (the previous query's while the next one is on its
        // way), or the mailbox until the first answer arrives. Without it, memory is scanned.
        // Keyed by the answer's query, not the typed text, so keystrokes before the next answer cost nothing.
        let useIndex = !typed.isEmpty && searcher != nil && fallbackQuery != typed
        let hits = useIndex ? searchHits : nil
        let q = useIndex ? hits?.query ?? "" : typed
        let opened = openedUnread
        let key = ListKey(mailbox: selectedMailbox, query: q, filterUnread: filterUnread, hits: hits == nil ? -1 : hitsGeneration,
                          openedUnread: opened)
        _ = messages.count  // registers the dependency for SwiftUI even when the cache answers
        if let c = listCache, c.revision == revision, c.key == key { return c.list }
        if let hits, !q.isEmpty {
            let list = Self.hitList(messages, hits.ids, scope: searchScope(selectedMailbox))
            listCache = (revision, key, list)
            return list
        }
        let list = messages.filter { m in
            if !q.isEmpty {
                guard inSearchScope(m), m.mailbox != .trash, m.mailbox != .junk else { return false }
                return [m.subject, m.from.name, m.from.email, m.body].contains { $0.lowercased().contains(q) }
            }
            if !opened.isEmpty && opened.contains(m.id) {
                var asOpened = m
                asOpened.isRead = false
                return contains(selectedMailbox, asOpened)
            }
            guard contains(selectedMailbox, m) else { return false }
            if filterUnread && m.isRead { return false }
            return true
        }
        .sorted { $0.date > $1.date }
        listCache = (revision, key, list)
        return list
    }

    /// The index's hits as they are in memory now: in scope, not in Trash or Junk, newest first.
    /// Split across the cores: one pass over 180,000 messages takes about 45 ms in a debug build.
    nonisolated private static func hitList(_ msgs: [Message], _ hits: Set<Message.ID>, scope: Set<UUID>?) -> [Message] {
        let chunks = 8, size = (msgs.count + chunks - 1) / chunks
        nonisolated(unsafe) let parts = UnsafeMutableBufferPointer<[Message]>.allocate(capacity: chunks)
        _ = parts.initialize(from: repeatElement([], count: chunks))
        defer { parts.deinitialize(); parts.deallocate() }
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            parts[c] = msgs[min(c * size, msgs.count)..<min((c + 1) * size, msgs.count)].filter { m in
                hits.contains(m.id) && scope?.contains(m.accountID) != false && m.mailbox != .trash && m.mailbox != .junk
            }
        }
        return parts.flatMap { $0 }.sorted { $0.date > $1.date }
    }

    private func inSearchScope(_ m: Message) -> Bool {
        if case let .account(id, _) = selectedMailbox { return m.accountID == id }
        return true
    }

    private var normalizedSearch: String { searchText.trimmingCharacters(in: .whitespaces).lowercased() }

    /// The accounts a search covers: the selected one, or nil for all.
    private func searchScope(_ ref: MailboxRef) -> Set<UUID>? {
        if case let .account(id, _) = ref { return [id] }
        return nil
    }

    /// Asks the index for the current search, after a short pause for more typing. An answer that arrives
    /// after the text has changed again is dropped.
    func searchTextChanged() {
        searchTask?.cancel()
        let q = normalizedSearch
        guard !q.isEmpty else {
            searchTask = nil; searchHits = nil; fallbackQuery = nil
            if status == Self.limitNotice { status = nil }
            return
        }
        guard searcher != nil else { return }
        searchTask = Task { [debounce = searchDebounce] in
            if debounce > .zero {
                do { try await Task.sleep(for: debounce) } catch { return }
            }
            await runSearch(q)
        }
    }

    /// Runs the current search again, without a pause, keeping the results on screen meanwhile: after a save,
    /// so the index catches up with what arrived since.
    public func searchAgain() {
        let q = normalizedSearch
        guard !q.isEmpty, searcher != nil else { return }
        searchTask?.cancel()
        searchTask = Task { await runSearch(q) }
    }

    private func runSearch(_ q: String) async {
        guard let searcher else { return }
        let scope = searchScope(selectedMailbox)
        let snapshot = messages, snapshotRevision = revision
        do {
            // Detached, so neither the query nor the pass over all messages runs on the main actor.
            let (ids, hits, list) = try await Task.detached(priority: .userInitiated) {
                let ids = try await searcher(q, scope), hits = Set(ids)
                return (ids, hits, Self.hitList(snapshot, hits, scope: scope))
            }.value
            guard !Task.isCancelled, normalizedSearch == q, searchScope(selectedMailbox) == scope else { return }
            fallbackQuery = nil
            searchHits = (q, hits)
            // The list is ready unless mail changed meanwhile; then `visibleMessages` makes it again.
            if revision == snapshotRevision {
                listCache = (revision, ListKey(mailbox: selectedMailbox, query: q, filterUnread: filterUnread,
                                               hits: hitsGeneration, openedUnread: openedUnread), list)
            }
            if ids.count >= MailDatabase.searchLimit {
                status = Self.limitNotice
            } else if status == Self.limitNotice {
                status = nil
            }
        } catch {
            guard !Task.isCancelled, normalizedSearch == q else { return }
            fallbackQuery = q
            status = "Search failed: \(error.localizedDescription)"
        }
    }

    static let limitNotice = "Showing the newest 2,000 results"

    public var selectedMessage: Message? { selection.count == 1 ? selection.first.flatMap(message) : nil }

    @ObservationIgnored private var conversationCache: (revision: Int, id: Message.ID, list: [Message])?

    /// The message with the rest of its conversation, newest first, as Mail shows it: the same account, every
    /// mailbox but Trash, Junk and Drafts (the message itself always). Empty if the message is gone.
    public func conversation(of id: Message.ID) -> [Message] {
        _ = messages.count  // registers the dependency for SwiftUI even when the cache answers
        if let c = conversationCache, c.revision == revision, c.id == id { return c.list }
        guard let m = message(id) else { return [] }
        var list = [m]
        if let conv = m.conversationID {
            let skip: Set<MailboxKind> = [.trash, .junk, .drafts]
            list = messages.filter {
                $0.id == id || ($0.conversationID == conv && $0.accountID == m.accountID && !skip.contains($0.mailbox))
            }
            .sorted { $0.date > $1.date }
        }
        conversationCache = (revision, id, list)
        return list
    }

    public var title: String {
        switch selectedMailbox {
        case .smart(let s): s == .allInboxes ? "All Inboxes" : s.title
        case let .account(id, kind):
            kind == .inbox ? "Inbox – \(account(id)?.name ?? "")" : name(of: kind, in: id)
        }
    }

    // MARK: Mutations

    /// Every local action goes through here or `delete`. Server messages change locally at once and
    /// the change is queued for the server.
    private func update(_ ids: Set<Message.ID>, _ f: (inout Message) -> Void) {
        changedIDs.formUnion(ids)
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

    public func move(_ ids: Set<Message.ID>, to box: MailboxKind) {
        keepingSelectionVisible(ids) { update(ids) { $0.mailbox = box } }
    }

    public func delete(_ ids: Set<Message.ID>) {
        keepingSelectionVisible(ids) {
            let erase = messages.filter { ids.contains($0.id) && $0.mailbox == .trash }
            let eraseIDs = Set(erase.map(\.id))
            messages.removeAll { eraseIDs.contains($0.id) }
            forget(eraseIDs)
            for (acct, group) in Dictionary(grouping: erase.filter { $0.remoteID != nil }, by: \.accountID) {
                enqueue(group, account: acct) { .delete($0) }
            }
            update(ids.subtracting(eraseIDs)) { $0.mailbox = .trash }
        }
    }

    public func archive(_ ids: Set<Message.ID>) { move(ids, to: .archive) }

    public func toggleJunk(_ ids: Set<Message.ID>) {
        keepingSelectionVisible(ids) { update(ids) { $0.mailbox = $0.mailbox == .junk ? .inbox : .junk } }
    }

    /// Runs a move or delete of `ids`. Selected messages it takes out of the list (or erases) don't stay
    /// selected, so a second Delete can't erase a message the user never saw in Trash. When that was the whole
    /// selection, the message that followed it in the list is selected, as after Delete.
    private func keepingSelectionVisible(_ ids: Set<Message.ID>, _ body: () -> Void) {
        guard !selection.isDisjoint(with: ids) else { body(); return }
        let list = visibleMessages.map(\.id), before = selection
        body()
        let remaining = Set(visibleMessages.map(\.id))
        let gone = before.intersection(ids).subtracting(remaining)
        guard !gone.isEmpty, selection == before else { return }
        selection = gone == before ? Self.following(before, in: list, remaining: remaining) ?? [] : before.subtracting(gone)
    }

    /// The message after the last of `ids` in `list` that is still in it (else the one before), as Mail selects
    /// after an action; nil when none of `ids` was in the list.
    private static func following(_ ids: Set<Message.ID>, in list: [Message.ID], remaining: Set<Message.ID>) -> Set<Message.ID>? {
        guard let lastIdx = list.lastIndex(where: ids.contains) else { return nil }
        let next = list[(lastIdx + 1)...].first { remaining.contains($0) && !ids.contains($0) }
            ?? list[..<lastIdx].last { remaining.contains($0) && !ids.contains($0) }
        return next.map { [$0] } ?? []
    }

    public func setFlag(_ c: FlagColor?, for ids: Set<Message.ID>) { update(ids) { $0.flag = c } }

    public func toggleRead(_ ids: Set<Message.ID>) {
        let anyUnread = messages.contains { ids.contains($0.id) && !$0.isRead }
        update(ids) { $0.isRead = anyUnread }
    }

    public func markSelectionRead() {
        var opened: [Message.ID] = []
        update(selection) { m in
            if !m.isRead { opened.append(m.id) }
            m.isRead = true
        }
        openedUnread.formUnion(opened)
    }

    public func markAllRead(in ref: MailboxRef) {
        update(Set(messages.filter { contains(ref, $0) }.map(\.id))) { $0.isRead = true }
    }

    /// Runs `action` on the selection, then selects the message that followed it in the list – as Mail does.
    /// A selection that wasn't in the list (hidden by the unread filter or a search) isn't kept selected
    /// once the action takes it out of the list.
    public func actOnSelection(_ action: (Set<Message.ID>) -> Void) {
        let list = visibleMessages.map(\.id)
        let ids = selection
        action(ids)
        let remaining = Set(visibleMessages.map(\.id))
        selection = Self.following(ids, in: list, remaining: remaining) ?? ids.intersection(remaining)
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
            self.keepingSelectionVisible(ids) { self.update(ids) { m in
                switch ref {
                case .smart(.flagged): if m.flag == nil { m.flag = .red }
                case .smart(.allInboxes): m.mailbox = .inbox
                case let .account(acct, kind): m.accountID = acct; m.mailbox = kind
                case .smart(.vip), .smart(.unread): break
                }
            } }
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

    public func isComplete(_ account: UUID, _ box: MailboxKind) -> Bool { complete.contains(key(account, box)) }

    private func key(_ account: UUID, _ box: MailboxKind) -> String { "\(account)/\(box.rawValue)" }

    /// Merges one page of a folder sync and moves that folder's sync position on.
    /// The last page (`more == false`) completes the folder: later checks then only fetch changes.
    public func apply(_ r: SyncResult, account: UUID, mailbox: MailboxKind) {
        merge(r.upserts, deleted: r.deletedRemoteIDs, reads: r.readChanges, account: account, mailbox: mailbox)
        syncTokens[key(account, mailbox)] = r.token
        if !r.more { complete.insert(key(account, mailbox)) }
    }

    /// Applies several pages of one folder in one merge, as if one after the other. Each merge goes over every
    /// message, so a batch of history pages costs one pass instead of one per page.
    public func apply(_ pages: [SyncResult], account: UUID, mailbox: MailboxKind) {
        guard let last = pages.last else { return }
        var upserts: [Message] = [], slot: [String: Int] = [:], deleted = Set<String>(), reads: [String: Bool] = [:]
        for p in pages {
            for rid in p.deletedRemoteIDs {
                slot[rid] = nil  // an earlier page's version is dropped: only messages still in `slot` are merged
                reads[rid] = nil
                deleted.insert(rid)
            }
            for m in p.upserts {
                guard let rid = m.remoteID else { continue }  // server messages always have one
                deleted.remove(rid); reads[rid] = nil
                if let i = slot[rid] { upserts[i] = m } else { slot[rid] = upserts.count; upserts.append(m) }
            }
            for (rid, v) in p.readChanges {
                if let i = slot[rid] { upserts[i].isRead = v } else { reads[rid] = v }
            }
        }
        merge(slot.sorted { $0.value < $1.value }.map { upserts[$0.value] }, deleted: Array(deleted), reads: reads,
              account: account, mailbox: mailbox)
        syncTokens[key(account, mailbox)] = last.token
        if !last.more { complete.insert(key(account, mailbox)) }
    }

    /// Merges server messages into one mailbox without touching its sync position (used for the newest-N
    /// lookup). Known messages keep their local ID, selection and loaded body. Messages with a change still
    /// waiting for the server keep their local read state, flag and mailbox.
    public func merge(_ upserts: [Message], deleted: [String] = [], reads: [String: Bool] = [:],
                      account: UUID, mailbox: MailboxKind) {
        merge([(mailbox, upserts)], deleted: deleted, reads: reads, account: account)
    }

    /// The same for several mailboxes in one pass over all messages, e.g. the newest messages of each folder.
    /// When nothing changes, `messages` isn't touched: assigning it redraws every view.
    public func merge(_ groups: [(MailboxKind, [Message])], deleted: [String] = [], reads: [String: Bool] = [:],
                      account: UUID) {
        serverAccounts.insert(account)
        guard groups.contains(where: { !$0.1.isEmpty }) || !deleted.isEmpty || !reads.isEmpty else { return }
        let mine = outbox.lazy.filter { $0.account == account }
        let pending = Set(mine.flatMap(\.change.remoteIDs))
        // A pending move makes the source folder report the message as deleted; that one stays.
        // Any other deletion (done elsewhere) wins over a pending read or flag change.
        let moving = Set<String>(mine.flatMap { (p: PendingChange) -> [String] in
            if case let .move(ids, _) = p.change { return ids }
            return []
        })
        var ms = messages  // one write to the observed array, not one per message
        var changed = false
        // By index, reading only what's needed: copying each of 180,000 messages is slow.
        let gone = Set(deleted).subtracting(moving)
        if !gone.isEmpty {
            var ids = Set<Message.ID>()
            for i in ms.indices where ms[i].accountID == account {
                if let r = ms[i].remoteID, gone.contains(r) { ids.insert(ms[i].id) }
            }
            if !ids.isEmpty {
                ms.removeAll { ids.contains($0.id) }
                selection.subtract(ids)
                forget(ids)
                changed = true
            }
        }
        var index = [String: Int]()
        for i in ms.indices where ms[i].accountID == account { if let r = ms[i].remoteID { index[r] = i } }
        for (mailbox, upserts) in groups {
            for var m in upserts {
                m.accountID = account
                m.mailbox = mailbox
                if let rid = m.remoteID, let i = index[rid] {
                    let old = ms[i]
                    m.id = old.id
                    if old.flag != nil && m.flag != nil { m.flag = old.flag }  // the server has no colours
                    if old.bodyLoaded && !m.bodyLoaded {
                        m.body = old.body; m.attachments = old.attachments; m.invite = old.invite; m.bodyLoaded = true
                        m.html = old.html; m.htmlChecked = old.htmlChecked
                    }
                    if pending.contains(rid) { m.isRead = old.isRead; m.flag = old.flag; m.mailbox = old.mailbox }
                    guard m != old else { continue }
                    ms[i] = m
                } else {
                    ms.append(m)
                    if let rid = m.remoteID { index[rid] = ms.count - 1 }
                }
                changedIDs.insert(m.id)
                changed = true
            }
        }
        for (rid, read) in reads where !pending.contains(rid) {
            if let i = index[rid], ms[i].isRead != read { ms[i].isRead = read; changedIDs.insert(ms[i].id); changed = true }
        }
        if changed { messages = ms }
    }

    // MARK: Database

    /// A new message: shown at once and written to disk with the next changes.
    private func add(_ m: Message) {
        messages.append(m)
        changedIDs.insert(m.id); removedIDs.remove(m.id)
    }

    private func forget(_ ids: Set<Message.ID>) {
        changedIDs.subtract(ids)
        removedIDs.formUnion(ids)
    }

    /// Accounts whose mail is written to disk: server accounts, not the sample data.
    private func isStored(_ account: UUID) -> Bool { serverAccounts.contains(account) }

    /// What changed since the last call, for `MailDatabase.write`. Messages are taken as they are now.
    /// Cheap on the main thread: see `StoreChanges.resolved()`.
    public func takeChanges() -> StoreChanges {
        var c = StoreChanges()
        if !changedIDs.isEmpty && !serverAccounts.isEmpty {
            // The array is shared, not copied; the write picks the changed messages from it, off the main thread.
            c.snapshot = messages
            c.snapshotIDs = changedIDs
            c.storedAccounts = serverAccounts
        }
        c.removed = Array(removedIDs)
        if syncChanged { c.sync = syncStates() }
        if foldersChanged { c.folders = folders.filter { isStored($0.key) } }
        if outboxChanged { c.outbox = outbox }
        changedIDs = []; removedIDs = []
        syncChanged = false; foldersChanged = false; outboxChanged = false
        return c
    }

    /// A write failed: these changes go out again with the next ones.
    public func retry(_ c: StoreChanges) {
        changedIDs.formUnion(c.upsertIDs.filter { !removedIDs.contains($0) })
        removedIDs.formUnion(c.removed.filter { !changedIDs.contains($0) })
        if c.sync != nil { syncChanged = true }
        if c.folders != nil { foldersChanged = true }
        if c.outbox != nil { outboxChanged = true }
    }

    /// Everything that is stored, to fill a new database.
    public func storedState() -> StoreChanges {
        StoreChanges(upserts: messages.filter { isStored($0.accountID) }, sync: syncStates(),
                     folders: folders.filter { isStored($0.key) }, outbox: outbox)
    }

    private func syncStates() -> [SyncState] {
        Set(syncTokens.keys).union(complete).compactMap { k in
            guard let account = UUID(uuidString: String(k.prefix(36))), isStored(account) else { return nil }
            return SyncState(account: account, mailbox: MailboxKind(rawValue: String(k.dropFirst(37))),
                             token: syncTokens[k], complete: complete.contains(k))
        }
    }

    /// Launch, step 1: sync positions, folders and waiting changes. Messages follow with the next calls.
    public func restore(_ meta: StoredMeta) {
        let mine = Set(accounts.map(\.id))
        for s in meta.sync where mine.contains(s.account) {
            if let t = s.token { syncTokens[key(s.account, s.mailbox)] = t }
            if s.complete { complete.insert(key(s.account, s.mailbox)) }
            serverAccounts.insert(s.account)
        }
        for (a, f) in meta.folders where mine.contains(a) && folders[a] == nil {
            folders[a] = f
            serverAccounts.insert(a)
        }
        outbox += meta.outbox.filter { mine.contains($0.account) }
        loadedBoxes = []
        // What was just read from disk doesn't need writing back.
        syncChanged = false; foldersChanged = false; outboxChanged = false
    }

    /// Launch, step 2: the mail of some mailboxes (the Inbox first), shown while the rest loads.
    public func restore(_ msgs: [Message], boxes: [MailboxKey]) {
        let known = Set(messages.map(\.id))
        messages += msgs.filter { !known.contains($0.id) }
        for b in boxes { loadedBoxes?.insert(key(b.account, b.mailbox)) }
    }

    /// Launch, step 3: everything else. A message changed meanwhile keeps its version in memory.
    /// Then waiting changes go to the server and the history sync may start.
    public func finishLoading(_ rest: [Message]) {
        let known = Set(messages.map(\.id))
        messages += rest.filter { !known.contains($0.id) }
        loadedBoxes = nil
        scheduleFlush()
        if !backends.isEmpty { startHistory() }
    }

    /// True while launch is still loading stored mail.
    public var isLoading: Bool { loadedBoxes != nil }

    func isLoaded(_ account: UUID, _ box: MailboxKind) -> Bool { loadedBoxes?.contains(key(account, box)) ?? true }

    // MARK: Disk cache

    /// Server mail, sync positions and unsent changes of every server account. Sample data isn't cached.
    public func cache() -> MailCache {
        var out: [UUID: MailCache.AccountState] = [:]
        for acct in serverAccounts {
            let boxes = MailboxKind.allCases + (folders[acct] ?? []).map(\.box)
            var tokens: [MailboxKind: String] = [:]
            for box in boxes { tokens[box] = syncTokens[key(acct, box)] }
            out[acct] = MailCache.AccountState(messages: messages.filter { $0.accountID == acct && $0.remoteID != nil },
                                               syncTokens: tokens, outbox: outbox.filter { $0.account == acct },
                                               complete: boxes.filter { isComplete(acct, $0) }, folders: folders[acct])
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
            for box in state.complete ?? [] { complete.insert(key(acct, box)) }
            if let f = state.folders, folders[acct] == nil { folders[acct] = f }
            serverAccounts.insert(acct)
        }
        scheduleFlush()
    }

    // MARK: Write-back

    /// Exchange gives moved items new IDs. Updates the messages and the changes still queued.
    public func renameRemote(_ map: [String: String], account: UUID) {
        for i in messages.indices where messages[i].accountID == account {
            if let rid = messages[i].remoteID, let new = map[rid] { messages[i].remoteID = new; changedIDs.insert(messages[i].id) }
        }
        for i in outbox.indices where outbox[i].account == account { outbox[i].change = outbox[i].change.renamed(map) }
    }

    /// The server refused a change: undo it locally. A message that couldn't be sent is kept in Drafts.
    public func failed(_ p: PendingChange, _ error: String) {
        outbox.removeAll { $0.id == p.id }
        switch p.change {
        case let .send(d), let .saveDraft(d):
            let acct = account(d.accountID)
            let m = Message(accountID: d.accountID, mailbox: .drafts,
                            from: Contact(name: acct?.name ?? "", email: acct?.address ?? ""),
                            to: Contact.parseList(d.to), cc: Contact.parseList(d.cc),
                            subject: d.subject.isEmpty ? "(No Subject)" : d.subject,
                            body: d.text, date: .now, isRead: true, attachments: d.attachments.map(\.attachment))
            add(m)
            if !d.attachments.isEmpty { setAttachmentData(d.attachments.map(\.data), for: m.id) }
            status = "Couldn't send “\(d.subject)”: \(error). It's in Drafts on this Mac."
        default:
            // Only what this change set, and only while it still holds: later changes (still queued or sent)
            // stay, and a message erased since isn't brought back. Only a refused erase re-adds the message.
            for old in p.previous {
                guard let i = messages.firstIndex(where: { $0.id == old.id }) else {
                    if case .delete = p.change {
                        removedIDs.remove(old.id); changedIDs.insert(old.id)
                        messages.append(old)
                    }
                    continue
                }
                changedIDs.insert(old.id)
                switch p.change {
                case let .setRead(_, v): if messages[i].isRead == v { messages[i].isRead = old.isRead }
                case let .setFlagged(_, v): if (messages[i].flag != nil) == v { messages[i].flag = old.flag }
                case let .move(_, box): if messages[i].mailbox == box { messages[i].mailbox = old.mailbox }
                case .respond, .reply, .removeFromCalendar:
                    let holds = switch p.change {
                    case let .respond(_, r): messages[i].invite?.response == r && messages[i].invite?.reply == nil
                    case let .reply(_, r): messages[i].invite?.reply == r
                    default: messages[i].invite?.response == nil
                    }
                    guard holds else { continue }
                    if messages[i].mailbox == .trash { messages[i].mailbox = old.mailbox }
                    messages[i].invite = old.invite
                case .delete, .send, .saveDraft: break
                }
            }
            status = "Exchange refused a change: \(error)"
        }
    }

    private func scheduleFlush() {
        // Not while loading: the server renames moved messages, and those not in memory yet would keep old IDs.
        guard flushTask == nil, loadedBoxes == nil, outbox.contains(where: canSend) else { return }
        flushTask = Task {
            await drain()
            flushTask = nil
        }
    }

    /// Writes queued changes in order. When offline, changes stay queued for the next refresh;
    /// a send is never retried, because a timed-out send may have gone out.
    private func drain() async {
        while let p = outbox.first(where: canSend), let backend = backends[p.account] {
            do {
                try await perform(p, backend)
                outbox.removeAll { $0.id == p.id }
            } catch where pauseIfSignInFailed(error, account: p.account) {
                continue
            } catch let e as URLError {
                // A send or an answer that timed out may have gone out; never repeat it.
                if case .send = p.change { failed(p, e.localizedDescription); continue }
                if case .respond = p.change { failed(p, e.localizedDescription); continue }
                if case .reply = p.change { failed(p, e.localizedDescription); continue }
                status = "Offline – changes will be sent to Exchange later"
                return
            } catch {
                failed(p, error.localizedDescription)
            }
        }
    }

    private func canSend(_ p: PendingChange) -> Bool { backends[p.account] != nil && !paused.contains(p.account) }

    /// Stops all requests for an account whose sign-in failed. Returns false for any other error.
    func pauseIfSignInFailed(_ error: Error, account acct: UUID) -> Bool {
        guard error is AuthenticationError else { return false }
        paused.insert(acct)
        status = "Sign-in to “\(account(acct)?.name ?? "")” failed. Update the password in the Keychain "
            + "(MailReplica-EWS), then relaunch. Nothing is sent until then."
        return true
    }

    public func isPaused(_ acct: UUID) -> Bool { paused.contains(acct) }

    private func perform(_ p: PendingChange, _ b: any MailBackend) async throws {
        switch p.change {
        case let .setRead(ids, v): try await b.setRead(ids, v)
        case let .setFlagged(ids, v): try await b.setFlagged(ids, v)
        case let .move(ids, box):
            // Changes are written before refresh reads the folder list (e.g. a drop right after launch).
            if remoteFolders[p.account] == nil { setRemoteFolders(try await b.folders(), account: p.account) }
            guard let folder = remoteFolders[p.account]?.first(where: { $0.role == box }) else {
                throw MailError("There is no \(name(of: box, in: p.account)) folder on the server")
            }
            renameRemote(try await b.move(ids, to: folder), account: p.account)
        case let .delete(ids): try await b.delete(ids)
        case let .send(d): try await b.send(d)
        case let .saveDraft(d): try await b.saveDraft(d)
        case let .respond(id, r): try await b.respond(id, InviteReply(response: r))
        case let .reply(id, r):
            try await b.respond(id, r)
            // Without a sent answer Exchange may leave the invite in the Inbox; move it like the others.
            // If the server already moved it, that fails harmlessly.
            if !r.send, let trash = remoteFolders[p.account]?.first(where: { $0.role == .trash }),
               let map = try? await b.move([id], to: trash) {
                renameRemote(map, account: p.account)
            }
        case let .removeFromCalendar(id):
            try await b.removeFromCalendar(id)
            // Like an unsent answer: if Exchange leaves the cancellation in the Inbox, move it; if not, this fails harmlessly.
            if let trash = remoteFolders[p.account]?.first(where: { $0.role == .trash }),
               let map = try? await b.move([id], to: trash) {
                renameRemote(map, account: p.account)
            }
        }
    }

    public func setBody(_ b: MessageBody, for id: Message.ID) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        changedIDs.insert(id)
        messages[i].body = b.text
        messages[i].attachments = b.attachments
        messages[i].hasAttachments = !b.attachments.isEmpty
        messages[i].bodyLoaded = true
        messages[i].html = b.html
        messages[i].htmlChecked = true
        if let f = b.from { messages[i].from = f }
        if let to = b.to { messages[i].to = to }
        if let cc = b.cc { messages[i].cc = cc }
        if let invite = b.invite { messages[i].invite = invite; messages[i].isInvite = true }
    }

    // MARK: Invites

    /// The calendar day of each invite on screen, keyed by message. Not cached: the calendar changes.
    public private(set) var dayEvents: [Message.ID: [CalendarEvent]] = [:]

    /// Fetches the local calendar day around an invite, for its day column and conflict note.
    public func loadDay(for id: Message.ID) async {
        guard let m = message(id), let invite = m.invite, let backend = backends[m.accountID], !paused.contains(m.accountID)
        else { return }
        let from = Calendar.current.startOfDay(for: invite.start)
        let to = Calendar.current.date(byAdding: .day, value: 1, to: from) ?? from.addingTimeInterval(86400)
        do { dayEvents[id] = try await backend.events(from: from, to: to) } catch {
            if !pauseIfSignInFailed(error, account: m.accountID) { status = "Couldn't load the calendar: \(error.localizedDescription)" }
        }
    }

    /// Answers an invite: shown at once, then sent. Exchange tells the organizer and updates the calendar.
    public func respond(_ r: InviteResponse, to id: Message.ID) {
        answer(id, response: r, reply: nil) { .respond($0, r) }
    }

    /// Answers an invite with options (comment, not sending, a proposed time).
    public func respond(_ reply: InviteReply, to id: Message.ID) {
        if let s = reply.proposedStart, let e = reply.proposedEnd, e <= s {
            status = "The proposed meeting must end after it starts."
            return
        }
        answer(id, response: reply.response, reply: reply) { .reply($0, reply) }
    }

    /// Takes a cancelled meeting off the calendar; the cancellation goes to Trash, as after an answer.
    public func removeFromCalendar(_ id: Message.ID) {
        answer(id, response: nil, reply: nil) { .removeFromCalendar($0) }
    }

    /// Records the answer and moves the invite to Trash at once, as Exchange does after an answer
    /// (no move request: the server moves it itself). The next message is selected, as after Delete.
    private func answer(_ id: Message.ID, response: InviteResponse?, reply: InviteReply?,
                        _ change: (String) -> ServerChange) {
        guard let old = message(id), old.invite != nil else { return }
        let apply: (Set<Message.ID>) -> Void = { _ in
            guard let i = self.messages.firstIndex(where: { $0.id == id }) else { return }
            self.changedIDs.insert(id)
            self.messages[i].invite?.response = response
            self.messages[i].invite?.reply = reply
            self.messages[i].mailbox = .trash
        }
        if selection == [id] { actOnSelection(apply) } else { apply([id]) }
        guard let rid = old.remoteID else { return }
        outbox.append(PendingChange(account: old.accountID, change: change(rid), previous: [old]))
        scheduleFlush()
    }

    // MARK: Inline images

    /// The `cid:` images of the messages on screen. Never cached: they can be megabytes.
    private var inline: [Message.ID: [String: InlineImage]] = [:]

    public func inlineImages(for id: Message.ID) -> [String: InlineImage] { inline[id] ?? [:] }

    /// For sample data and tests; replaces the images of any other message.
    public func setInlineImages(_ images: [String: InlineImage], for id: Message.ID) { inline = [id: images] }

    /// Keeps the images of the other messages of the conversation on screen, drops the rest.
    func addInlineImages(_ images: [String: InlineImage], for id: Message.ID) {
        let shown = Set(selectedMessage.map { conversation(of: $0.id).map(\.id) } ?? [])
        inline = inline.filter { shown.contains($0.key) }
        inline[id] = images
    }

    /// Fetches the images the shown HTML body refers to with `cid:`. A failure leaves the body as it is.
    public func loadInlineImages(for id: Message.ID) async {
        guard inline[id] == nil, let m = message(id), let html = m.html, let rid = m.remoteID,
              let backend = backends[m.accountID], !paused.contains(m.accountID) else { return }
        let ids = HTMLPage.contentIDs(in: html)
        guard !ids.isEmpty else { return }
        do { addInlineImages(try await backend.inlineImages(remoteID: rid, contentIDs: ids), for: id) } catch {
            if !pauseIfSignInFailed(error, account: m.accountID) { status = "Couldn't load images: \(error.localizedDescription)" }
        }
    }

    // MARK: Attachments

    /// Where opened attachments are written, a folder per message, like Mail's "Mail Downloads".
    @ObservationIgnored public var downloadsFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("Mail Downloads")
    /// The content of attachments of messages without a server (sample data), by position.
    @ObservationIgnored private var localAttachments: [Message.ID: [Data]] = [:]
    /// What Quick Look shows: every attachment of a message, and the one in front.
    public var previewItems: [URL] = []
    public var previewItem: URL?

    /// For sample data and tests: the content of a local message's attachments, in order.
    public func setAttachmentData(_ data: [Data], for id: Message.ID) { localAttachments[id] = data }

    /// The attachment as a file, fetched from the server the first time. nil (and a status) if that fails.
    public func attachmentFile(_ index: Int, of id: Message.ID) async -> URL? {
        guard let m = message(id), m.attachments.indices.contains(index) else { return nil }
        let a = m.attachments[index]
        // A folder per position: two attachments may have the same name.
        let url = downloadsFolder.appendingPathComponent(id.uuidString).appendingPathComponent("\(index)")
            .appendingPathComponent(a.fileName)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            let data: Data
            if let local = localAttachments[id], local.indices.contains(index) {
                data = local[index]
            } else if let rid = m.remoteID, let backend = backends[m.accountID], !paused.contains(m.accountID) {
                data = try await backend.attachment(remoteID: rid, index: index)
            } else {
                status = "Couldn't open “\(a.name)”: its content isn't available."
                return nil
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            // As Mail does: Gatekeeper then asks before an attached app or script runs.
            try (url as NSURL).setResourceValue([kLSQuarantineTypeKey as String: kLSQuarantineTypeEmailAttachment as String,
                                                 kLSQuarantineAgentNameKey as String: "Mail Replica"],
                                                forKey: .quarantinePropertiesKey)
            return url
        } catch {
            if !pauseIfSignInFailed(error, account: m.accountID) {
                status = "Couldn't open “\(a.name)”: \(error.localizedDescription)"
            }
            return nil
        }
    }

    /// Copies the attachment into `folder` without replacing anything there ("name 2.pdf", as in the Finder).
    public func saveAttachment(_ index: Int, of id: Message.ID, to folder: URL) async -> URL? {
        guard let file = await attachmentFile(index, of: id) else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = Self.freeURL(for: file.lastPathComponent, in: folder)
            try FileManager.default.copyItem(at: file, to: target)
            return target
        } catch {
            status = "Couldn't save “\(file.lastPathComponent)”: \(error.localizedDescription)"
            return nil
        }
    }

    /// File ▸ Save Attachments…: every attachment of the message into one folder.
    public func saveAllAttachments(of id: Message.ID, to folder: URL) async -> [URL] {
        var saved: [URL] = []
        for i in message(id)?.attachments.indices ?? 0..<0 {
            if let url = await saveAttachment(i, of: id, to: folder) { saved.append(url) }
        }
        return saved
    }

    /// Quick Look over all of the message's attachments, starting at `index`.
    public func quickLookAttachments(of id: Message.ID, at index: Int = 0) async {
        var files: [URL] = [], front: URL?
        for i in message(id)?.attachments.indices ?? 0..<0 {
            guard let url = await attachmentFile(i, of: id) else { continue }
            files.append(url)
            if i == index { front = url }
        }
        previewItems = files
        previewItem = front ?? files.first
    }

    static func freeURL(for name: String, in folder: URL) -> URL {
        let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
        var url = folder.appendingPathComponent(name), n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(Attachment.fileName(base, ending: ext.isEmpty ? " \(n)" : " \(n).\(ext)"))
            n += 1
        }
        return url
    }

    /// For sample data and tests: a day of made-up calendar entries next to an invite.
    public func setDayEvents(_ events: [CalendarEvent], for id: Message.ID) { dayEvents[id] = events }

    /// Fetches the body of a server message the first time it is shown.
    public func loadBody(_ id: Message.ID) async {
        guard let m = message(id), m.needsBody, let rid = m.remoteID, let backend = backends[m.accountID],
              !paused.contains(m.accountID) else { return }
        do { setBody(try await backend.body(remoteID: rid), for: id) } catch {
            if !pauseIfSignInFailed(error, account: m.accountID) { status = "Couldn't load message: \(error.localizedDescription)" }
        }
    }

    /// Newest messages fetched for a folder whose full sync hasn't finished: about one screenful.
    public static let firstScreen = 50

    /// The quick check: what the user looks at, first and fast. Only the Inbox and the mailbox on screen.
    /// A fully synced folder asks for changes (one small request); one still syncing gets its newest
    /// messages. Never waits for the history sync, which it starts afterwards.
    public func refresh(history: Bool = true) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // Write first, so the check doesn't briefly bring back the old state.
        scheduleFlush()
        await flushTask?.value
        for (acct, backend) in backends where !paused.contains(acct) {
            do {
                if remoteFolders[acct] == nil { setRemoteFolders(try await backend.folders(), account: acct) }
                for role in quickCheckRoles(acct) {
                    guard let folder = remoteFolders[acct]?.first(where: { $0.role == role }) else { continue }
                    if isComplete(acct, role) {
                        var more = true
                        while more {
                            let r = try await backend.sync(folder, token: syncToken(acct, role))
                            apply(r, account: acct, mailbox: role)
                            more = r.more
                        }
                    } else {
                        merge(try await backend.newest(in: folder, limit: Self.firstScreen), account: acct, mailbox: role)
                    }
                }
                status = historyError
            } catch where pauseIfSignInFailed(error, account: acct) {
            } catch {
                status = "\(account(acct)?.name ?? "Account"): \(error.localizedDescription)"
            }
        }
        if history { startHistory() }
    }

    /// Roles the quick check covers: the Inbox, plus the mailbox on screen if it belongs to this account.
    func quickCheckRoles(_ acct: UUID) -> [MailboxKind] {
        var roles: [MailboxKind] = [.inbox]
        if case let .account(a, box) = selectedMailbox, a == acct, box != .inbox { roles.append(box) }
        // While launch is loading, a mailbox not yet in memory isn't checked: merging would duplicate its mail.
        return roles.filter { isLoaded(acct, $0) }
    }

    /// History order: small, often-read folders first, the user's own folders after them; Sent (often the largest) last.
    static let historyPriority: [MailboxKind] = [.inbox, .drafts, .archive, .junk, .trash, .sent]

    static func prioritized(_ roles: [MailboxKind]) -> [MailboxKind] {
        historyPriority.dropLast().filter(roles.contains) + roles.filter { !$0.isStandard } + (roles.contains(.sent) ? [.sent] : [])
    }

    /// The mailbox on screen jumps the queue.
    func historyOrder(_ acct: UUID, _ roles: [MailboxKind]) -> [MailboxKind] {
        var order = Self.prioritized(roles)
        if case let .account(a, box) = selectedMailbox, a == acct, let i = order.firstIndex(of: box) {
            order.insert(order.remove(at: i), at: 0)
        }
        return order
    }

    /// Share of the account's messages that are here: complete folders in full, others by what has arrived.
    func historyFraction(_ acct: UUID, _ folders: [RemoteFolder]) -> Double {
        let total = folders.reduce(0) { $0 + $1.totalCount }
        guard total > 0 else { return 0 }
        let done = folders.reduce(0) { sum, f in
            sum + (isComplete(acct, f.role) ? f.totalCount : min(f.totalCount, count(.account(acct, f.role))))
        }
        return Double(done) / Double(total)
    }

    public func startHistory() {
        guard historyTask == nil, loadedBoxes == nil else { return }
        historyTask = Task {
            await syncHistory()
            historyTask = nil
        }
    }

    /// How long history pages are collected before they are shown. Applied together in one go, they cost the
    /// window one update instead of one per page, which kept a big mailbox's window from responding.
    static let historyBatch: Duration = .milliseconds(1500)

    /// Fetches every folder's full contents in the background: first the newest messages of each folder,
    /// then one page at a time, shown in batches (`historyBatch`). The next folder is picked after every batch,
    /// so switching mailboxes takes effect within moments. A failing folder doesn't stop the others; offline,
    /// the history waits for the next check.
    public func syncHistory() async {
        defer { progress = nil }
        for (acct, backend) in backends where !paused.contains(acct) {
            var fetched: [(MailboxKind, [Message])] = [], since = ContinuousClock.now
            func show() {
                merge(fetched, account: acct)
                for (role, _) in fetched { newestLoaded.insert(key(acct, role)) }
                fetched = []; since = .now
            }
            for role in historyOrder(acct, (remoteFolders[acct] ?? []).map(\.role))
            where !isComplete(acct, role) && !historyFailed.contains(key(acct, role)) && !newestLoaded.contains(key(acct, role)) {
                guard let folder = remoteFolders[acct]?.first(where: { $0.role == role }) else { continue }
                showHistoryProgress(acct)
                do {
                    fetched.append((role, try await backend.newest(in: folder, limit: 200)))
                } catch {
                    _ = pauseIfSignInFailed(error, account: acct)
                    break
                }
                if since.duration(to: .now) > Self.historyBatch { show() }
            }
            show()
        }
        while let (acct, backend, folder) = nextHistoryFolder() {
            showHistoryProgress(acct)
            var pages: [SyncResult] = []
            // Whatever arrived is shown, also when a page fails; in one merge.
            defer { apply(pages, account: acct, mailbox: folder.role) }
            do {
                var token = syncToken(acct, folder.role)
                let start = ContinuousClock.now
                repeat {
                    let r = try await backend.sync(folder, token: token)
                    pages.append(r)
                    token = r.token
                } while pages.last?.more == true && start.duration(to: .now) < Self.historyBatch
            } catch where pauseIfSignInFailed(error, account: acct) {
            } catch is URLError {
                return
            } catch {
                historyFailed.insert(key(acct, folder.role))
                historyError = "\(name(of: folder.role, in: acct)): \(error.localizedDescription)"
                status = historyError
            }
        }
        progress = nil
        // History is done: bring the complete folders that aren't on screen up to date (one small request each).
        for (acct, backend) in backends where !paused.contains(acct) {
            for role in backgroundDeltaRoles(acct, (remoteFolders[acct] ?? []).map(\.role)) {
                guard let folder = remoteFolders[acct]?.first(where: { $0.role == role }) else { continue }
                do {
                    var more = true
                    while more {
                        let r = try await backend.sync(folder, token: syncToken(acct, role))
                        apply(r, account: acct, mailbox: role)
                        more = r.more
                    }
                } catch {
                    if pauseIfSignInFailed(error, account: acct) || error is URLError { break }
                }
            }
        }
    }

    /// Complete folders the quick check doesn't cover.
    func backgroundDeltaRoles(_ acct: UUID, _ roles: [MailboxKind]) -> [MailboxKind] {
        let quick = quickCheckRoles(acct)
        return Self.prioritized(roles).filter { isComplete(acct, $0) && !quick.contains($0) }
    }

    private func nextHistoryFolder() -> (UUID, any MailBackend, RemoteFolder)? {
        for acct in accounts.map(\.id) {
            guard let backend = backends[acct], let folders = remoteFolders[acct], !paused.contains(acct) else { continue }
            for role in historyOrder(acct, folders.map(\.role))
            where !isComplete(acct, role) && !historyFailed.contains(key(acct, role)) {
                if let f = folders.first(where: { $0.role == role }) { return (acct, backend, f) }
            }
        }
        return nil
    }

    private func showHistoryProgress(_ acct: UUID) {
        progress = SyncProgress(text: "Synchronizing “\(account(acct)?.name ?? "")”",
                                fraction: historyFraction(acct, remoteFolders[acct] ?? []))
    }

    // MARK: Compose

    public func draft(_ kind: ReplyKind, to id: Message.ID, includeAttachments: IncludeAttachments = .never) -> Draft {
        guard let m = message(id) else { return Draft(accountID: accounts[0].id) }
        let me = account(m.accountID)?.address
        let prefix = kind == .forward ? "Fwd: " : "Re: "
        let subject = m.subject.hasPrefix(prefix) ? m.subject : prefix + m.subject
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        // Any line ending: Exchange bodies use CRLF, which is one Character in Swift, not "\n".
        let quoted = m.body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { "> \($0)" }
            .joined(separator: "\n")
        let header = kind == .forward
            ? "\n\nBegin forwarded message:\n\nFrom: \(m.from.name) <\(m.from.email)>\nSubject: \(m.subject)\nDate: \(df.string(from: m.date))\n\n"
            : "\n\nOn \(df.string(from: m.date)), \(m.from.name) <\(m.from.email)> wrote:\n\n"
        var to = ""
        switch kind {
        case .reply: to = m.from.email
        case .replyAll:
            to = ([m.from] + m.to + m.cc).map(\.email).filter { $0.lowercased() != me?.lowercased() }.joined(separator: ", ")
        case .forward: break
        }
        var d = Draft(accountID: m.accountID, to: to, subject: subject, body: header + quoted)
        if m.hasAttachments || !m.attachments.isEmpty {
            d.original = id
            // Forward always takes them along; a reply only with Include Attachments With Replies ▸ Always.
            if kind == .forward || includeAttachments == .always { d.loadingOriginal = id }
        }
        return d
    }

    /// Include Attachments With Replies ▸ When Adding Recipients: the reply now goes to someone who
    /// wasn't on the original message.
    public func addsNewRecipient(_ d: Draft) -> Bool {
        guard let id = d.original, let m = message(id) else { return false }
        var known = Set(([m.from] + m.to + m.cc).map { $0.email.lowercased() })
        if let me = account(m.accountID)?.address { known.insert(me.lowercased()) }
        return (Contact.parseList(d.to) + Contact.parseList(d.cc))
            .contains { $0.email.contains("@") && !known.contains($0.email.lowercased()) }
    }

    /// Adds files to a draft. A folder (or package) goes as a zip archive of it, made the way the Finder
    /// compresses. Unreadable items are left out, with a note in `status`.
    public func attach(_ urls: [URL], to draft: inout Draft) { draft.attachments += files(urls) }

    /// The files to attach: a folder as a zip of it. Reports the ones that can't be read.
    public func files(_ urls: [URL]) -> [DraftAttachment] {
        var files: [DraftAttachment] = [], skipped: [String] = []
        for url in urls {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isFolder {
                guard let zip = Self.zipped(url) else { skipped.append(url.lastPathComponent); continue }
                files.append(DraftAttachment(name: url.lastPathComponent + ".zip", contentType: "application/zip", data: zip))
                continue
            }
            guard let data = try? Data(contentsOf: url) else { skipped.append(url.lastPathComponent); continue }
            files.append(DraftAttachment(name: url.lastPathComponent,
                                         contentType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType, data: data))
        }
        if !skipped.isEmpty { status = "Couldn't attach \(skipped.map { "“\($0)”" }.joined(separator: ", "))." }
        return files
    }

    /// A zip of the folder, from the system's "for uploading" read (it zips folders on the fly).
    static func zipped(_ folder: URL) -> Data? {
        var data: Data?, error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &error) { zipURL in
            data = try? Data(contentsOf: zipURL)
        }
        return data
    }

    /// Adds the original message's attachments (a forward, or a reply that includes them), fetched from the
    /// server if needed, as in Mail.
    public func includeOriginalAttachments(in draft: inout Draft) async {
        guard let id = draft.loadingOriginal, let m = message(id) else { draft.loadingOriginal = nil; return }
        if m.needsBody { await loadBody(id) }
        for (i, a) in (message(id)?.attachments ?? []).enumerated() {
            guard let url = await attachmentFile(i, of: id), let data = try? Data(contentsOf: url) else { continue }
            draft.attachments.append(DraftAttachment(
                name: a.name, contentType: a.contentType ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType,
                data: data, fromOriginal: true))
        }
        draft.loadingOriginal = nil
    }

    /// An invite answer "with comments" as a message, like Outlook's: to the organizer, with the subject
    /// Exchange gives it. Proposing starts from the meeting's own time.
    public func answerDraft(_ r: InviteResponse, to id: Message.ID, proposing: Bool = false) -> Draft {
        guard let m = message(id), let invite = m.invite else { return Draft(accountID: accounts[0].id) }
        let answered = switch r {
        case .accept: "Accepted"
        case .tentative: "Tentative"
        case .decline: "Declined"
        }
        let prefix = proposing ? "New Time Proposed" : answered
        let to = invite.organizer.map { $0.email.isEmpty ? $0.name : "\($0.name) <\($0.email)>" } ?? ""
        return Draft(accountID: m.accountID, to: to, subject: "\(prefix): \(m.subject)",
                     inviteAnswer: InviteAnswer(messageID: id, response: r, proposedStart: proposing ? invite.start : nil,
                                                proposedEnd: proposing ? invite.end : nil))
    }

    // MARK: Message size

    /// The largest message each account may send, as its server reports it.
    public private(set) var maxMessageSizes: [UUID: Int] = [:]

    public func setMaxMessageSize(_ size: Int, for account: UUID) { maxMessageSizes[account] = size }

    /// Asks the server once per session; without an answer there is no limit to show.
    public func loadMaxMessageSize(for account: UUID) async {
        guard maxMessageSizes[account] == nil, let backend = backends[account], !paused.contains(account),
              let address = self.account(account)?.address,
              let size = try? await backend.maxMessageSize(from: address) else { return }
        maxMessageSizes[account] = size
    }

    public func maximumSize(for d: Draft) -> Int? { maxMessageSizes[d.accountID] }

    /// Over the account's limit: Send asks first, as Mail does before Mail Drop.
    public func isOverSizeLimit(_ d: Draft) -> Bool { maximumSize(for: d).map { d.estimatedSize > $0 } ?? false }

    /// Mail's AttachmentsPendingMessage: a forward isn't sent or saved before its original files are in.
    private func attachmentsPending(_ d: Draft) -> Bool {
        guard d.loadingOriginal != nil else { return false }
        status = "This message contains attachments that are still being loaded."
        return true
    }

    public func send(_ d: Draft) {
        if attachmentsPending(d) { return }
        if let a = d.inviteAnswer {
            let text = d.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return respond(InviteReply(response: a.response, comment: text.isEmpty ? nil : text,
                                       proposedStart: a.proposedStart, proposedEnd: a.proposedEnd), to: a.messageID)
        }
        let acct = account(d.accountID) ?? accounts[0]
        if serverAccounts.contains(acct.id) {
            outbox.append(PendingChange(account: acct.id, change: .send(d), previous: []))
            return scheduleFlush()
        }
        let m = Message(accountID: acct.id, mailbox: .sent, from: Contact(name: acct.name, email: acct.address),
                        to: Contact.parseList(d.to), cc: Contact.parseList(d.cc), subject: d.subject,
                        body: d.text, date: .now, isRead: true, attachments: d.attachments.map(\.attachment))
        add(m)
        if !d.attachments.isEmpty { setAttachmentData(d.attachments.map(\.data), for: m.id) }
    }

    public func saveDraft(_ d: Draft) {
        if attachmentsPending(d) { return }
        let acct = account(d.accountID) ?? accounts[0]
        if serverAccounts.contains(acct.id) {
            outbox.append(PendingChange(account: acct.id, change: .saveDraft(d), previous: []))
            return scheduleFlush()
        }
        let m = Message(accountID: acct.id, mailbox: .drafts, from: Contact(name: acct.name, email: acct.address),
                        to: Contact.parseList(d.to), subject: d.subject.isEmpty ? "(No Subject)" : d.subject,
                        body: d.text, date: .now, isRead: true, attachments: d.attachments.map(\.attachment))
        add(m)
        if !d.attachments.isEmpty { setAttachmentData(d.attachments.map(\.data), for: m.id) }
    }
}

struct MailError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}
