import Foundation
import Testing
@testable import MailModel

/// A mailbox the size of a real work account (≈70k messages, mostly Sent and Trash), made up.
/// Each redraw runs `visibleMessages` and every sidebar count, so they must stay well under a frame budget.
@MainActor
struct MailStorePerformanceTests {
    let work = Account(name: "Work", address: "me@work.com")
    /// Debug build on a machine that may be busy (virus scanner, builds). Well above the typical 0.01–0.06s,
    /// well below the 0.8s per redraw the uncached sidebar counts took.
    static let limit = 0.25

    func bigStore() -> MailStore {
        let boxes: [(MailboxKind, Int)] = [(.inbox, 2_900), (.drafts, 300), (.sent, 54_000), (.trash, 11_800), (.archive, 30)]
        var msgs: [Message] = []
        msgs.reserveCapacity(70_000)
        var n = 0
        for (box, count) in boxes {
            for _ in 0..<count {
                n += 1
                msgs.append(Message(accountID: work.id, mailbox: box, from: Contact(name: "S\(n % 500)", email: "s\(n % 500)@x.com"),
                                    to: [], subject: "Subject \(n)", body: "", date: Date(timeIntervalSince1970: Double(n * 60)),
                                    isRead: n % 30 != 0, remoteID: "R\(n)", serverPreview: "Preview \(n)", bodyLoaded: false))
            }
        }
        return MailStore(accounts: [work], messages: msgs)
    }

    /// Best of three fresh runs: the machine may be busy, and the minimum is what the code costs.
    func seconds(_ f: (MailStore) -> Void) -> Double {
        (0..<3).map { _ in
            let s = bigStore()
            let start = Date()
            f(s)
            return Date().timeIntervalSince(start)
        }.min()!
    }

    @Test func listAndSidebarStayFastAt70kMessages() {
        let list = seconds { s in s.selectedMailbox = .account(work.id, .inbox); _ = s.visibleMessages }
        let sent = seconds { s in s.selectedMailbox = .account(work.id, .sent); _ = s.visibleMessages }
        let refs: [MailboxRef] = [.smart(.allInboxes), .smart(.vip), .smart(.flagged), .smart(.unread)]
            + MailboxKind.allCases.map { .account(work.id, $0) }
        let sidebar = seconds { s in for r in refs { _ = s.unreadCount(r); _ = s.count(r) } }
        print(String(format: "PERF inbox list %.3fs, sent list %.3fs, sidebar %.3fs", list, sent, sidebar))
        #expect(list < Self.limit)
        #expect(sent < Self.limit)
        #expect(sidebar < Self.limit)
    }

    /// Memory search (before the index is ready) folds every message's fields once per query. About 0.17s here;
    /// the limit is ten times that, so a busy machine doesn't fail it.
    @Test func memorySearchStaysFastAt70kMessages() {
        let t = seconds { s in s.searchText = "subject 4"; _ = s.visibleMessages }
        print(String(format: "PERF memory search 70k %.3fs", t))
        #expect(t < 2.0)
    }

    @Test func mergingASyncPageStaysFastAt70kMessages() {
        let page = (0..<512).map { i in
            Message(accountID: work.id, from: Contact(name: "N", email: "n@x.com"), to: [], subject: "New \(i)", body: "",
                    date: .now, remoteID: "NEW\(i)", bodyLoaded: false)
        }
        let t = seconds { s in s.apply(SyncResult(upserts: page, deletedRemoteIDs: [], token: "t", more: true), account: work.id, mailbox: .sent) }
        print(String(format: "PERF merge 512 into 70k %.3fs", t))
        #expect(t < Self.limit)
    }

    @Test func cacheSaveAndLoadAt70kMessages() throws {
        let s = bigStore()
        s.apply(SyncResult(upserts: [], deletedRemoteIDs: [], token: "t", more: false), account: work.id, mailbox: .inbox)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MailPerf-\(UUID())/cache.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let snapshot = s.cache()
        var start = Date()
        try snapshot.save(to: url)
        let save = Date().timeIntervalSince(start)
        start = Date()
        let loaded = try #require(MailCache.load(from: url))
        let load = Date().timeIntervalSince(start)
        start = Date()
        let fresh = MailStore(accounts: [work], messages: [])
        fresh.restore(loaded)
        let restore = Date().timeIntervalSince(start)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print(String(format: "PERF cache 70k: save %.2fs, load %.2fs, restore %.2fs, %.1f MB", save, load, restore, Double(size) / 1e6))
        #expect(fresh.messages.count == s.messages.count)
    }

    /// Undoing a refused batch of 100 (the outbox batch size) far into the message array (BUG-078).
    @Test func undoingARefusedBatchStaysFastAt70kMessages() {
        let t = (0..<3).map { _ in
            let s = bigStore()
            let ids = Set(s.messages.filter { $0.mailbox == .trash }.suffix(100).map(\.id))
            s.archive(ids)
            let p = s.outbox[0]
            let start = Date()
            s.failed(p, "refused")
            let t = Date().timeIntervalSince(start)
            #expect(s.messages.filter { ids.contains($0.id) }.allSatisfy { $0.mailbox == .trash })
            return t
        }.min()!
        print(String(format: "PERF failed() 100 in 70k %.3fs", t))
        #expect(t < Self.limit)
    }
}
