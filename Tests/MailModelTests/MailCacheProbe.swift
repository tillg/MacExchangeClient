import Foundation
import SQLite3
import Testing
@testable import MailModel

/// Loads the real cache and prints timings and sizes only, never mail content. Runs only with `MAIL_CACHE_PROBE=1`.
@MainActor
struct MailCacheProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAIL_CACHE_PROBE"] == "1")) func realCacheLoad() throws {
        var t = Date()
        let data = try Data(contentsOf: MailCache.defaultURL)
        let read = Date().timeIntervalSince(t); t = Date()
        let cache = try JSONDecoder().decode(MailCache.self, from: data)
        let decode = Date().timeIntervalSince(t)
        let msgs = cache.accounts.values.flatMap(\.messages)
        let html = msgs.reduce(0) { $0 + ($1.html?.utf8.count ?? 0) }, body = msgs.reduce(0) { $0 + $1.body.utf8.count }
        let store = MailStore(accounts: cache.accounts.keys.map { Account(id: $0, name: "A", address: "") }, messages: [])
        t = Date(); store.restore(cache)
        print(String(format: "CACHEPROBE %.1f MB, read %.2fs, decode %.2fs, restore %.2fs; %d messages, %d with body, html %.1f MB, text %.1f MB",
                     Double(data.count) / 1e6, read, decode, Date().timeIntervalSince(t), msgs.count,
                     msgs.filter(\.bodyLoaded).count, Double(html) / 1e6, Double(body) / 1e6))
        // Per mailbox: standard names, the user's own folders only counted.
        var per: [String: Int] = [:]
        for m in msgs { per[m.mailbox.isStandard ? m.mailbox.rawValue : "own folders", default: 0] += 1 }
        print("CACHEPROBE per mailbox", per.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        try sqliteTiming(msgs)
    }

    /// The same messages in SQLite with one column per field, in a temporary file that is deleted afterwards.
    func sqliteTiming(_ msgs: [Message]) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var db: OpaquePointer?
        sqlite3_open(dir.appendingPathComponent("m.sqlite").path, &db)
        defer { sqlite3_close(db) }
        func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }
        exec("PRAGMA journal_mode=WAL")
        exec("CREATE TABLE m(id TEXT PRIMARY KEY, account TEXT, mailbox TEXT, remote TEXT, date REAL, read INT, flag TEXT, from_name TEXT, from_email TEXT, recipients TEXT, subject TEXT, preview TEXT, category TEXT, flags INT)")
        exec("CREATE INDEX m_box ON m(account, mailbox, date)")
        let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var t = Date()
        exec("BEGIN")
        var ins: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO m VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)", -1, &ins, nil)
        for m in msgs {
            let texts = [m.id.uuidString, m.accountID.uuidString, m.mailbox.rawValue, m.remoteID ?? "", "", "", m.flag?.rawValue ?? "",
                         m.from.name, m.from.email, (m.to + m.cc).map { "\($0.name)\u{1F}\($0.email)" }.joined(separator: "\u{1E}"),
                         m.subject, m.preview, m.category.rawValue]
            for (k, v) in texts.enumerated() where k != 4 && k != 5 { sqlite3_bind_text(ins, Int32(k + 1), v, -1, T) }
            sqlite3_bind_double(ins, 5, m.date.timeIntervalSinceReferenceDate)
            sqlite3_bind_int(ins, 6, m.isRead ? 1 : 0)
            sqlite3_bind_int(ins, 14, (m.isVIP ? 1 : 0) | (m.hasAttachments ? 2 : 0))
            sqlite3_step(ins); sqlite3_reset(ins)
        }
        sqlite3_finalize(ins)
        exec("COMMIT")
        let write = Date().timeIntervalSince(t)
        func read(_ sql: String) -> (Int, Double) {
            let t = Date()
            var st: OpaquePointer?, out: [Message] = []
            sqlite3_prepare_v2(db, sql, -1, &st, nil)
            func s(_ c: Int32) -> String { sqlite3_column_text(st, c).map { String(cString: $0) } ?? "" }
            while sqlite3_step(st) == SQLITE_ROW {
                let rcp = s(9).split(separator: "\u{1E}").map { p in
                    let f = p.split(separator: "\u{1F}", omittingEmptySubsequences: false)
                    return Contact(name: String(f.first ?? ""), email: String(f.dropFirst().first ?? ""))
                }
                var m = Message(accountID: UUID(uuidString: s(1))!, mailbox: MailboxKind(rawValue: s(2)), from: Contact(name: s(7), email: s(8)),
                                to: rcp, subject: s(10), body: "", date: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(st, 4)),
                                isRead: sqlite3_column_int(st, 5) == 1, flag: FlagColor(rawValue: s(6)), category: MailCategory(rawValue: s(12)) ?? .primary,
                                remoteID: s(3), serverPreview: s(11), bodyLoaded: false)
                m.id = UUID(uuidString: s(0))!
                out.append(m)
            }
            sqlite3_finalize(st)
            return (out.count, Date().timeIntervalSince(t))
        }
        let inbox = read("SELECT * FROM m WHERE mailbox='inbox' ORDER BY date DESC")
        let all = read("SELECT * FROM m")
        t = Date()
        exec("UPDATE m SET flag='red' WHERE rowid=1000")
        let one = Date().timeIntervalSince(t)
        print(String(format: "CACHEPROBE sqlite: write all %.2fs, inbox %d rows %.2fs, all %d rows %.2fs, one flag change %.4fs",
                     write, inbox.0, inbox.1, all.0, all.1, one))
    }
}
