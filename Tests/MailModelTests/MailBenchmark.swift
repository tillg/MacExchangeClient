import Foundation
import Testing
@testable import MailModel

/// Old (substring scan, no index) against new (FTS5) on a copy of the real database:
/// `MAIL_BENCH=/path/copy.sqlite`, made with `VACUUM INTO`; the copy is changed. Built with `-DBENCH_OLD` in a
/// worktree of the commit before search. Cold: the first run in the process. Warm: median of the repeats.
/// Prints timings and counts only, never mail content.
@MainActor
struct MailBenchmark {
    nonisolated static let path = ProcessInfo.processInfo.environment["MAIL_BENCH"]
    static let words = ["meeting", "rechnung", "projekt", "invoice", "bericht"]

    func time(_ f: () throws -> Void) rethrows -> Double {
        let t = Date(); try f(); return Date().timeIntervalSince(t) * 1000
    }
    func timeAsync(_ f: () async throws -> Void) async rethrows -> Double {
        let t = Date(); try await f(); return Date().timeIntervalSince(t) * 1000
    }
    func report(_ op: String, cold: Double?, warm: [Double]) {
        let w = warm.sorted()
        let median = w.isEmpty ? "–" : String(format: "%.1f", w[w.count / 2])
        print("BENCH | \(op) | \(cold.map { String(format: "%.1f", $0) } ?? "–") | \(median) |")
    }
    func megabytes() -> Double {
        let fm = FileManager.default
        return ["", "-wal"].reduce(0.0) { $0 + Double((try? fm.attributesOfItem(atPath: Self.path! + $1)[.size] as? Int) ?? 0) } / 1e6
    }

    @Test(.enabled(if: path != nil)) func oldAgainstNew() async throws {
        let url = URL(fileURLWithPath: Self.path!)
        // Launch: open, folders and sync positions, the Inboxes; then the rest.
        var db: MailDatabase!, inboxes: [MailboxKey] = [], all: [Message] = []
        func launch() throws {
            db = try MailDatabase(url: url)
            let meta = try db.meta()
            inboxes = Set(meta.sync.map(\.account)).map { MailboxKey(account: $0, mailbox: .inbox) }
            _ = try db.messages(in: inboxes)
        }
        let launchCold = try time(launch)
        var launchWarm: [Double] = []
        for _ in 0..<5 { launchWarm.append(try time(launch)) }
        report("Launch: open + Inbox", cold: launchCold, warm: launchWarm)
        let restCold = try time { all = try db.messages(notIn: inboxes) }
        var restWarm: [Double] = []
        for _ in 0..<3 { restWarm.append(try time { _ = try db.messages(notIn: inboxes) }) }
        report("Launch: load the rest (\(all.count))", cold: restCold, warm: restWarm)
        all = try db.messages()

        #if !BENCH_OLD
        let before = megabytes()
        let migration = try time { try db.prepareSearch() }
        report("One-time index build (\(String(format: "%.0f → %.0f MB", before, megabytes())))", cold: migration, warm: [])
        #else
        report("Database size \(String(format: "%.0f MB", megabytes()))", cold: nil, warm: [])
        #endif

        // Search: main-thread time per keystroke, and the time until the results are there (no debounce).
        let accounts = Set(all.map(\.accountID)).map { Account(id: $0, name: "A", address: "") }
        let store = MailStore(accounts: accounts, messages: all)
        #if !BENCH_OLD
        let index = db!
        store.searcher = { q, a in try index.search(q, accounts: a) }
        store.searchDebounce = .zero
        #endif
        var keyCold: Double?, resultCold: Double?, keyWarm: [Double] = [], resultWarm: [Double] = []
        for round in 0..<3 {
            for word in Self.words {
                store.searchText = ""
                _ = store.visibleMessages
                var key = 0.0
                let result = await timeAsync {
                    key = time { store.searchText = word; _ = store.visibleMessages }
                    #if !BENCH_OLD
                    await store.searchTask?.value
                    _ = store.visibleMessages
                    #endif
                }
                if keyCold == nil { keyCold = key; resultCold = result } else if round > 0 { keyWarm.append(key); resultWarm.append(result) }
            }
        }
        report("Search: main thread per keystroke", cold: keyCold, warm: keyWarm)
        report("Search: results ready (without 150 ms debounce)", cold: resultCold, warm: resultWarm)

        // Deleting a message that is in the results: the list updates.
        var deleteCold: Double?, deleteWarm: [Double] = []
        for word in Self.words {
            store.searchText = word
            #if !BENCH_OLD
            await store.searchTask?.value
            #endif
            guard let first = store.visibleMessages.first else { continue }
            let t = time { store.delete([first.id]); _ = store.visibleMessages }
            if deleteCold == nil { deleteCold = t } else { deleteWarm.append(t) }
        }
        report("Search: delete a result, list updated", cold: deleteCold, warm: deleteWarm)

        // Saving (off the main thread in the app).
        var batch = Array(all.prefix(5_000))
        var newCold: Double?, newWarm: [Double] = [], readCold: Double?, readWarm: [Double] = []
        var flagCold: Double?, flagWarm: [Double] = [], removeCold: Double?, removeWarm: [Double] = []
        for _ in 0..<6 {
            try db.write(StoreChanges(removed: batch.map(\.id)))
            let n = try time { try db.write(StoreChanges(upserts: batch)) }
            for i in batch.indices { batch[i].isRead.toggle() }
            let r = try time { try db.write(StoreChanges(upserts: batch)) }
            batch[0].flag = batch[0].flag == nil ? .red : nil
            let f = try time { try db.write(StoreChanges(upserts: [batch[0]])) }
            let gone = Array(batch.suffix(1_000))
            let d = try time { try db.write(StoreChanges(removed: gone.map(\.id))) }
            try db.write(StoreChanges(upserts: gone))
            if newCold == nil { newCold = n; readCold = r; flagCold = f; removeCold = d } else {
                newWarm.append(n); readWarm.append(r); flagWarm.append(f); removeWarm.append(d)
            }
        }
        report("Save: 5,000 new messages", cold: newCold, warm: newWarm)
        report("Save: 5,000 read changes", cold: readCold, warm: readWarm)
        report("Save: 1 flag change", cold: flagCold, warm: flagWarm)
        report("Save: remove 1,000 messages", cold: removeCold, warm: removeWarm)
    }
}
