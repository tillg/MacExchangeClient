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

    func bigStore(times k: Int = 1) -> MailStore {
        let sizes: [(MailboxKind, Int)] = [(.inbox, 2_900), (.drafts, 300), (.sent, 54_000), (.trash, 11_800), (.archive, 30)]
        let boxes = sizes.map { ($0.0, $0.1 * k) }
        var msgs: [Message] = []
        msgs.reserveCapacity(70_000 * k)
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

    /// A redraw reads `selectedMessage` several times (menu items, viewer, detail). For a message that arrived this
    /// session, at the far end of `messages`, each read used to scan them all (BUG-137). 100 reads stay in budget.
    @Test func readingTheSelectedMessageStaysFastAt70kMessages() {
        let arrived = Message(accountID: work.id, from: Contact(name: "New", email: "new@x.com"), to: [], subject: "Just arrived",
                              body: "", date: .now, remoteID: "NEW-1", bodyLoaded: false)
        let t = (0..<3).map { _ in
            let s = bigStore()
            s.apply(SyncResult(upserts: [arrived], deletedRemoteIDs: [], token: "t", more: false), account: work.id, mailbox: .inbox)
            s.selection = [s.messages.last!.id]
            let start = Date()
            for _ in 0..<100 { #expect(s.selectedMessage?.remoteID == "NEW-1") }
            return Date().timeIntervalSince(start)
        }.min()!
        print(String(format: "PERF 100 reads of selectedMessage in 70k %.3fs", t))
        #expect(t < Self.limit)
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

    /// Dropping the selected message on another mailbox at about 210k messages (a real account's size). The drop
    /// runs on the main thread as the mouse is let go; the redraw after it costs as much again, so it must be quick.
    @Test func droppingTheSelectionStaysFastAt210kMessages() {
        let t = (0..<3).map { _ in
            let s = bigStore(times: 3)
            s.selectedMailbox = .account(work.id, .inbox)
            let id = s.visibleMessages[5].id
            s.selection = [id]
            let start = Date()
            #expect(s.drop([id], on: .account(work.id, .archive)))
            return Date().timeIntervalSince(start)
        }.min()!
        print(String(format: "PERF drop 1 of 210k %.3fs", t))
        #expect(t < 0.15)  // about 0.1s, most of it the list the redraw needs anyway; 0.26s before (seven passes)
    }

    /// Exchange's answer to a move renames the moved message; that also runs on the main thread, right after a drop.
    @Test func renamingAMovedMessageStaysFastAt210kMessages() {
        let t = (0..<3).map { _ in
            let s = bigStore(times: 3)
            let start = Date()
            s.renameRemote(["R5": "NEW5"], account: work.id)
            let t = Date().timeIntervalSince(start)
            #expect(s.messages.filter { $0.remoteID == "NEW5" }.count == 1)
            return t
        }.min()!
        print(String(format: "PERF renameRemote 1 in 210k %.3fs", t))
        #expect(t < 0.1)
    }
}
