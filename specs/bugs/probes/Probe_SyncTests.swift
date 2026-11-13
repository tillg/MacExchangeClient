import Foundation
import Testing
@testable import MailModel

/// Round-2 probes for MailStore's sync-state paths (no backend object).
@MainActor
struct Probe_SyncTests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")

    func store(_ msgs: [Message] = []) -> MailStore { MailStore(accounts: [work, home], messages: msgs) }

    /// Like an EWS list summary: no body, recipients as display names only (EWSBackend.message).
    func remote(_ rid: String, subject: String = "Hi", read: Bool = false, minutesAgo: Double = 0,
                flag: FlagColor? = nil) -> Message {
        var m = Message(accountID: work.id, from: Contact(name: "Ann", email: "ann@x.com"),
                        to: [Contact(name: "Me", email: "")], cc: [Contact(name: "Bob", email: "")],
                        subject: subject, body: "", date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60),
                        isRead: read, flag: flag, remoteID: rid, bodyLoaded: false)
        m.serverPreview = "preview"
        return m
    }

    func page(_ ups: [Message] = [], del: [String] = [], reads: [String: Bool] = [:], token: String = "t",
              more: Bool = false) -> SyncResult {
        SyncResult(upserts: ups, deletedRemoteIDs: del, readChanges: reads, token: token, more: more)
    }

    func synced(_ rids: [String], in box: MailboxKind = .inbox) -> MailStore {
        let s = store()
        s.apply(page(rids.map { remote($0) }, token: "t0"), account: work.id, mailbox: box)
        return s
    }

    func id(_ s: MailStore, _ rid: String) -> Message.ID { s.messages.first { $0.remoteID == rid }!.id }

    // MARK: Merging server updates

    /// While a move is on its way, the destination's sync can already list the moved copy under its new ID;
    /// when the move's answer then renames the message, there must be one message, not two.
    @Test func renameOntoAnIDTheSyncAlreadyBroughtDoesNotDuplicate() {
        let s = synced(["A"])
        let a = id(s, "A")
        s.archive([a])
        s.apply(page([remote("A2")], token: "a1"), account: work.id, mailbox: .archive)
        s.renameRemote(["A": "A2"], account: work.id)
        #expect(s.messages.filter { $0.remoteID == "A2" }.count == 1)
        #expect(s.count(.account(work.id, .archive)) == 1)
    }

    /// The Inbox sync says A was deleted (elsewhere) while a local move of A was queued. The move then fails
    /// (the item is gone): A must not stay in the Inbox forever – no later sync will report it again.
    @Test func deletionSeenDuringAPendingMoveIsNotForgotten() {
        let s = synced(["A"])
        let a = id(s, "A")
        s.archive([a])
        s.apply(page(del: ["A"], token: "t1"), account: work.id, mailbox: .inbox)
        s.failed(s.outbox[0], "The specified object was not found in the store.")
        s.apply(page(token: "t2"), account: work.id, mailbox: .inbox)
        #expect(s.message(a) == nil, "deleted on the server but shown in \(s.message(a)?.mailbox.rawValue ?? "-")")
    }

    /// A message deleted elsewhere: its queued read/flag changes can't be written any more and must leave the outbox
    /// (else they are sent, refused, and show "Exchange refused a change").
    @Test func serverDeletionDropsTheMessagesQueuedChanges() {
        let s = synced(["A", "B"])
        s.toggleRead([id(s, "A")])
        s.setFlag(.red, for: [id(s, "A"), id(s, "B")])
        s.apply(page(del: ["A"], token: "t1"), account: work.id, mailbox: .inbox)
        #expect(s.message(id(s, "B")) != nil)
        let ids = s.outbox.flatMap(\.change.remoteIDs)
        #expect(!ids.contains("A"), "outbox still has \(s.outbox.map(\.change))")
    }

    /// A queued read change must not swallow an unrelated flag change from the server.
    @Test func pendingReadChangeKeepsTheServersFlag() {
        let s = synced(["A"])
        let a = id(s, "A")
        s.toggleRead([a])  // queued: setRead true
        s.apply(page([remote("A", flag: .red)], token: "t1"), account: work.id, mailbox: .inbox)
        #expect(s.message(a)?.isRead == true)
        #expect(s.message(a)?.flag != nil, "flagged on the phone, lost here")
    }

    /// A queued flag change must not swallow a read change from the server.
    @Test func pendingFlagChangeKeepsTheServersReadState() {
        let s = synced(["A"])
        let a = id(s, "A")
        s.setFlag(.red, for: [a])
        s.apply(page(reads: ["A": true], token: "t1"), account: work.id, mailbox: .inbox)
        #expect(s.message(a)?.isRead == true, "read on the phone, still unread here")
    }

    // MARK: Folders

    /// A folder removed on the server: its mail must not linger in Flagged / search.
    @Test func mailOfARemovedServerFolderIsDropped() {
        let s = store()
        let x = MailboxKind.folder("X")
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "i"), RemoteFolder(role: x, id: "X", name: "Projects")],
                           account: work.id)
        s.apply(page([remote("A", subject: "Quarterly plan", flag: .red)], token: "x1"), account: work.id, mailbox: x)
        #expect(s.count(.smart(.flagged)) == 1)
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "i")], account: work.id)
        #expect(s.children(of: nil, account: work.id).isEmpty)
        #expect(s.count(.smart(.flagged)) == 0, "flagged mail of a deleted folder")
        s.searchText = "quarterly"
        #expect(s.visibleMessages.isEmpty, "search finds mail of a deleted folder")
    }

    // MARK: Status messages

    @Test func failedSaveDraftDoesNotSayCouldntSend() {
        let s = synced([])
        s.saveDraft(Draft(accountID: work.id, to: "ann@x.com", subject: "Plan", body: "B"))
        s.failed(s.outbox[0], "Quota exceeded")
        #expect(s.status?.contains("send") == false, "status: \(s.status ?? "")")
        s.saveDraft(Draft(accountID: work.id, to: "ann@x.com", subject: "", body: "B"))
        s.failed(s.outbox[0], "Quota exceeded")
        #expect(s.status?.contains("“”") == false, "status: \(s.status ?? "")")
    }

    // MARK: Idempotence / paging

    @Test func applyingTheSameSyncTwiceChangesNothing() {
        let s = synced(["A", "B"])
        let r = page([remote("A", subject: "new", read: true), remote("C")], del: ["B"], reads: ["A": true], token: "t1")
        s.apply(r, account: work.id, mailbox: .inbox)
        _ = s.takeChanges()
        let before = s.messages
        let rev = s.changeCount
        s.apply(r, account: work.id, mailbox: .inbox)
        #expect(s.messages == before)
        #expect(s.changeCount == rev)
        let c = s.takeChanges().resolved()
        #expect(c.upserts.isEmpty && c.removed.isEmpty)
    }

    /// A pending move must not swallow a read change from the server either.
    @Test func pendingMoveKeepsTheServersReadState() {
        let s = synced(["A"])
        let a = id(s, "A")
        s.archive([a])
        s.apply(page(reads: ["A": true], token: "t1"), account: work.id, mailbox: .inbox)
        #expect(s.message(a)?.mailbox == .archive)
        #expect(s.message(a)?.isRead == true, "read on the phone, still unread here")
    }

    /// Launch: a move made offline last session is still queued; the moved message sits in Archive on disk
    /// (not loaded yet). The quick check of the Inbox reports a change of it (read on the phone). After loading,
    /// there must be one message, not one in the Inbox and one in the Archive.
    @Test func quickCheckDuringLaunchDoesNotDuplicateAMessageMovedOfflineLastSession() {
        var moved = remote("A"); moved.accountID = work.id; moved.mailbox = .archive
        var inboxMsg = remote("B"); inboxMsg.accountID = work.id
        let s = store()
        var meta = StoredMeta()
        meta.sync = [SyncState(account: work.id, mailbox: .inbox, token: "t0", complete: true)]
        meta.outbox = [PendingChange(account: work.id, change: .move(["A"], to: .archive), previous: [remote("A")])]
        s.restore(meta)
        s.restore([inboxMsg], boxes: [MailboxKey(account: work.id, mailbox: .inbox)])
        #expect(s.quickCheckRoles(work.id) == [.inbox])
        s.apply(page([remote("A", read: true)], token: "t1"), account: work.id, mailbox: .inbox)
        s.finishLoading([moved])
        #expect(s.messages.filter { $0.remoteID == "A" }.count == 1, "boxes: \(s.messages.filter { $0.remoteID == "A" }.map(\.mailbox.rawValue))")
    }

    /// The existing test severalPagesApplyLikeOneAfterTheOther feeds delete-A-then-upsert-A across pages.
    /// Applied in one batch, the message keeps its local ID, selection and loaded body; one by one, it doesn't.
    @Test func batchedDeleteThenReupsertMatchesOneByOne() {
        func run(batch: Bool) -> (sameID: Bool, selected: Bool, body: String?) {
            let s = synced(["A"])
            let a = id(s, "A")
            s.selection = [a]
            s.setBody(MessageBody(text: "Full", attachments: []), for: a)
            let pages = [page(del: ["A"], token: "p1", more: true), page([remote("A", subject: "Back")], token: "p2")]
            if batch { s.apply(pages, account: work.id, mailbox: .inbox) } else { for p in pages { s.apply(p, account: work.id, mailbox: .inbox) } }
            let m = s.messages.first { $0.remoteID == "A" }
            return (m?.id == a, s.selection == [a], m?.body)
        }
        let b = run(batch: true), q = run(batch: false)
        #expect(b.sameID == q.sameID && b.selected == q.selected && b.body == q.body, "batch \(b) vs one by one \(q)")
    }

    /// Folder removed on the server while it is the selected mailbox: the title goes blank.
    @Test func selectedRemovedFolderKeepsATitle() {
        let s = store()
        let x = MailboxKind.folder("X")
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "i"), RemoteFolder(role: x, id: "X", name: "Projects")], account: work.id)
        s.selectedMailbox = .account(work.id, x)
        #expect(s.title == "Projects")
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "i")], account: work.id)  // next launch: folder gone
        #expect(s.title != "", "blank title, selection \(s.selectedMailbox)")
    }

    @Test func outboxBatchesAt100And101WithMixedChanges() {
        let s = synced((0..<101).map { "R\($0)" })
        let ids = Set(s.messages.filter { $0.remoteID != nil }.map(\.id))
        s.drop(ids, on: .account(work.id, .archive))
        #expect(s.outbox.map(\.change.remoteIDs.count) == [100, 1])
        s.setFlag(.red, for: Set(s.messages.filter { $0.remoteID != nil }.prefix(100).map(\.id)))
        #expect(s.outbox.count == 3)
        #expect(Set(s.outbox.flatMap(\.change.remoteIDs)).count == 101)
    }

    @Test func historyFractionStaysWithinZeroAndOne() {
        let s = synced((0..<30).map { "R\($0)" })
        let folders = [RemoteFolder(role: .inbox, id: "i", totalCount: 10), RemoteFolder(role: .sent, id: "s", totalCount: 0),
                       RemoteFolder(role: .archive, id: "a", totalCount: 5)]
        let f = s.historyFraction(work.id, folders)
        #expect(f >= 0 && f <= 1)
    }

    /// Everything written through takeChanges() must add up to storedState() (what a new database gets).
    @Test func writtenChangesAddUpToTheStoredStateOverRandomOps() {
        var failures: [String] = []
        for seed in 0..<200 {
            var g = RNG(state: UInt64(seed) &* 104_729 &+ 11)
            let s = synced(["R0", "R1", "R2", "R3"])
            var disk: [UUID: Message] = [:], sync: [String: SyncState] = [:], outbox: [PendingChange] = []
            var log: [String] = [], next = 4
            func write(_ c: StoreChanges) {
                for m in c.upserts { disk[m.id] = m }
                for r in c.removed { disk[r] = nil }
                if let st = c.sync { sync = [:]; for x in st { sync["\(x.account)/\(x.mailbox.rawValue)"] = x } }
                if let o = c.outbox { outbox = o }
            }
            for step in 0..<30 {
                let live = s.messages.filter { $0.remoteID != nil }
                switch Int.random(in: 0..<9, using: &g) {
                case 0:
                    let box: MailboxKind = [.inbox, .archive, .trash].randomElement(using: &g)!
                    var ups: [Message] = [], del: [String] = []
                    for m in live where m.mailbox == box && Bool.random(using: &g) {
                        if Bool.random(using: &g) { ups.append(remote(m.remoteID!, read: Bool.random(using: &g))) } else { del.append(m.remoteID!) }
                    }
                    if Bool.random(using: &g) { ups.append(remote("R\(next)")); next += 1 }
                    s.apply(page(ups, del: del, token: "t\(step)", more: Bool.random(using: &g)), account: work.id, mailbox: box)
                    log.append("apply \(box.rawValue) +\(ups.map { $0.remoteID! }) -\(del)")
                case 1: if let m = live.randomElement(using: &g) { s.toggleRead([m.id]); log.append("read \(m.remoteID!)") }
                case 2: if let m = live.randomElement(using: &g) { s.archive([m.id]); log.append("archive \(m.remoteID!)") }
                case 3: if let m = live.randomElement(using: &g) { s.delete([m.id]); log.append("delete \(m.remoteID!)") }
                case 4: if let p = s.outbox.randomElement(using: &g) { s.failed(p, "x"); log.append("failed \(p.change)") }
                case 5:
                    if let m = live.randomElement(using: &g) {
                        s.renameRemote([m.remoteID!: "R\(next)"], account: work.id); next += 1; log.append("rename \(m.remoteID!)")
                    }
                case 6: write(s.takeChanges().resolved()); log.append("write")
                case 7: s.retry(s.takeChanges()); log.append("write failed → retry")
                default: if let m = live.randomElement(using: &g) { s.setBody(MessageBody(text: "b", attachments: []), for: m.id); log.append("body \(m.remoteID!)") }
                }
            }
            write(s.takeChanges().resolved())
            let full = s.storedState()
            let want = Dictionary(uniqueKeysWithValues: full.upserts.map { ($0.id, $0) })
            var wantSync: [String: SyncState] = [:]
            for x in full.sync ?? [] { wantSync["\(x.account)/\(x.mailbox.rawValue)"] = x }
            if disk != want || sync != wantSync || outbox != (full.outbox ?? []) {
                let extra = Set(disk.keys).subtracting(want.keys).compactMap { disk[$0]?.remoteID }
                let missing = Set(want.keys).subtracting(disk.keys).compactMap { want[$0]?.remoteID }
                let stale = want.keys.filter { disk[$0] != nil && disk[$0] != want[$0] }.compactMap { want[$0]?.remoteID }
                failures.append("seed \(seed): extra \(extra) missing \(missing) stale \(stale) sync \(sync == wantSync) outbox \(outbox == (full.outbox ?? [])) :: \(log.joined(separator: "; "))")
            }
        }
        #expect(failures.isEmpty, "\(failures.count) seeds; shortest: \(failures.min { $0.count < $1.count } ?? "")")
    }

    /// A refresh that runs before launch has restored the database (the user clicks a mailbox while
    /// "Loading Mail…"; SidebarView refreshes on every selection change) merges the newest Inbox mail under new
    /// local IDs; restoring the stored Inbox then adds the same server messages again, and the stored
    /// (older) sync position replaces the one just fetched.
    @Test func refreshBeforeLaunchRestoreDoesNotDuplicateTheInbox() {
        let s = store()
        // Stored last session:
        var stored = remote("A"); stored.accountID = work.id
        var meta = StoredMeta()
        meta.sync = [SyncState(account: work.id, mailbox: .sent, token: "old", complete: true)]
        // Early refresh: Inbox not complete in memory yet → newest 50 merged; Sent delta moved on to "new".
        s.merge([remote("A"), remote("B")], account: work.id, mailbox: .inbox)
        s.apply(page(token: "new"), account: work.id, mailbox: .sent)
        // Then launch restores the database.
        s.restore(meta)
        s.restore([stored], boxes: [MailboxKey(account: work.id, mailbox: .inbox)])
        s.finishLoading([])
        #expect(s.messages.filter { $0.remoteID == "A" }.count == 1, "Inbox shows A \(s.messages.filter { $0.remoteID == "A" }.count) times")
        #expect(s.syncToken(work.id, .sent) == "new")
    }

    /// An Exchange account whose password is missing from the Keychain has no backend (AppSetup.connect). Signing
    /// in to a second account calls removeLocalAccounts(), which must drop only the sample data, not that account.
    @Test func signingInAnotherAccountKeepsAnExchangeAccountWithoutPassword() {
        let s = MailStore(accounts: [], messages: [])
        s.accounts.append(work)  // connect() without a password
        var meta = StoredMeta()
        meta.sync = [SyncState(account: work.id, mailbox: .inbox, token: "t", complete: true)]
        s.restore(meta)
        var m = remote("A"); m.accountID = work.id
        s.restore([m], boxes: [MailboxKey(account: work.id, mailbox: .inbox)])
        s.finishLoading([])
        s.send(Draft(accountID: work.id, to: "ann@x.com", subject: "Kept", body: "B"))
        s.failed(s.outbox[0], "Timeout")  // kept in Drafts on this Mac
        #expect(s.messages.contains { $0.subject == "Kept" && $0.remoteID == nil })
        s.removeLocalAccounts()
        #expect(s.accounts.map(\.id) == [work.id], "the Exchange account left the sidebar")
        #expect(s.messages.contains { $0.subject == "Kept" }, "the unsent message kept in Drafts is gone")
    }

    /// The 70k account of MailStorePerformanceTests, limit 0.25 s (its budget).
    func big(_ n: Int = 70_000) -> MailStore {
        var ms: [Message] = []
        ms.reserveCapacity(n)
        for i in 0..<n {
            ms.append(Message(accountID: work.id, mailbox: i < 3000 ? .inbox : .sent, from: Contact(name: "S", email: "s@x.com"),
                              to: [], subject: "Subject \(i)", body: "", date: Date(timeIntervalSince1970: Double(i * 60)),
                              isRead: true, remoteID: "R\(i)", serverPreview: "Preview \(i)", bodyLoaded: false))
        }
        let s = store(ms)
        s.apply(page(token: "t"), account: work.id, mailbox: .inbox)
        return s
    }

    @Test func refusedBatchOf100IsUndoneQuicklyOnABigAccount() {
        let t = (0..<3).map { _ in
            let s = big()
            s.markAllRead(in: .account(work.id, .inbox))  // already read: nothing
            s.archive(Set(s.messages.suffix(100).map(\.id)))
            let p = s.outbox[0]
            let start = Date()
            s.failed(p, "refused")
            return Date().timeIntervalSince(start)
        }.min()!
        print("PERF failed() 100 in 70k: \(Int(t * 1000)) ms")
        #expect(t < 0.25, "\(Int(t * 1000)) ms")
    }

    @Test func renamingAMovedBatchOf100IsQuickOnABigAccount() {
        let t = (0..<3).map { _ in
            let s = big()
            let ids = s.messages.suffix(100)
            let map = Dictionary(uniqueKeysWithValues: ids.map { ($0.remoteID!, $0.remoteID! + "-new") })
            let start = Date()
            s.renameRemote(map, account: work.id)
            return Date().timeIntervalSince(start)
        }.min()!
        print("PERF renameRemote 100 in 70k: \(Int(t * 1000)) ms")
        #expect(t < 0.25, "\(Int(t * 1000)) ms")
    }

    @Test func loadingABodyIsQuickOnABigAccount() {
        let t = (0..<3).map { _ in
            let s = big()
            let id = s.messages[35_000].id
            let start = Date()
            s.setBody(MessageBody(text: "x", attachments: [], from: Contact(name: "A", email: "a@x.com"), to: [], cc: []), for: id)
            return Date().timeIntervalSince(start)
        }.min()!
        print("PERF setBody in 70k: \(Int(t * 1000)) ms")
        #expect(t < 0.25, "\(Int(t * 1000)) ms")
    }

    struct RNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            var z = state; z = (z ^ (z >> 33)) &* 0xff51afd7ed558ccd; z ^= z >> 33
            return z
        }
    }

    struct Snap: Hashable { let rid: String; let box: String; let read: Bool; let flag: Bool; let subject: String }
    func snap(_ s: MailStore) -> [Snap] {
        s.messages.compactMap { m in m.remoteID.map { Snap(rid: $0, box: m.mailbox.rawValue, read: m.isRead, flag: m.flag != nil, subject: m.subject) } }
            .sorted { ($0.rid, $0.box) < ($1.rid, $1.box) }
    }

    /// Pages applied in one batch must give what applying them one after the other gives.
    @Test func batchedPagesEqualSequentialPagesOverRandomSeeds() {
        var failures: [String] = []
        for seed in 0..<400 {
            var g = RNG(state: UInt64(seed) &+ 1)
            let pool = (0..<6).map { "R\($0)" }
            let initial = pool.filter { _ in Bool.random(using: &g) }
            var pages: [SyncResult] = []
            var dead = Set<String>()  // a deleted server ID never comes back
            for p in 0..<Int.random(in: 1...4, using: &g) {
                var ups: [Message] = [], del: [String] = [], reads: [String: Bool] = [:]
                for rid in pool where !dead.contains(rid) {
                    switch Int.random(in: 0..<6, using: &g) {
                    case 0: ups.append(remote(rid, subject: "s\(p)", read: Bool.random(using: &g)))
                    case 1: del.append(rid); dead.insert(rid)
                    case 2: reads[rid] = Bool.random(using: &g)
                    default: break
                    }
                }
                pages.append(page(ups, del: del, reads: reads, token: "p\(p)", more: true))
            }
            let a = synced(initial), b = synced(initial)
            // a local change pending on one message in both
            if let first = initial.first { a.toggleRead([id(a, first)]); b.toggleRead([id(b, first)]) }
            a.apply(pages, account: work.id, mailbox: .inbox)
            for p in pages { b.apply(p, account: work.id, mailbox: .inbox) }
            if snap(a) != snap(b) { failures.append("seed \(seed): batch \(snap(a)) vs seq \(snap(b))") }
        }
        #expect(failures.isEmpty, "\(failures.count) seeds differ; first: \(failures.first ?? "")")
    }

    /// Invariant over random op sequences: one message per server ID.
    @Test func randomSyncAndLocalOpsNeverDuplicateAServerMessage() {
        var failures: [String] = []
        for seed in 0..<300 {
            var g = RNG(state: UInt64(seed) &* 7919 &+ 3)
            let s = synced(["R0", "R1", "R2"])
            var next = 3, log: [String] = []
            let boxes: [MailboxKind] = [.inbox, .archive, .trash]
            for _ in 0..<25 {
                let live = s.messages.filter { $0.remoteID != nil }
                switch Int.random(in: 0..<7, using: &g) {
                case 0:  // server page for a folder
                    let box = boxes.randomElement(using: &g)!
                    var ups: [Message] = [], del: [String] = []
                    for m in live where m.mailbox == box && Bool.random(using: &g) {
                        if Bool.random(using: &g) { ups.append(remote(m.remoteID!, read: Bool.random(using: &g))) } else { del.append(m.remoteID!) }
                    }
                    if Int.random(in: 0..<3, using: &g) == 0 { ups.append(remote("R\(next)")); next += 1 }
                    s.apply(page(ups, del: del, token: "t\(log.count)"), account: work.id, mailbox: box)
                    log.append("apply(\(box.rawValue), ups:\(ups.map { $0.remoteID! }), del:\(del))")
                case 1: if let m = live.randomElement(using: &g) { s.toggleRead([m.id]); log.append("toggleRead \(m.remoteID!)") }
                case 2: if let m = live.randomElement(using: &g) { s.archive([m.id]); log.append("archive \(m.remoteID!)") }
                case 3: if let m = live.randomElement(using: &g) { s.delete([m.id]); log.append("delete \(m.remoteID!)") }
                case 4:  // the oldest queued change succeeds on the server: a move renames
                    if let p = s.outbox.first, case let .move(ids, _) = p.change {
                        var map: [String: String] = [:]
                        for i in ids { map[i] = "R\(next)"; next += 1 }
                        s.renameRemote(map, account: work.id)
                        log.append("rename \(map)")
                    }
                case 5: if let p = s.outbox.randomElement(using: &g) { s.failed(p, "x"); log.append("failed \(p.change)") }
                default: if let m = live.randomElement(using: &g) { s.setFlag(.red, for: [m.id]); log.append("flag \(m.remoteID!)") }
                }
                let rids = s.messages.compactMap(\.remoteID)
                if Set(rids).count != rids.count {
                    failures.append("seed \(seed): \(log.joined(separator: "; "))")
                    break
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.count) seeds; shortest: \(failures.min { $0.count < $1.count } ?? "")")
    }
}
