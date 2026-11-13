import CoreServices
import Foundation
import UniformTypeIdentifiers
import Observation

@MainActor
@Observable
public final class MailStore {
    public var accounts: [Account]
    public private(set) var messages: [Message] { didSet { revision &+= 1 } }
    /// Bumped on every change to `messages` (and `folders`); the caches below are valid for one revision.
    @ObservationIgnored private var revision = 0
    /// Changes when the messages (or folders) change, to skip saving an unchanged cache.
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
        didSet {
            // The messages of a selected conversation row count as selected too.
            guard !openedUnread.isEmpty else { return }
            let kept = withConversations(selection)
            if !openedUnread.isSubset(of: kept) { openedUnread.formIntersection(kept) }
        }
    }
    /// The list shows each conversation as one row (Settings ▸ Viewing ▸ Show messages as conversations).
    public var groupsConversations = false
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
    /// The index's answer for a query in a scope (the accounts searched); shown as it is until the next answer
    /// arrives, also after another account's mailbox was selected (BUG-080).
    public private(set) var searchHits: (query: String, scope: Set<UUID>?, ids: Set<Message.ID>)? { didSet { hitsGeneration &+= 1 } }
    @ObservationIgnored private var hitsGeneration = 0
    /// A query the index couldn't answer: memory is scanned for it instead.
    private var fallbackQuery: String?
    /// The query of the memory scan last shown (its results stay while the index's next answer is on its way).
    @ObservationIgnored private var memoryQuery: String?
    @ObservationIgnored private(set) var searchTask: Task<Void, Never>?
    /// Wait after a keystroke before asking the index.
    @ObservationIgnored var searchDebounce: Duration = .milliseconds(150)
    /// Last sync problem or notice, shown under the window title.
    public var status: String?
    public private(set) var isRefreshing = false
    /// Shown at the bottom of the sidebar while checking for mail, like Mail's activity view.
    public var progress: SyncProgress?

    /// Each account's folders of its own, as a tree (see `children(of:account:)`).
    public private(set) var folders: [UUID: [Folder]] = [:] {
        didSet {
            foldersChanged = true
            folderTree = [:]
            if folders != oldValue { foldersInTrash = Self.foldersInTrash(folders); revision &+= 1 }
        }
    }
    /// Each account's folders inside Trash, at any depth (Exchange keeps deleted folders there): their mail
    /// counts as deleted, like Trash's own.
    @ObservationIgnored private var foldersInTrash: [UUID: Set<MailboxKind>] = [:]

    private var backends: [UUID: any MailBackend] = [:]
    private var remoteFolders: [UUID: [RemoteFolder]] = [:]
    private var syncTokens: [String: String] = [:] { didSet { syncChanged = true } }
    /// Folders ("account/mailbox") whose full sync has finished; checks then only fetch changes.
    private var complete: Set<String> = [] { didSet { syncChanged = true } }
    /// Folders syncing from the start (token nil): the server IDs they held when that began that no page has
    /// listed since. A from-scratch sync lists everything there and reports no deletions, so once it is complete
    /// these are gone from the server (`prune`). In memory only: a pass interrupted by quitting removes nothing.
    @ObservationIgnored private var unlisted: [String: (done: Bool, ids: Set<String>)] = [:]
    private var historyTask: Task<Void, Never>?
    /// Folders whose history sync failed this session; retried after a relaunch.
    private var historyFailed: Set<String> = []
    /// Folders whose rejected sync token was already dropped this session (`resetSync`).
    @ObservationIgnored private var tokensReset: Set<String> = []
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
    /// Messages kept only on this Mac whose file content is still to be written (`keepFiles`).
    @ObservationIgnored private var filesChanged = Set<Message.ID>()
    /// Mailboxes whose stored mail is in memory while launch is still loading; nil once everything is.
    @ObservationIgnored private var loadedBoxes: Set<String>?
    private var flushTask: Task<Void, Never>?
    /// Accounts whose server asked to wait (throttling): their changes aren't sent before then.
    @ObservationIgnored private var busyUntil: [UUID: Date] = [:]
    /// Notices about an account's connection (its failed check, offline, busy), by account. Only that account's next
    /// successful check clears them; other notices ("Couldn't send …", a refused change) stay until replaced.
    @ObservationIgnored private var connectionNotices: [UUID: String] = [:]
    /// Server deletions of messages whose move was still queued, by account. They are held, not applied, because the
    /// move itself makes the source folder report them; if the move then fails, the deletion was real and is applied.
    @ObservationIgnored private var deletedWhileMoving: [UUID: Set<String>] = [:]
    /// Counts the changes written to the server. A server answer notes it when it is requested (`requestStamp`).
    @ObservationIgnored private(set) var requestStamp = 0
    /// When each property of a server message was last written (`requestStamp` after the write), by account and
    /// server ID. An answer requested before that doesn't undo it; one requested before an erase or a move (whose
    /// old ID is gone on the server) doesn't bring the old ID back. In memory only.
    @ObservationIgnored private var written: [UUID: [String: Written]] = [:]
    private struct Written { var read = 0, flag = 0, mailbox = 0 }
    /// Writes the changes to disk and returns once they are written; called before a send goes out, so its
    /// `inFlight` mark is saved first. Nil with sample data and in tests that don't save.
    @ObservationIgnored public var saveBeforeSending: (() async -> Void)?
    /// IDs per server request, so "Mark All as Read" on a big inbox doesn't send one huge request.
    public static let batchSize = 100

    public init(accounts: [Account], messages: [Message]) {
        self.accounts = accounts
        self.messages = messages
    }

    // MARK: Queries

    public func message(_ id: Message.ID) -> Message? { messages.first { $0.id == id } }

    public func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }

    /// Each account's folders by parent (sorted) and their names, made once per change of `folders`: the sidebar,
    /// the Move menu and the toolbar ask for them on every redraw.
    @ObservationIgnored private var folderTree: [UUID: (children: [MailboxKind?: [Folder]], names: [MailboxKind: String])] = [:]

    private func tree(_ account: UUID) -> (children: [MailboxKind?: [Folder]], names: [MailboxKind: String]) {
        let list = folders[account] ?? []  // read first: registers the dependency for SwiftUI even when the cache answers
        if let t = folderTree[account] { return t }
        var children: [MailboxKind?: [Folder]] = [:], names: [MailboxKind: String] = [:]
        for f in list {
            children[f.parent, default: []].append(f)
            if names[f.box] == nil { names[f.box] = f.name }
        }
        for k in children.keys { children[k]!.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
        folderTree[account] = (children, names)
        return (children, names)
    }

    /// The folders directly in `parent` (nil: at the top of the account), by name as Finder sorts.
    public func children(of parent: MailboxKind?, account: UUID) -> [Folder] {
        tree(account).children[parent] ?? []
    }

    /// The mailbox's name: the standard title, or the folder's own.
    public func name(of box: MailboxKind, in account: UUID) -> String {
        box.isStandard ? box.title : tree(account).names[box] ?? ""
    }

    /// Sets an account's folder tree (for local accounts; server accounts get theirs from the server).
    public func setFolders(_ f: [Folder], account: UUID) { folders[account] = f }

    /// The server's folder list: the user's own folders become the account's tree. A folder of the tree the list no
    /// longer has was removed on the server: its mail and sync position go, and its selection moves to the Inbox.
    func setRemoteFolders(_ remote: [RemoteFolder], account: UUID) {
        remoteFolders[account] = remote
        let gone = Set((folders[account] ?? []).map(\.box)).subtracting(remote.map(\.role))
        folders[account] = remote.filter { !$0.role.isStandard }.map { Folder(box: $0.role, name: $0.name, parent: $0.parent) }
        guard !gone.isEmpty else { return }
        for box in gone {
            let k = key(account, box)
            if syncTokens[k] != nil { syncTokens[k] = nil }
            if complete.contains(k) { complete.remove(k) }
            unlisted[k] = nil; newestLoaded.remove(k); historyFailed.remove(k); tokensReset.remove(k)
        }
        // While launch is loading, the folder's stored mail isn't in memory yet: `finishLoading` leaves it out.
        if loadedBoxes != nil { removedFolders[account, default: []].formUnion(gone) }
        let ids = Set(messages.lazy.filter { $0.accountID == account && gone.contains($0.mailbox) }.map(\.id))
        if !ids.isEmpty {
            messages.removeAll { ids.contains($0.id) }
            selection.subtract(ids)
            forget(ids)
        }
        if case let .account(a, box) = selectedMailbox, a == account, gone.contains(box) { selectedMailbox = .account(account, .inbox) }
    }

    /// Folders removed on the server while launch was still loading, by account.
    @ObservationIgnored private var removedFolders: [UUID: Set<MailboxKind>] = [:]

    /// Stored mail without the mail of folders removed on the server meanwhile; that mail is removed from disk.
    private func withoutRemovedFolders(_ msgs: [Message]) -> [Message] {
        guard !removedFolders.isEmpty else { return msgs }
        var kept: [Message] = [], gone = Set<Message.ID>()
        for m in msgs {
            if removedFolders[m.accountID]?.contains(m.mailbox) == true { gone.insert(m.id) } else { kept.append(m) }
        }
        forget(gone)
        return kept
    }

    nonisolated private static func foldersInTrash(_ folders: [UUID: [Folder]]) -> [UUID: Set<MailboxKind>] {
        folders.compactMapValues { list in
            var inTrash: Set<MailboxKind> = [.trash], grew = true
            while grew {
                grew = false
                for f in list where !inTrash.contains(f.box) {
                    if let p = f.parent, inTrash.contains(p) { inTrash.insert(f.box); grew = true }
                }
            }
            inTrash.remove(.trash)
            return inTrash.isEmpty ? nil : inTrash
        }
    }

    /// In Trash or in a folder inside it.
    nonisolated private static func isDeleted(_ m: Message, _ inTrash: [UUID: Set<MailboxKind>]) -> Bool {
        m.mailbox == .trash || inTrash[m.accountID]?.contains(m.mailbox) == true
    }

    private func isDeleted(_ m: Message) -> Bool { Self.isDeleted(m, foldersInTrash) }

    func contains(_ ref: MailboxRef, _ m: Message) -> Bool {
        switch ref {
        case .smart(.allInboxes): m.mailbox == .inbox
        case .smart(.vip): m.isVIP && m.mailbox == .inbox
        case .smart(.flagged): m.flag != nil && !isDeleted(m)
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
            if m.flag != nil && !isDeleted(m) {
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
        var mailbox: MailboxRef, query: String, filterUnread: Bool, hits: Int, openedUnread: Set<Message.ID>, grouped = false
    }

    /// The conversation rows of the list made for `key`: each row's messages in the list (newest first, the row's own
    /// first), and the row each of them is shown in. Only conversations with more than one message in the list.
    @ObservationIgnored private var threadCache: (revision: Int, key: ListKey, members: [Message.ID: [Message]],
                                                  rowOf: [Message.ID: Message.ID])?

    /// One row per conversation (by account, as All Inboxes spans several): its newest message in the list stands
    /// for it. A message without a conversation is a row of its own. One pass over the list, cached with it.
    private func grouping(_ list: [Message], _ key: ListKey) -> [Message] {
        struct Conversation: Hashable { let account: UUID; let id: String }
        var slot: [Conversation: Int] = [:], rows: [Message] = [], members: [Int: [Message]] = [:]
        for m in list {
            guard let c = m.conversationID else { rows.append(m); continue }
            let k = Conversation(account: m.accountID, id: c)
            if let i = slot[k] { members[i, default: [rows[i]]].append(m) } else { slot[k] = rows.count; rows.append(m) }
        }
        var byRow: [Message.ID: [Message]] = [:], rowOf: [Message.ID: Message.ID] = [:]
        for (i, ms) in members {
            byRow[rows[i].id] = ms
            for m in ms { rowOf[m.id] = rows[i].id }
        }
        threadCache = (revision, key, byRow, rowOf)
        return rows
    }

    /// The conversation rows of the list on screen.
    private var threads: (members: [Message.ID: [Message]], rowOf: [Message.ID: Message.ID]) {
        guard groupsConversations else { return ([:], [:]) }
        _ = visibleMessages
        guard let t = threadCache, t.revision == revision, t.key == listCache?.key else { return ([:], [:]) }
        return (t.members, t.rowOf)
    }

    /// What the row of a conversation shows: nil for a row that is a single message.
    public func conversationRow(_ id: Message.ID) -> ConversationRow? {
        threads.members[id].map(ConversationRow.init)
    }

    /// The messages these list rows stand for: a conversation row's messages in the list, with the row's own.
    /// Everything the list hands to an action goes through here, so it acts on the whole conversation, as in Mail.
    public func withConversations(_ ids: Set<Message.ID>) -> Set<Message.ID> {
        let t = threads
        guard !t.members.isEmpty else { return ids }
        var all = ids
        for id in ids { if let ms = t.members[t.rowOf[id] ?? id] { all.formUnion(ms.map(\.id)) } }
        return all
    }

    /// The selection as rows of the list: a selected message that a newer one of its conversation now stands for
    /// (a reply arrived) is shown as that row. Setting it selects the rows.
    public var listSelection: Set<Message.ID> {
        get {
            let rowOf = threads.rowOf
            return rowOf.isEmpty ? selection : Set(selection.map { rowOf[$0] ?? $0 })
        }
        set { selection = newValue }
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
        // Results that came from memory stay the same way until the index's first answer is in.
        let q = useIndex ? hits?.query ?? memoryQuery ?? "" : typed
        let opened = openedUnread
        let key = ListKey(mailbox: selectedMailbox, query: q, filterUnread: filterUnread, hits: hits == nil ? -1 : hitsGeneration,
                          openedUnread: opened, grouped: groupsConversations && q.isEmpty)
        _ = messages.count  // registers the dependency for SwiftUI even when the cache answers
        if let c = listCache, c.revision == revision, c.key == key { return c.list }
        if let hits, !q.isEmpty {
            let list = Self.hitList(messages, hits.ids, scope: hits.scope, inTrash: foldersInTrash)
            listCache = (revision, key, list)
            return list
        }
        if !q.isEmpty { memoryQuery = q }
        let words = Self.searchWords(q)
        let found = messages.filter { m in
            if !q.isEmpty {
                guard inSearchScope(m), !isDeleted(m), m.mailbox != .junk else { return false }
                return Self.matches(m, words)
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
        .sorted(by: Self.newestFirst)
        let list = key.grouped ? grouping(found, key) : found
        listCache = (revision, key, list)
        return list
    }

    /// A search whose first answer is on its way, with no earlier results to keep: the list shows the mailbox meanwhile,
    /// and an empty one isn't "No Results" yet.
    public var awaitingSearchResults: Bool {
        let typed = normalizedSearch
        return !typed.isEmpty && searcher != nil && fallbackQuery != typed && searchHits == nil && memoryQuery == nil
    }

    /// The index's hits as they are in memory now: in scope, not in Trash (or a folder inside it) or Junk, newest first.
    /// Split across the cores: one pass over 180,000 messages takes about 45 ms in a debug build.
    nonisolated private static func hitList(_ msgs: [Message], _ hits: Set<Message.ID>, scope: Set<UUID>?,
                                            inTrash: [UUID: Set<MailboxKind>]) -> [Message] {
        let chunks = 8, size = (msgs.count + chunks - 1) / chunks
        nonisolated(unsafe) let parts = UnsafeMutableBufferPointer<[Message]>.allocate(capacity: chunks)
        _ = parts.initialize(from: repeatElement([], count: chunks))
        defer { parts.deinitialize(); parts.deallocate() }
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            parts[c] = msgs[min(c * size, msgs.count)..<min((c + 1) * size, msgs.count)].filter { m in
                hits.contains(m.id) && scope?.contains(m.accountID) != false && !isDeleted(m, inTrash) && m.mailbox != .junk
            }
        }
        return parts.flatMap { $0 }.sorted(by: Self.newestFirst)
    }

    /// Newest first; messages with the same time by their ID, so their order doesn't depend on the order they were
    /// loaded in (a relaunch loads the Inboxes first).
    nonisolated static func newestFirst(_ a: Message, _ b: Message) -> Bool {
        guard a.date == b.date else { return a.date > b.date }
        return withUnsafeBytes(of: a.id.uuid) { x in withUnsafeBytes(of: b.id.uuid) { y in memcmp(x.baseAddress!, y.baseAddress!, 16) < 0 } }
    }

    /// The typed words, folded as memory search compares them.
    nonisolated private static func searchWords(_ q: String) -> [String] {
        q.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
    }

    nonisolated private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Memory search, by the index's rules (README "Search"): every word, in any of subject, sender, To, Cc, the
    /// server's preview or the body; case and accents don't matter. Unlike the index, a word also matches inside
    /// a word. The fields are joined with line breaks, which no word contains, so a word never spans two fields.
    nonisolated private static func matches(_ m: Message, _ words: [String]) -> Bool {
        let fields = [m.subject, m.from.name, m.from.email] + (m.to + m.cc).flatMap { [$0.name, $0.email] }
            + [m.serverPreview ?? "", m.body]
        let text = fold(fields.joined(separator: "\n"))
        return words.allSatisfy { text.contains($0) }
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
            searchTask = nil; searchHits = nil; fallbackQuery = nil; memoryQuery = nil
            if statusIsAboutSearch { status = nil }
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
        let snapshot = messages, snapshotRevision = revision, inTrash = foldersInTrash
        do {
            // Detached, so neither the query nor the pass over all messages runs on the main actor.
            let (ids, hits, list) = try await Task.detached(priority: .userInitiated) {
                let ids = try await searcher(q, scope), hits = Set(ids)
                return (ids, hits, Self.hitList(snapshot, hits, scope: scope, inTrash: inTrash))
            }.value
            guard !Task.isCancelled, normalizedSearch == q, searchScope(selectedMailbox) == scope else { return }
            fallbackQuery = nil
            searchHits = (q, scope, hits)
            // The list is ready unless mail changed meanwhile; then `visibleMessages` makes it again.
            if revision == snapshotRevision {
                listCache = (revision, ListKey(mailbox: selectedMailbox, query: q, filterUnread: filterUnread,
                                               hits: hitsGeneration, openedUnread: openedUnread), list)
            }
            if ids.count >= MailDatabase.searchLimit {
                status = Self.limitNotice
            } else if statusIsAboutSearch {
                status = nil
            }
        } catch {
            guard !Task.isCancelled, normalizedSearch == q else { return }
            fallbackQuery = q
            searchHits = nil  // memory answers now: its results, not older hits, stay while the next query is pending
            status = Self.searchFailed + error.localizedDescription
        }
    }

    static let limitNotice = "Showing the newest 2,000 results"
    static let searchFailed = "Search failed: "

    /// The status is a search's own notice (the limit or a failure), which goes with that search.
    private var statusIsAboutSearch: Bool { status == Self.limitNotice || status?.hasPrefix(Self.searchFailed) == true }

    /// Read several times per redraw (menus, viewer, detail): where the selected message sits is kept per revision,
    /// so mail that arrived this session (at the end of `messages`) isn't found by a scan of all of them each time.
    public var selectedMessage: Message? {
        guard selection.count == 1, let id = selection.first else { return nil }
        _ = messages.count  // registers the dependency for SwiftUI even when the cache answers
        if let c = selectedCache, c.revision == revision, c.id == id { return c.index.map { messages[$0] } }
        let i = messages.firstIndex { $0.id == id }
        selectedCache = (revision, id, i)
        return i.map { messages[$0] }
    }

    @ObservationIgnored private var selectedCache: (revision: Int, id: Message.ID, index: Int?)?

    @ObservationIgnored private var conversationCache: (revision: Int, id: Message.ID, list: [Message])?

    /// The message with the rest of its conversation, newest first, as Mail shows it: the same account, every
    /// mailbox but Trash (and folders inside it), Junk and Drafts (the message itself always). Empty if the message is gone.
    public func conversation(of id: Message.ID) -> [Message] {
        _ = messages.count  // registers the dependency for SwiftUI even when the cache answers
        if let c = conversationCache, c.revision == revision, c.id == id { return c.list }
        guard let m = selectedMessage?.id == id ? selectedMessage : message(id) else { return [] }
        var list = [m]
        if let conv = m.conversationID {
            let skip: Set<MailboxKind> = [.trash, .junk, .drafts]
            list = messages.filter {
                $0.id == id || ($0.conversationID == conv && $0.accountID == m.accountID && !skip.contains($0.mailbox)
                                && !isDeleted($0))
            }
            .sorted(by: Self.newestFirst)
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
    /// Only messages it actually changes are saved again.
    private func update(_ ids: Set<Message.ID>, _ f: (inout Message) -> Void) {
        update(at: messages.indices.filter { ids.contains(messages[$0].id) }, f)
    }

    /// `update` of the messages at these indices, for a caller that already found them.
    private func update(at indices: [Int], _ f: (inout Message) -> Void) {
        var changed: [(old: Message, new: Message)] = []
        for i in indices {
            let old = messages[i]
            f(&messages[i])
            guard messages[i] != old else { continue }
            if old.remoteID != nil, messages[i].accountID != old.accountID {
                messages[i] = old
                status = "Exchange messages can't be moved to another account yet"
                continue
            }
            changedIDs.insert(old.id)
            if old.remoteID != nil { changed.append((old, messages[i])) }
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
            groups[key, default: []].append(Self.undoCopy(old))
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

    /// What a queued read, flag or move change keeps to undo itself: the message without its content. The undo
    /// only puts back read state, flag and mailbox, and the outbox is saved whole on every change.
    private static func undoCopy(_ m: Message) -> Message {
        var c = m
        c.body = ""; c.html = nil; c.htmlChecked = nil; c.attachments = []; c.serverPreview = nil; c.bodyLoaded = false
        return c
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

    /// Move to Junk; when every message is already in Junk, Not Junk (back to the Inbox).
    public func toggleJunk(_ ids: Set<Message.ID>) {
        let allJunk = !messages.contains { ids.contains($0.id) && $0.mailbox != .junk }
        keepingSelectionVisible(ids) { update(ids) { $0.mailbox = allJunk ? .inbox : .junk } }
    }

    /// Runs a move or delete of `ids`. Selected messages it takes out of the list (or erases) don't stay
    /// selected, so a second Delete can't erase a message the user never saw in Trash. When that was the whole
    /// selection, the message that followed it in the list is selected, as after Delete (unless `selectNext` is
    /// false: a read or flag change only lets go of them, so no other message is opened and marked read).
    private func keepingSelectionVisible(_ ids: Set<Message.ID>, selectNext: Bool = true, _ body: () -> Void) {
        guard !selection.isDisjoint(with: ids) else { body(); return }
        let list = visibleMessages.map(\.id), before = selection
        body()
        let remaining = Set(visibleMessages.map(\.id))
        let gone = before.intersection(ids).subtracting(remaining)
        guard !gone.isEmpty, selection == before else { return }
        selection = gone == before && selectNext ? Self.following(before, in: list, remaining: remaining) ?? [] : before.subtracting(gone)
    }

    /// The message after the last of `ids` in `list` that is still in it (else the one before), as Mail selects
    /// after an action; nil when none of `ids` was in the list.
    private static func following(_ ids: Set<Message.ID>, in list: [Message.ID], remaining: Set<Message.ID>) -> Set<Message.ID>? {
        guard let lastIdx = list.lastIndex(where: ids.contains) else { return nil }
        let next = list[(lastIdx + 1)...].first { remaining.contains($0) && !ids.contains($0) }
            ?? list[..<lastIdx].last { remaining.contains($0) && !ids.contains($0) }
        return next.map { [$0] } ?? []
    }

    public func setFlag(_ c: FlagColor?, for ids: Set<Message.ID>) {
        keepingSelectionVisible(ids, selectNext: false) { update(ids) { $0.flag = c } }
    }

    public func toggleRead(_ ids: Set<Message.ID>) {
        let anyUnread = messages.contains { ids.contains($0.id) && !$0.isRead }
        keepingSelectionVisible(ids, selectNext: false) { update(ids) { $0.isRead = anyUnread } }
    }

    public func markSelectionRead() {
        var opened: [Message.ID] = []
        update(withConversations(selection)) { m in
            if !m.isRead { opened.append(m.id) }
            m.isRead = true
        }
        openedUnread.formUnion(opened)
    }

    public func markAllRead(in ref: MailboxRef) {
        update(Set(messages.filter { contains(ref, $0) }.map(\.id))) { $0.isRead = true }
        // Launch is still loading: the mailbox's mail that isn't in memory yet is marked as it arrives.
        if isLoading { markAllReadWhenLoaded.append(ref) }
    }

    /// Mailboxes marked all read while launch was loading, applied to the stored mail `finishLoading` brings.
    @ObservationIgnored private var markAllReadWhenLoaded: [MailboxRef] = []

    /// Runs `action` on the selection, then selects the message that followed it in the list – as Mail does.
    /// A selection that wasn't in the list (hidden by the unread filter or a search) isn't kept selected
    /// once the action takes it out of the list. An action that changes none of them keeps the selection.
    public func actOnSelection(_ action: (Set<Message.ID>) -> Void) {
        let list = visibleMessages.map(\.id)
        let ids = listSelection, all = withConversations(ids)
        let before = messages.filter { all.contains($0.id) }
        action(all)
        guard messages.filter({ all.contains($0.id) }) != before else { return }
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
        let change: (inout Message) -> Void = { m in
            switch ref {
            case .smart(.flagged): if m.flag == nil { m.flag = .red }
            case .smart(.allInboxes): m.mailbox = .inbox
            case let .account(acct, kind): m.accountID = acct; m.mailbox = kind
            case .smart(.vip), .smart(.unread): break
            }
        }
        // Runs on the main thread as the mouse is let go, so the whole message array is gone over as few times as
        // possible: once, to find the dropped messages by index (without copying each message).
        let at = messages.indices.filter { ids.contains(messages[$0].id) }
        let dropped = at.map { messages[$0] }
        // Only messages the drop changes: a flagged one in Trash isn't listed in Flagged, but has its flag already.
        var moving = Set(dropped.filter { m in
            guard !contains(ref, m) else { return false }
            var c = m
            change(&c)
            return c != m
        }.map(\.id))
        if case let .account(acct, _) = ref {
            let blocked = dropped.filter { moving.contains($0.id) && $0.remoteID != nil && $0.accountID != acct }
            if !blocked.isEmpty { status = "Exchange messages can't be moved to another account yet" }
            moving.subtract(blocked.map(\.id))
        }
        guard !moving.isEmpty else { return false }
        let movingAt = at.filter { moving.contains(messages[$0].id) }
        let rows = listSelection
        if !rows.isEmpty, ids == withConversations(rows) {
            // As `actOnSelection`: the selection moves on to the row that followed it. Every message in `moving`
            // changes, so there is no need to compare the messages before and after.
            let list = visibleMessages.map(\.id)
            update(at: movingAt, change)
            let remaining = Set(visibleMessages.map(\.id))
            selection = Self.following(rows, in: list, remaining: remaining) ?? rows.intersection(remaining)
        } else {
            keepingSelectionVisible(moving) { update(at: movingAt, change) }
        }
        return true
    }

    // MARK: Server sync

    /// Adds a server account. Its mail arrives with the next `refresh()`. Without a backend (no password yet) it is
    /// still a server account: its changes wait in the outbox. Adding an account that is already here (signing in
    /// again) gives it the backend.
    public func add(_ account: Account, backend: (any MailBackend)?) {
        if self.account(account.id) == nil { accounts.append(account) }
        backends[account.id] = backend
        if backend != nil { paused.remove(account.id) }
        serverAccounts.insert(account.id)
    }

    /// Drops accounts without a server (the sample data) and their local messages. A server account stays, also
    /// while it has no backend (no password).
    public func removeLocalAccounts() {
        let local = Set(accounts.filter { !$0.isServer && backends[$0.id] == nil }.map(\.id))
        guard !local.isEmpty else { return }  // nothing to remove: the view stays as it is
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
    /// `asked`: the `requestStamp` when the page was requested; changes written since then keep their value.
    public func apply(_ r: SyncResult, account: UUID, mailbox: MailboxKind, asked: Int? = nil) {
        startPassIfFromScratch(account, mailbox)
        merge(r.upserts, deleted: r.deletedRemoteIDs, reads: r.readChanges, account: account, mailbox: mailbox, asked: asked)
        listed(r.upserts.compactMap(\.remoteID) + r.readChanges.keys, account, mailbox, complete: !r.more)
        syncTokens[key(account, mailbox)] = r.token
        if !r.more { complete.insert(key(account, mailbox)) }
    }

    /// Applies several pages of one folder in one merge, as if one after the other. Each merge goes over every
    /// message, so a batch of history pages costs one pass instead of one per page.
    public func apply(_ pages: [SyncResult], account: UUID, mailbox: MailboxKind, asked: Int? = nil) {
        guard let last = pages.last else { return }
        startPassIfFromScratch(account, mailbox)
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
              account: account, mailbox: mailbox, asked: asked)
        listed(pages.flatMap { $0.upserts.compactMap(\.remoteID) + $0.readChanges.keys }, account, mailbox,
               complete: !last.more)
        syncTokens[key(account, mailbox)] = last.token
        if !last.more { complete.insert(key(account, mailbox)) }
    }

    /// A sync without a token starts a pass over the whole folder: every server message here now must be listed by it.
    private func startPassIfFromScratch(_ account: UUID, _ mailbox: MailboxKind) {
        let k = key(account, mailbox)
        guard syncTokens[k] == nil else { return }
        var ids = Set<String>()
        for m in messages where m.accountID == account && m.mailbox == mailbox { if let r = m.remoteID { ids.insert(r) } }
        unlisted[k] = (false, ids)
    }

    /// Server IDs a page of a from-scratch pass listed. Its last page removes the rest (`prune`).
    private func listed(_ rids: [String], _ account: UUID, _ mailbox: MailboxKind, complete: Bool) {
        let k = key(account, mailbox)
        guard var pass = unlisted[k], !pass.done else { return }
        pass.ids.subtract(rids)
        pass.done = complete
        unlisted[k] = pass
        if complete { prune() }
    }

    /// The server rejected the folder's token: it is forgotten and the folder syncs again from the start; the
    /// complete pass then removes what is gone. Once per folder and session: if the new token is rejected too, the
    /// folder is reported and left as it is (the history skips it) rather than downloaded again on every check.
    private func resetSync(_ account: UUID, _ mailbox: MailboxKind) {
        let k = key(account, mailbox)
        guard tokensReset.insert(k).inserted else {
            historyFailed.insert(k)
            historyError = "\(name(of: mailbox, in: account)): \(SyncTokenRejected().localizedDescription)"
            status = historyError
            return
        }
        syncTokens[k] = nil
        complete.remove(k)
    }

    /// Removes what a completed from-scratch pass didn't list: deleted or moved away on the server meanwhile.
    /// A message with a change still queued stays until that change is done (`drain` calls this again).
    private func prune() {
        for (k, pass) in unlisted where pass.done {
            guard let account = UUID(uuidString: String(k.prefix(36))) else { continue }
            let mailbox = MailboxKind(rawValue: String(k.dropFirst(37)))
            let pending = Set(outbox.lazy.filter { $0.account == account }.flatMap(\.change.remoteIDs))
            var gone = Set<Message.ID>(), kept = Set<String>()
            for m in messages where m.accountID == account && m.mailbox == mailbox {
                guard let r = m.remoteID, pass.ids.contains(r) else { continue }
                if pending.contains(r) { kept.insert(r) } else { gone.insert(m.id) }
            }
            unlisted[k] = kept.isEmpty ? nil : (true, kept)
            guard !gone.isEmpty else { continue }
            messages.removeAll { gone.contains($0.id) }
            selection.subtract(gone)
            forget(gone)
        }
    }

    /// Merges server messages into one mailbox without touching its sync position (used for the newest-N
    /// lookup). Known messages keep their local ID, selection and loaded body. A message with a change still
    /// waiting for the server keeps the property that change sets (read state, flag or mailbox), and takes the
    /// server's word for the others.
    public func merge(_ upserts: [Message], deleted: [String] = [], reads: [String: Bool] = [:],
                      account: UUID, mailbox: MailboxKind, asked: Int? = nil) {
        merge([(mailbox, upserts)], deleted: deleted, reads: reads, account: account, asked: asked)
    }

    /// The same for several mailboxes in one pass over all messages, e.g. the newest messages of each folder.
    /// When nothing changes, `messages` isn't touched: assigning it redraws every view.
    public func merge(_ groups: [(MailboxKind, [Message])], deleted: [String] = [], reads: [String: Bool] = [:],
                      account: UUID, asked: Int? = nil) {
        serverAccounts.insert(account)
        guard groups.contains(where: { !$0.1.isEmpty }) || !deleted.isEmpty || !reads.isEmpty else { return }
        let mine = outbox.lazy.filter { $0.account == account }
        // Each queued change keeps only the property it changes; the server's word stands for the others.
        var guarded: [String: Guarded] = [:]
        for p in mine { for rid in p.change.remoteIDs { guarded[rid, default: []].formUnion(Guarded(p.change)) } }
        // So does a change written after this answer was requested: the answer is older than it.
        if let asked, let w = written[account] {
            var rids = Set(reads.keys)
            for (_, ups) in groups { for m in ups { if let r = m.remoteID { rids.insert(r) } } }
            for rid in rids {
                guard let t = w[rid] else { continue }
                var g: Guarded = []
                if t.read > asked { g.insert(.read) }
                if t.flag > asked { g.insert(.flag) }
                if t.mailbox > asked { g.insert(.mailbox) }
                if !g.isEmpty { guarded[rid, default: []].formUnion(g) }
            }
        }
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
        let held = Set(deleted).intersection(moving)
        if !held.isEmpty { deletedWhileMoving[account, default: []].formUnion(held) }
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
        if !gone.isEmpty { dropQueuedReadsAndFlags(of: gone, account: account) }
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
                    // What only the body knows is kept: addresses (summaries may carry names only) and the
                    // attachment list with its paperclip. Unless the summary names other people or has another preview
                    // (the start of the text): then the message changed on the server (a draft edited elsewhere), and
                    // its body is fetched again when shown.
                    if old.bodyLoaded && !m.bodyLoaded, old.serverPreview == nil || m.serverPreview == old.serverPreview,
                       let from = Self.keeping([m.from], old: [old.from])?.first,
                       let to = Self.keeping(m.to, old: old.to), let cc = Self.keeping(m.cc, old: old.cc) {
                        m.body = old.body; m.attachments = old.attachments; m.bodyLoaded = true
                        // A meeting response loaded before BUG-038 carries an invite; the server says it's none.
                        m.invite = m.isInvite == false ? nil : old.invite
                        m.html = old.html; m.htmlChecked = old.htmlChecked
                        m.from = from; m.to = to; m.cc = cc; m.hasAttachments = old.hasAttachments
                    }
                    if let g = guarded[rid] {
                        if g.contains(.read) { m.isRead = old.isRead }
                        if g.contains(.flag) { m.flag = old.flag }
                        if g.contains(.mailbox) { m.mailbox = old.mailbox }
                    }
                    guard m != old else { continue }
                    ms[i] = m
                } else if let rid = m.remoteID, guarded[rid] != nil {
                    // Gone here with a change still queued, or written since this answer was requested (erased, or
                    // moved: Exchange gave it a new ID): an answer from before that change doesn't bring it back.
                    continue
                } else {
                    ms.append(m)
                    if let rid = m.remoteID { index[rid] = ms.count - 1 }
                }
                changedIDs.insert(m.id)
                changed = true
            }
        }
        for (rid, read) in reads where guarded[rid]?.contains(.read) != true {
            if let i = index[rid], ms[i].isRead != read { ms[i].isRead = read; changedIDs.insert(ms[i].id); changed = true }
        }
        if changed { messages = ms }
    }

    /// The properties of a message a server change sets: a server page doesn't undo them while it is queued.
    private struct Guarded: OptionSet {
        let rawValue: UInt8
        static let read = Guarded(rawValue: 1), flag = Guarded(rawValue: 2), mailbox = Guarded(rawValue: 4)
        init(rawValue: UInt8) { self.rawValue = rawValue }
        init(_ c: ServerChange) {
            switch c {
            case .setRead: self = .read
            case .setFlagged: self = .flag
            case .move, .respond, .reply, .removeFromCalendar: self = .mailbox
            case .delete: self = [.read, .flag, .mailbox]
            case .send, .saveDraft: self = []
            }
        }
    }

    /// The loaded contacts, with any address a summary gives in their place; nil when the summary names other people.
    /// A summary contact without an address matches a loaded one by name (any case) or by the address shown as name.
    nonisolated static func keeping(_ summary: [Contact], old: [Contact]) -> [Contact]? {
        guard summary.count == old.count else { return nil }
        var out: [Contact] = []
        for (s, o) in zip(summary, old) {
            if !s.email.isEmpty { out.append(s); continue }
            let name = s.name.trimmingCharacters(in: .whitespaces)
            guard name.caseInsensitiveCompare(o.name.trimmingCharacters(in: .whitespaces)) == .orderedSame
                    || name.caseInsensitiveCompare(o.email) == .orderedSame else { return nil }
            out.append(o)
        }
        return out
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
        for id in filesChanged where !removedIDs.contains(id) { c.files[id] = localAttachments[id] }
        changedIDs = []; removedIDs = []; filesChanged = []
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
        filesChanged.formUnion(c.files.keys.filter { !removedIDs.contains($0) })
    }

    /// Everything that is stored, to fill a new database.
    public func storedState() -> StoreChanges {
        let stored = messages.filter { isStored($0.accountID) }, ids = Set(stored.map(\.id))
        return StoreChanges(upserts: stored, sync: syncStates(), folders: folders.filter { isStored($0.key) }, outbox: outbox,
                            files: localAttachments.filter { ids.contains($0.key) })
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
        // A check that ran before this (a mailbox selected while launch loads) has newer positions: they stay.
        let fetched = Set(syncTokens.keys)
        for s in meta.sync where mine.contains(s.account) {
            if let t = s.token, !fetched.contains(key(s.account, s.mailbox)) { syncTokens[key(s.account, s.mailbox)] = t }
            if s.complete { complete.insert(key(s.account, s.mailbox)) }
            serverAccounts.insert(s.account)
        }
        for (a, f) in meta.folders where mine.contains(a) && folders[a] == nil {
            folders[a] = f
            serverAccounts.insert(a)
        }
        localAttachments.merge(meta.files) { current, _ in current }
        var interrupted = false
        for p in meta.outbox where mine.contains(p.account) {
            // A send that was on its way when the app quit or crashed may have gone out: never sent again.
            if p.inFlight == true, case let .send(d) = p.change {
                keepInDrafts(d)
                status = "“\(d.subject.isEmpty ? "(No Subject)" : d.subject)” may already have been sent: the app quit while "
                    + "sending it. It's in Drafts on this Mac; check Sent before sending it again."
                interrupted = true
            } else {
                outbox.append(p)
            }
        }
        loadedBoxes = []
        // What was just read from disk doesn't need writing back; a send taken out of the outbox does, and so do
        // positions fetched before it.
        syncChanged = !fetched.isEmpty; foldersChanged = false; outboxChanged = interrupted
    }

    /// Launch, step 2: the mail of some mailboxes (the Inbox first), shown while the rest loads.
    public func restore(_ msgs: [Message], boxes: [MailboxKey]) {
        messages += notInMemory(withoutRemovedFolders(msgs))
        for b in boxes { loadedBoxes?.insert(key(b.account, b.mailbox)) }
    }

    /// Launch, step 3: everything else. A message changed meanwhile keeps its version in memory.
    /// Then waiting changes go to the server and the history sync may start.
    public func finishLoading(_ rest: [Message]) {
        let added = notInMemory(withoutRemovedFolders(rest))
        messages += added
        removedFolders = [:]
        loadedBoxes = nil
        if !markAllReadWhenLoaded.isEmpty {
            // Only the stored mail just added: what arrived or was marked unread since the action keeps its state.
            let refs = markAllReadWhenLoaded
            update(Set(added.lazy.filter { m in refs.contains { self.contains($0, m) } }.map(\.id))) { $0.isRead = true }
            markAllReadWhenLoaded = []
        }
        scheduleFlush()
        if !backends.isEmpty { startHistory() }
    }

    /// Stored messages to add at launch: those of the accounts set up (the mail of an account no longer in the list
    /// stays on disk but isn't shown), and not in memory yet. A server message a check brought before launch had
    /// read it is in memory under another local ID: that newer version stays, and the stored row goes.
    private func notInMemory(_ stored: [Message]) -> [Message] {
        struct RemoteKey: Hashable { let account: UUID; let id: String }
        let mine = Set(accounts.map(\.id))
        let known = Set(messages.map(\.id))
        var remote = Set<RemoteKey>()
        for m in messages { if let r = m.remoteID { remote.insert(RemoteKey(account: m.accountID, id: r)) } }
        var stale = Set<Message.ID>()
        let new = stored.filter { m in
            guard mine.contains(m.accountID), !known.contains(m.id) else { return false }
            if !remote.isEmpty, let r = m.remoteID, remote.contains(RemoteKey(account: m.accountID, id: r)) {
                stale.insert(m.id)
                return false
            }
            return true
        }
        if !stale.isEmpty { forget(stale) }
        return new
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

    /// Every folder syncs once more from the start (an import of mail from before conversations).
    func forgetSyncPositions() {
        syncTokens = [:]
        complete = []
    }

    // MARK: Write-back

    /// Exchange gives moved items new IDs. Updates the messages and the changes still queued.
    public func renameRemote(_ map: [String: String], account: UUID) {
        // The destination's sync may already have brought a moved message under its new ID. That copy goes; the
        // renamed message keeps its local ID, body and selection.
        // One pass over the messages, by index (this runs on the main thread after every move): the renamed ones and
        // those already under a new ID; the rest works on these few.
        let newIDs = Set(map.values)
        var renamed: [Int] = [], under: [Int] = []
        for i in messages.indices where messages[i].accountID == account {
            guard let rid = messages[i].remoteID else { continue }
            if map[rid] != nil { renamed.append(i) } else if newIDs.contains(rid) { under.append(i) }
        }
        var original: [String: Message.ID] = [:]  // new ID → the message renamed to it
        for i in renamed { original[map[messages[i].remoteID!]!] = messages[i].id }
        for i in renamed {
            messages[i].remoteID = map[messages[i].remoteID!]
            changedIDs.insert(messages[i].id)
        }
        var copies = Set<Message.ID>()
        for i in under {
            guard let keep = original[messages[i].remoteID!] else { continue }
            copies.insert(messages[i].id)
            if selection.remove(messages[i].id) != nil { selection.insert(keep) }
        }
        if !copies.isEmpty {
            messages.removeAll { copies.contains($0.id) }
            forget(copies)
        }
        for i in outbox.indices where outbox[i].account == account {
            outbox[i].change = outbox[i].change.renamed(map)
            // The copies kept for undoing too: a refused erase puts the message back under the ID the server has now.
            for j in outbox[i].previous.indices {
                if let rid = outbox[i].previous[j].remoteID, let new = map[rid] { outbox[i].previous[j].remoteID = new }
            }
        }
    }

    /// The server refused a change: undo it locally. A message that couldn't be sent is kept in Drafts.
    public func failed(_ p: PendingChange, _ error: String) {
        outbox.removeAll { $0.id == p.id }
        switch p.change {
        case let .send(d), let .saveDraft(d):
            keepInDrafts(d)
            let what = if case .send = p.change { "send" } else { "save the draft" }
            status = "Couldn't \(what) “\(d.subject.isEmpty ? "(No Subject)" : d.subject)”: \(error). It's in Drafts on this Mac."
        default:
            // Only what this change set, and only while it still holds: later changes (still queued or sent)
            // stay, and a message erased since isn't brought back. Only a refused erase re-adds the message.
            // A refused move of a message the server reported deleted meanwhile: that deletion was real.
            var deletedOnServer = Set<Message.ID>()
            // One pass finds the whole batch (a batch of 100 among 180,000 messages), not one search per message.
            let wanted = Set(p.previous.map(\.id))
            var at: [Message.ID: Int] = [:]
            for i in messages.indices where wanted.contains(messages[i].id) { at[messages[i].id] = i }
            for old in p.previous {
                guard let i = at[old.id] else {
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
                case let .move(_, box):
                    if let r = messages[i].remoteID, deletedWhileMoving[p.account]?.remove(r) != nil {
                        deletedOnServer.insert(old.id)
                    } else if messages[i].mailbox == box { messages[i].mailbox = old.mailbox }
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
            if !deletedOnServer.isEmpty {
                messages.removeAll { deletedOnServer.contains($0.id) }
                selection.subtract(deletedOnServer)
                forget(deletedOnServer)
            }
            // The comment the user typed for the organizer isn't lost with the answer: kept like a failed send.
            if case let .reply(_, r) = p.change, let comment = r.comment, let old = p.previous.first, let invite = old.invite {
                keepInDrafts(Draft(accountID: p.account, to: Self.organizer(invite),
                                   subject: Self.answerSubject(r.response, proposing: r.proposedStart != nil, old.subject), body: comment))
                status = "Couldn't send your answer to “\(old.subject)”: \(error). Your comment is in Drafts on this Mac."
                return
            }
            status = "Exchange refused a change: \(error)"
        }
    }

    /// A message that didn't reach the server, or may not have: kept as a local message in Drafts, with its files.
    private func keepInDrafts(_ d: Draft) {
        let acct = account(d.accountID)
        var m = Message(accountID: d.accountID, mailbox: .drafts,
                        from: Contact(name: acct?.name ?? "", email: acct?.address ?? ""),
                        to: Contact.parseList(d.to), cc: Contact.parseList(d.cc),
                        subject: d.subject.isEmpty ? "(No Subject)" : d.subject,
                        body: d.text, date: .now, isRead: true, attachments: d.attachments.map(\.attachment))
        // Pictures placed in the text stay in their place: an HTML body referring to the kept files.
        let placed = Set(d.placedPictures)
        if !placed.isEmpty {
            m.html = d.html { placed.contains($0) ? Self.localContentID($0) : nil }
            m.htmlChecked = true
        }
        add(m)
        if !d.attachments.isEmpty { keepFiles(d.attachments.map(\.data), for: m) }
    }

    private func scheduleFlush() {
        // Not while loading: the server renames moved messages, and those not in memory yet would keep old IDs.
        guard flushTask == nil, loadedBoxes == nil, outbox.contains(where: canSend) else { return }
        flushTask = Task {
            await drain()
            flushTask = nil
        }
    }

    /// Read and flag changes still queued for messages the server reports deleted are moot: their IDs are taken out
    /// (with the undo copies), so they aren't sent, refused and undone for a message that no longer exists.
    private func dropQueuedReadsAndFlags(of gone: Set<String>, account: UUID) {
        func kept(_ ids: [String]) -> [String]? {
            let k = ids.filter { !gone.contains($0) }
            return k.count == ids.count ? nil : k
        }
        var box = outbox, touched = false
        box = box.compactMap { p in
            guard p.account == account else { return p }
            var q = p
            switch p.change {
            case let .setRead(ids, v): guard let k = kept(ids) else { return p }; q.change = .setRead(k, v)
            case let .setFlagged(ids, v): guard let k = kept(ids) else { return p }; q.change = .setFlagged(k, v)
            default: return p
            }
            touched = true
            if q.change.remoteIDs.isEmpty { return nil }
            q.previous = p.previous.filter { $0.remoteID.map { !gone.contains($0) } ?? true }
            return q
        }
        if touched { outbox = box }
    }

    /// Writes queued changes in order. When an account's server can't be reached, its changes stay queued for the
    /// next refresh while other accounts' changes go out; a send is never retried, because a timed-out send may have
    /// gone out.
    private func drain() async {
        // Accounts whose server couldn't be reached this time: their changes wait, in order; the others go on.
        var unreachable = Set<UUID>()
        while let p = outbox.first(where: { canSend($0) && !unreachable.contains($0.account) }),
              let backend = backends[p.account] {
            if case .send = p.change, let i = outbox.firstIndex(where: { $0.id == p.id }) {
                // Marked and saved before the request goes out: a quit or crash meanwhile can't send it twice.
                outbox[i].inFlight = true
                await saveBeforeSending?()
            }
            do {
                do { try await perform(p, backend) } catch let e as LeftOnServer {
                    // A half message in the server's Drafts: erased later (`merge` keeps it out meanwhile). The
                    // server just failed twice, so the account waits until the next drain.
                    outbox.append(PendingChange(account: p.account, change: .delete([e.remoteID]), previous: []))
                    unreachable.insert(p.account)
                    throw e.error
                }
                outbox.removeAll { $0.id == p.id }
                noteWritten(p.change, p.change.remoteIDs, account: p.account)
                // The move went through: the deletions its source reported were its own.
                if case let .move(ids, _) = p.change { deletedWhileMoving[p.account]?.subtract(ids) }
            } catch where pauseIfSignInFailed(error, account: p.account) {
                // Refused at sign-in: it didn't go out, and goes when the account works again.
                if let i = outbox.firstIndex(where: { $0.id == p.id }) { outbox[i].inFlight = nil }
                continue
            } catch let e as URLError {
                // A send or an answer that timed out may have gone out; never repeat it.
                if case .send = p.change { failed(p, e.localizedDescription); continue }
                if case .respond = p.change { failed(p, e.localizedDescription); continue }
                if case .reply = p.change { failed(p, e.localizedDescription); continue }
                connectionNotice("Offline – changes will be sent to Exchange later", account: p.account)
                unreachable.insert(p.account)
            } catch let e as ServerBusy {
                // Not refused, just not now. A send or an answer may still have gone out; never repeat it.
                if case .send = p.change { failed(p, e.localizedDescription); continue }
                if case .respond = p.change { failed(p, e.localizedDescription); continue }
                if case .reply = p.change { failed(p, e.localizedDescription); continue }
                connectionNotice("Exchange is busy – changes will be sent later", account: p.account)
                unreachable.insert(p.account)
                if let wait = e.retryAfter { busyUntil[p.account] = Date.now.addingTimeInterval(wait) }
            } catch let e as PartlyRefused {
                // The other items changed on the server: they keep the change (and moved ones their new IDs).
                renameRemote(e.moved, account: p.account)
                deletedWhileMoving[p.account]?.subtract(e.moved.keys)
                noteWritten(p.change, p.change.remoteIDs.filter { e.refused[$0] == nil }, account: p.account)
                var refused = p
                // `previous` follows the change's IDs in order; matched by position, as an earlier move renames the IDs.
                refused.previous = zip(p.change.remoteIDs, p.previous.filter { $0.remoteID != nil })
                    .filter { e.refused[$0.0] != nil }.map(\.1)
                failed(refused, e.localizedDescription)
            } catch {
                failed(p, error.localizedDescription)
            }
        }
        prune()
    }

    /// Moves an answered invite (or a removed cancellation) to Deleted Items after its answer went out, reading the
    /// folder list first if it isn't known yet. If the server already moved it, the move fails and nothing else
    /// happens. If the server can't be reached or is busy, the move is queued as an ordinary change and goes later.
    /// Any other refusal is shown: the message stays in its folder on the server and comes back at the next check.
    private func moveToTrash(_ id: String, account: UUID, _ b: any MailBackend) async {
        do {
            if remoteFolders[account] == nil { setRemoteFolders(try await b.folders(), account: account) }
            guard let trash = remoteFolders[account]?.first(where: { $0.role == .trash }) else { return }
            renameRemote(try await b.move([id], to: trash), account: account)
        } catch where error is URLError || error is ServerBusy || error is AuthenticationError {
            if let wait = (error as? ServerBusy)?.retryAfter { busyUntil[account] = Date.now.addingTimeInterval(wait) }
            outbox.append(PendingChange(account: account, change: .move([id], to: .trash), previous: []))
        } catch where !error.localizedDescription.contains("ErrorItemNotFound") {
            let subject = messages.first { $0.accountID == account && $0.remoteID == id }?.subject ?? ""
            status = "Couldn't move “\(subject)” to Trash on the server: \(error.localizedDescription)"
        } catch {}
    }

    /// A change reached the server: answers requested before now don't undo it (`written`).
    private func noteWritten(_ c: ServerChange, _ ids: [String], account: UUID) {
        let g = Guarded(c)
        guard !g.isEmpty, !ids.isEmpty else { return }
        requestStamp += 1
        var w = written[account] ?? [:]
        for rid in ids {
            var t = w[rid] ?? Written()
            if g.contains(.read) { t.read = requestStamp }
            if g.contains(.flag) { t.flag = requestStamp }
            if g.contains(.mailbox) { t.mailbox = requestStamp }
            w[rid] = t
        }
        written[account] = w
    }

    private func connectionNotice(_ text: String, account acct: UUID) {
        connectionNotices[acct] = text
        status = text
    }

    private func canSend(_ p: PendingChange) -> Bool {
        backends[p.account] != nil && !paused.contains(p.account) && (busyUntil[p.account] ?? .distantPast) <= .now
    }

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
            if !r.send { await moveToTrash(id, account: p.account, b) }
        case let .removeFromCalendar(id):
            try await b.removeFromCalendar(id)
            // Like an unsent answer: if Exchange leaves the cancellation in the Inbox, move it.
            await moveToTrash(id, account: p.account, b)
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
    /// Invites whose day couldn't be read (no server, paused, an error) and has none shown: no longer waited for.
    public private(set) var unavailableDays: Set<Message.ID> = []

    /// Fetches the local calendar day around an invite, for its day column and conflict note.
    public func loadDay(for id: Message.ID) async {
        guard let m = message(id), let invite = m.invite else { return }
        guard let backend = backends[m.accountID], !paused.contains(m.accountID) else {
            if dayEvents[id] == nil { unavailableDays.insert(id) }
            return
        }
        let from = Calendar.current.startOfDay(for: invite.start)
        let to = Calendar.current.date(byAdding: .day, value: 1, to: from) ?? from.addingTimeInterval(86400)
        do { setDayEvents(try await backend.events(from: from, to: to), for: id) } catch {
            // A cancelled load (the user moved on) says nothing about the calendar: the next showing loads it again.
            if Self.wasCancelled(error) { return }
            if dayEvents[id] == nil { unavailableDays.insert(id) }
            if !pauseIfSignInFailed(error, account: m.accountID) { status = "Couldn't load the calendar: \(error.localizedDescription)" }
        }
    }

    /// Whether an invite or cancellation can be answered (or removed from the calendar): only one you received, as
    /// in Outlook. Your own, in Sent or sent from the account's address, has no answer buttons.
    public func canAnswer(_ id: Message.ID) -> Bool {
        guard let m = message(id), m.invite != nil, m.mailbox != .sent else { return false }
        guard let own = account(m.accountID)?.address, !own.isEmpty else { return true }
        return m.from.email.caseInsensitiveCompare(own) != .orderedSame
    }

    /// Answers an invite: shown at once, then sent. Exchange tells the organizer and updates the calendar.
    public func respond(_ r: InviteResponse, to id: Message.ID) {
        answer(id, response: r, reply: nil) { .respond($0, r) }
    }

    /// Answers an invite with options (comment, not sending, a proposed time).
    public func respond(_ reply: InviteReply, to id: Message.ID) {
        // Exchange takes a proposal only as a pair; half of one would go out as a plain answer.
        if (reply.proposedStart == nil) != (reply.proposedEnd == nil) {
            status = "The proposed meeting needs both a start and an end."
            return
        }
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
        guard let old = message(id), canAnswer(id) else { return }
        let apply: (Set<Message.ID>) -> Void = { _ in
            guard let i = self.messages.firstIndex(where: { $0.id == id }) else { return }
            self.changedIDs.insert(id)
            self.messages[i].invite?.response = response
            self.messages[i].invite?.reply = reply
            self.messages[i].mailbox = .trash
        }
        // One of several selected: it leaves the selection with its move, so Delete can't erase it from Trash unseen.
        if selection == [id] { actOnSelection(apply) } else { keepingSelectionVisible([id]) { apply([id]) } }
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
        guard inline[id] == nil, let m = message(id), let html = m.html else { return }
        let ids = HTMLPage.contentIDs(in: html)
        guard !ids.isEmpty else { return }
        // A message kept only here (a draft whose send failed) refers to its own files.
        if m.remoteID == nil, let files = localAttachments[id] {
            var images: [String: InlineImage] = [:]
            for cid in ids {
                guard let k = Self.localFileIndex(cid), files.indices.contains(k), m.attachments.indices.contains(k) else { continue }
                images[cid] = InlineImage(contentType: m.attachments[k].contentType ?? "application/octet-stream", data: files[k])
            }
            if !images.isEmpty { addInlineImages(images, for: id) }
            return
        }
        guard let rid = m.remoteID, let backend = backends[m.accountID], !paused.contains(m.accountID) else { return }
        do { addInlineImages(try await backend.inlineImages(remoteID: rid, contentIDs: ids), for: id) } catch {
            if !Self.wasCancelled(error), !pauseIfSignInFailed(error, account: m.accountID) { status = "Couldn't load images: \(error.localizedDescription)" }
        }
    }

    /// The content ID by which a local message's HTML refers to its k-th file.
    static func localContentID(_ k: Int) -> String { "file\(k)@local" }

    static func localFileIndex(_ cid: String) -> Int? {
        guard cid.hasPrefix("file"), cid.hasSuffix("@local") else { return nil }
        return Int(cid.dropFirst(4).dropLast(6))
    }

    // MARK: Attachments

    /// Where opened attachments are written, a folder per message, like Mail's "Mail Downloads".
    @ObservationIgnored public var downloadsFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("Mail Downloads")
    /// The content of attachments of messages without a server (sample data), by position.
    @ObservationIgnored private var localAttachments: [Message.ID: [Data]] = [:]
    /// What Quick Look shows: every attachment of a message, and the one in front.
    public var previewItems: [URL] = []
    /// Counts Quick Look requests, so only the latest sets what is shown.
    @ObservationIgnored private var quickLookRequest = 0
    public var previewItem: URL?

    /// For sample data and tests: the content of a local message's attachments, in order.
    public func setAttachmentData(_ data: [Data], for id: Message.ID) { localAttachments[id] = data }

    /// The files of a message kept only on this Mac; written to disk with it when its account is stored.
    private func keepFiles(_ data: [Data], for m: Message) {
        localAttachments[m.id] = data
        if isStored(m.accountID) { filesChanged.insert(m.id) }
    }

    /// Size and modification date of each attachment file this store wrote, to tell whether an app changed it since.
    @ObservationIgnored private var writtenFiles: [URL: FileStamp] = [:]

    struct FileStamp: Equatable {
        let size: Int?, modified: Date?
        init?(_ url: URL) {
            guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            size = (a[.size] as? NSNumber)?.intValue
            modified = a[.modificationDate] as? Date
        }
    }

    /// The attachment as a file, fetched from the server the first time. nil (and a status) if that fails.
    /// Opening again gives the same file, with any edits the user made to it.
    public func attachmentFile(_ index: Int, of id: Message.ID) async -> URL? {
        await attachmentFile(index, of: id, original: false)
    }

    /// The attachment exactly as it came in the mail, for Save and Forward. The opened file is used only while no
    /// app has changed it (Preview saves a filled-in form in place); otherwise the content is fetched again, into
    /// a folder of its own beside it.
    public func originalAttachmentFile(_ index: Int, of id: Message.ID) async -> URL? {
        await attachmentFile(index, of: id, original: true)
    }

    private func attachmentFile(_ index: Int, of id: Message.ID, original: Bool) async -> URL? {
        guard let m = message(id), m.attachments.indices.contains(index) else { return nil }
        let a = m.attachments[index]
        // A folder per position: two attachments may have the same name.
        let folder = downloadsFolder.appendingPathComponent(id.uuidString).appendingPathComponent("\(index)")
        var url = folder.appendingPathComponent(a.fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            if !original || isUnchanged(url) { return url }
            url = folder.appendingPathComponent("Original").appendingPathComponent(a.fileName)
            if isUnchanged(url) { return url }
        }
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
            writtenFiles[url] = FileStamp(url)
            return url
        } catch {
            if !Self.wasCancelled(error), !pauseIfSignInFailed(error, account: m.accountID) {
                status = "Couldn't open “\(a.name)”: \(error.localizedDescription)"
            }
            return nil
        }
    }

    /// Whether `url` is a file this store wrote and nothing has changed since.
    private func isUnchanged(_ url: URL) -> Bool {
        guard let written = writtenFiles[url] else { return false }
        return FileStamp(url) == written
    }

    /// Copies the attachment into `folder` without replacing anything there ("name 2.pdf", as in the Finder).
    public func saveAttachment(_ index: Int, of id: Message.ID, to folder: URL) async -> URL? {
        guard let file = await originalAttachmentFile(index, of: id) else { return nil }
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

    /// Quick Look over all of the message's attachments, starting at `index` (nil: the first that loads). When the
    /// chosen one can't be had, no other file is shown in its place; the status says why. A Quick Look asked for
    /// later wins: an earlier one whose files arrive after it changes nothing.
    public func quickLookAttachments(of id: Message.ID, at index: Int? = nil) async {
        quickLookRequest &+= 1
        let request = quickLookRequest
        var files: [URL] = [], front: URL?
        for i in message(id)?.attachments.indices ?? 0..<0 {
            guard let url = await attachmentFile(i, of: id) else { continue }
            files.append(url)
            if i == index { front = url }
        }
        guard request == quickLookRequest else { return }
        previewItems = files
        previewItem = index == nil ? files.first : front
    }

    static func freeURL(for name: String, in folder: URL) -> URL {
        let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
        var url = folder.appendingPathComponent(name), n = 2
        // The item itself, not what a link points to: a broken link or alias also takes the name.
        while (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil {
            url = folder.appendingPathComponent(Attachment.fileName(base, ending: ext.isEmpty ? " \(n)" : " \(n).\(ext)"))
            n += 1
        }
        return url
    }

    /// For sample data and tests: a day of made-up calendar entries next to an invite.
    public func setDayEvents(_ events: [CalendarEvent], for id: Message.ID) { dayEvents[id] = events; unavailableDays.remove(id) }

    /// The view that asked has moved on (another message was selected, the window closed): its task was cancelled,
    /// and URLSession reports that as an error. Nothing failed, so nothing is reported.
    static func wasCancelled(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// Fetches the body of a server message the first time it is shown. If the server's version of the message changed
    /// while the body was on its way (another preview: a draft edited elsewhere), that body is the old version's: it is
    /// asked for again, up to three times.
    public func loadBody(_ id: Message.ID) async {
        for _ in 0..<3 {
            guard let m = message(id), m.needsBody, let rid = m.remoteID, let backend = backends[m.accountID],
                  !paused.contains(m.accountID) else { return }
            do {
                let b = try await backend.body(remoteID: rid)
                guard let now = message(id), now.serverPreview == m.serverPreview else { continue }
                setBody(b, for: id)
                return
            } catch {
                if !Self.wasCancelled(error), !pauseIfSignInFailed(error, account: m.accountID) { status = "Couldn't load message: \(error.localizedDescription)" }
                return
            }
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
        // The roles are read again after each folder: a mailbox selected while the check runs is checked by it,
        // before it ends (a second check asked for meanwhile returns at once).
        var checked: [UUID: Set<MailboxKind>] = [:]
        func next(_ acct: UUID) -> MailboxKind? { quickCheckRoles(acct).first { !checked[acct, default: []].contains($0) } }
        repeat {
            for (acct, backend) in backends where !paused.contains(acct) && next(acct) != nil {
                do {
                    if remoteFolders[acct] == nil { setRemoteFolders(try await backend.folders(), account: acct) }
                    while let role = next(acct) {
                        checked[acct, default: []].insert(role)
                        guard let folder = remoteFolders[acct]?.first(where: { $0.role == role }) else { continue }
                        if isComplete(acct, role) {
                            do {
                                var more = true
                                while more {
                                    let asked = requestStamp, sent = syncToken(acct, role)
                                    let r = try await backend.sync(folder, token: sent)
                                    apply(r, account: acct, mailbox: role, asked: asked)
                                    more = r.more
                                    if more && r.token == sent { throw SamePageAgain() }
                                }
                            } catch is SyncTokenRejected {
                                resetSync(acct, role)
                            }
                        } else {
                            let asked = requestStamp
                            let newest = try await backend.newest(in: folder, limit: Self.firstScreen)
                            merge(newest, account: acct, mailbox: role, asked: asked)
                        }
                    }
                    // Only this account's own connection notice goes; another account's or "Couldn't send" stays.
                    if let notice = connectionNotices.removeValue(forKey: acct), status == notice { status = historyError }
                } catch where pauseIfSignInFailed(error, account: acct) {
                    checked[acct, default: []].formUnion(quickCheckRoles(acct))
                } catch {
                    checked[acct, default: []].formUnion(quickCheckRoles(acct))
                    connectionNotice("\(account(acct)?.name ?? "Account"): \(error.localizedDescription)", account: acct)
                }
            }
        } while backends.keys.contains { !paused.contains($0) && next($0) != nil }
        if history { startHistory() }
    }

    /// A server that answers "more" without moving its sync position on would be asked for the same page forever.
    struct SamePageAgain: LocalizedError {
        var errorDescription: String? { "The server sent the same page again" }
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
    /// so switching mailboxes takes effect within moments. A failing folder doesn't stop the others; an account
    /// whose server can't be reached (or asks to wait) waits for the next check, while the other accounts go on.
    public func syncHistory() async {
        defer { progress = nil }
        var unreachable = Set<UUID>()
        for (acct, backend) in backends where !paused.contains(acct) {
            var fetched: [(MailboxKind, [Message])] = [], since = ContinuousClock.now
            var asked = requestStamp  // when the batch's first answer was requested
            func show() {
                merge(fetched, account: acct, asked: asked)
                for (role, _) in fetched { newestLoaded.insert(key(acct, role)) }
                fetched = []; since = .now; asked = requestStamp
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
        while let (acct, backend, folder) = nextHistoryFolder(skipping: unreachable) {
            showHistoryProgress(acct)
            var pages: [SyncResult] = []
            let asked = requestStamp
            // Whatever arrived is shown, also when a page fails; in one merge.
            defer { apply(pages, account: acct, mailbox: folder.role, asked: asked) }
            do {
                var token = syncToken(acct, folder.role)
                let start = ContinuousClock.now
                repeat {
                    let r = try await backend.sync(folder, token: token)
                    pages.append(r)
                    if r.more && r.token == token { throw SamePageAgain() }
                    token = r.token
                } while pages.last?.more == true && start.duration(to: .now) < Self.historyBatch
            } catch where pauseIfSignInFailed(error, account: acct) {
            } catch is SyncTokenRejected {
                pages = []  // the pass starts over; nothing of the old one is applied
                resetSync(acct, folder.role)
            } catch where error is URLError || (error as? ServerBusy)?.retryAfter != nil {
                // Unreachable or throttled: the account waits for the next run. A page that isn't an Exchange
                // answer (no back-off) counts as this folder's failure below, so it can't hold up the others.
                unreachable.insert(acct)
            } catch {
                historyFailed.insert(key(acct, folder.role))
                historyError = "\(name(of: folder.role, in: acct)): \(error.localizedDescription)"
                status = historyError
            }
        }
        progress = nil
        // History is done: bring the complete folders that aren't on screen up to date (one small request each).
        for (acct, backend) in backends where !paused.contains(acct) && !unreachable.contains(acct) {
            for role in backgroundDeltaRoles(acct, (remoteFolders[acct] ?? []).map(\.role)) {
                guard let folder = remoteFolders[acct]?.first(where: { $0.role == role }) else { continue }
                do {
                    var more = true
                    while more {
                        let asked = requestStamp, sent = syncToken(acct, role)
                        let r = try await backend.sync(folder, token: sent)
                        apply(r, account: acct, mailbox: role, asked: asked)
                        more = r.more
                        if more && r.token == sent { throw SamePageAgain() }
                    }
                } catch is SyncTokenRejected {
                    resetSync(acct, role)  // synced from the start by the next history run
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

    private func nextHistoryFolder(skipping unreachable: Set<UUID>) -> (UUID, any MailBackend, RemoteFolder)? {
        for acct in accounts.map(\.id) where !unreachable.contains(acct) {
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
        // A prefix of the same kind already there (any case, with or without a space; AW:/WG: from German
        // Outlook) is replaced by the standard one rather than stacked.
        let (prefix, existing) = kind == .forward ? ("Fwd: ", /^(?i:fwd|fw|wg): ?/) : ("Re: ", /^(?i:re|aw): ?/)
        let subject = prefix + m.subject.replacing(existing, with: "", maxReplacements: 1)
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        // Any line ending: Exchange bodies use CRLF, which is one Character in Swift, not "\n".
        let quoted = m.body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { "> \($0)" }
            .joined(separator: "\n")
        // A summary not loaded yet has names without addresses: no empty "<>".
        let sender = m.from.formatted
        // As Mail's forwarded-message block: who it went to, and the time with seconds and zone (for readers elsewhere).
        let fdf = DateFormatter(); fdf.dateStyle = .long; fdf.timeStyle = .long
        let recipients = [("To", m.to), ("Cc", m.cc)].filter { !$0.1.isEmpty }
            .map { "\($0.0): \($0.1.map(\.formatted).joined(separator: ", "))\n" }.joined()
        let header = kind == .forward
            ? "\n\nBegin forwarded message:\n\nFrom: \(sender)\nSubject: \(m.subject)\nDate: \(fdf.string(from: m.date))\n"
                + recipients + "\n"
            : "\n\nOn \(df.string(from: m.date)), \(sender) wrote:\n\n"
        // Each address once, whatever its case, and never my own; the first occurrence is kept. A recipient
        // without an address ("Undisclosed recipients") is left out.
        var seen: Set<String> = me.map { [$0.lowercased()] } ?? []
        func addresses(_ cs: [Contact]) -> String {
            cs.map(\.email).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.joined(separator: ", ")
        }
        var to = "", cc = ""
        switch kind {
        case .reply:
            // Replying to my own message (from Sent, or in a conversation) goes to its recipients, as in Mail.
            // A note only to myself still goes to me.
            let recipients = m.from.email.lowercased() == me?.lowercased() ? addresses(m.to) : ""
            to = recipients.isEmpty ? m.from.email : recipients
        case .replyAll:
            to = addresses([m.from] + m.to)
            cc = addresses(m.cc)
        case .forward: break
        }
        var d = Draft(accountID: m.accountID, to: to, cc: cc, subject: subject, body: header + quoted)
        if m.hasAttachments || !m.attachments.isEmpty {
            d.original = id
            // Forward always takes them along; a reply only with Include Attachments With Replies ▸ Always.
            if kind == .forward || includeAttachments == .always { d.loadingOriginal = id }
        }
        return d
    }

    /// A reply or forward of a message whose body was never loaded (only the list summary: names without
    /// addresses, no text): the body is fetched first, so the draft has the addresses and the quote.
    public func loadedDraft(_ kind: ReplyKind, to id: Message.ID, includeAttachments: IncludeAttachments = .never) async -> Draft {
        if message(id)?.needsBody == true { await loadBody(id) }
        return draft(kind, to: id, includeAttachments: includeAttachments)
    }

    /// Include Attachments With Replies ▸ When Adding Recipients: the reply now goes to someone who
    /// wasn't on the original message.
    public func addsNewRecipient(_ d: Draft) -> Bool {
        guard let id = d.original, let m = message(id) else { return false }
        let original = [m.from] + m.to + m.cc
        var known = Set(original.map { $0.email.lowercased() })
        if let me = account(m.accountID)?.address { known.insert(me.lowercased()) }
        // Before its body is loaded, the original has names without addresses: a recipient of that name is known.
        let names = Set(original.filter(\.email.isEmpty).map { $0.name.lowercased() }).subtracting([""])
        return (Contact.parseList(d.to) + Contact.parseList(d.cc))
            .contains { $0.email.contains("@") && !known.contains($0.email.lowercased()) && !names.contains($0.name.lowercased()) }
    }

    /// Adds files to a draft. A folder (or package) goes as a zip archive of it, made the way the Finder
    /// compresses. Unreadable items are left out, with a note in `status`.
    public func attach(_ urls: [URL], to draft: inout Draft) { draft.attachments += files(urls) }

    /// The files to attach: a folder as a zip of it. Reports the ones that can't be read.
    public func files(_ urls: [URL]) -> [DraftAttachment] {
        var files: [DraftAttachment] = [], skipped: [String] = []
        for var url in urls {
            // A Finder alias (bookmark data, not a symbolic link) stands for its original: that file or folder is
            // attached, under its own name.
            let kind = try? url.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey])
            if kind?.isAliasFile == true, kind?.isSymbolicLink != true {
                // One whose original is gone can't be attached: its bytes mean nothing to the recipient.
                guard let original = try? URL(resolvingAliasFileAt: url) else { skipped.append(url.lastPathComponent); continue }
                url = original
            }
            // A symbolic link to a folder goes as the folder, under the link's name, as the Finder does.
            let target = url.resolvingSymlinksInPath()
            let isFolder = (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isFolder {
                guard let zip = Self.zipped(target) else { skipped.append(url.lastPathComponent); continue }
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
    /// server if needed, as in Mail. All or none: if the original or one of its files can't be had, nothing is
    /// added, `loadingOriginal` stays set (the message can't be sent or saved without them by accident) and
    /// `status` says which; the compose window offers to try again or to go on without them.
    public func includeOriginalAttachments(in draft: inout Draft) async {
        guard let id = draft.loadingOriginal, let m = message(id) else { draft.loadingOriginal = nil; return }
        if m.needsBody { await loadBody(id) }
        if Task.isCancelled { return }  // the compose window was closed: nothing to report
        guard let loaded = message(id), loaded.bodyLoaded, !(loaded.hasAttachments && loaded.attachments.isEmpty) else {
            status = "Couldn't add the original attachments: the original message couldn't be loaded."
            return
        }
        var files: [DraftAttachment] = [], missing: [String] = []
        for (i, a) in loaded.attachments.enumerated() {
            guard let url = await originalAttachmentFile(i, of: id), let data = try? Data(contentsOf: url) else {
                missing.append(a.name)
                continue
            }
            files.append(DraftAttachment(
                name: a.name, contentType: a.contentType ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType,
                data: data, fromOriginal: true))
        }
        guard missing.isEmpty else {
            if Task.isCancelled { return }
            status = "Couldn't add the original attachments: \(missing.map { "“\($0)”" }.joined(separator: ", ")) couldn't be loaded."
            return
        }
        draft.attachments += files
        draft.loadingOriginal = nil
    }

    /// An invite answer "with comments" as a message, like Outlook's: to the organizer, with the subject
    /// Exchange gives it. Proposing starts from the meeting's own time.
    public func answerDraft(_ r: InviteResponse, to id: Message.ID, proposing: Bool = false) -> Draft {
        guard let m = message(id), let invite = m.invite else { return Draft(accountID: accounts[0].id) }
        return Draft(accountID: m.accountID, to: Self.organizer(invite), subject: Self.answerSubject(r, proposing: proposing, m.subject),
                     inviteAnswer: InviteAnswer(messageID: id, response: r, proposedStart: proposing ? invite.start : nil,
                                                proposedEnd: proposing ? invite.end : nil))
    }

    /// "Accepted: …", "Tentative: …", "Declined: …" or "New Time Proposed: …", as Exchange titles the answer.
    static func answerSubject(_ r: InviteResponse, proposing: Bool, _ subject: String) -> String {
        let answered = switch r {
        case .accept: "Accepted"
        case .tentative: "Tentative"
        case .decline: "Declined"
        }
        return "\(proposing ? "New Time Proposed" : answered): \(subject)"
    }

    static func organizer(_ invite: Invite) -> String {
        invite.organizer?.formatted ?? ""
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

    /// The account the draft is written from. Never another one: a draft whose account was removed meanwhile
    /// (sample accounts go when signing in) waits for the user to choose one in From.
    private func sendingAccount(_ d: Draft) -> Account? {
        if let a = account(d.accountID) { return a }
        status = "“\(d.subject)” was written from an account that is no longer set up. Choose another one in From."
        return nil
    }

    /// Sends the draft (queued for the server, or added to Sent without one). False when it can't go out: the
    /// caller keeps the message window open, and `status` says why.
    @discardableResult
    public func send(_ d: Draft) -> Bool {
        if attachmentsPending(d) { return false }
        if let a = d.inviteAnswer {
            // The invite left meanwhile (answered elsewhere, erased): the window keeps the comment.
            guard message(a.messageID)?.invite != nil else {
                status = "Couldn't send “\(d.subject)”: the invitation is no longer in your mailbox."
                return false
            }
            let text = d.text.trimmingCharacters(in: .whitespacesAndNewlines)
            respond(InviteReply(response: a.response, comment: text.isEmpty ? nil : text,
                                proposedStart: a.proposedStart, proposedEnd: a.proposedEnd), to: a.messageID)
            return true
        }
        guard let acct = sendingAccount(d) else { return false }
        // An Exchange account is one also before it has stored anything, and while it has no password.
        if serverAccounts.contains(acct.id) || acct.isServer {
            outbox.append(PendingChange(account: acct.id, change: .send(d), previous: []))
            if backends[acct.id] == nil {
                status = "“\(d.subject.isEmpty ? "(No Subject)" : d.subject)” waits in the outbox until “\(acct.name)” "
                    + "is signed in again in Settings ▸ Accounts."
            }
            scheduleFlush()
            return true
        }
        let m = Message(accountID: acct.id, mailbox: .sent, from: Contact(name: acct.name, email: acct.address),
                        to: Contact.parseList(d.to), cc: Contact.parseList(d.cc),
                        subject: d.subject.isEmpty ? "(No Subject)" : d.subject,
                        body: d.text, date: .now, isRead: true, attachments: d.attachments.map(\.attachment))
        add(m)
        if !d.attachments.isEmpty { setAttachmentData(d.attachments.map(\.data), for: m.id) }
        return true
    }

    /// Saves the draft, in Drafts or queued for the server. False (and nothing kept) while a forward's original
    /// files are still loading: the caller keeps the message open and saves once they are in.
    @discardableResult
    public func saveDraft(_ d: Draft) -> Bool {
        if attachmentsPending(d) { return false }
        guard let acct = sendingAccount(d) else { return false }
        if serverAccounts.contains(acct.id) || acct.isServer {
            outbox.append(PendingChange(account: acct.id, change: .saveDraft(d), previous: []))
            scheduleFlush()
            return true
        }
        let m = Message(accountID: acct.id, mailbox: .drafts, from: Contact(name: acct.name, email: acct.address),
                        to: Contact.parseList(d.to), cc: Contact.parseList(d.cc),
                        subject: d.subject.isEmpty ? "(No Subject)" : d.subject,
                        body: d.text, date: .now, isRead: true, attachments: d.attachments.map(\.attachment))
        add(m)
        if !d.attachments.isEmpty { setAttachmentData(d.attachments.map(\.data), for: m.id) }
        return true
    }
}

struct MailError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}
