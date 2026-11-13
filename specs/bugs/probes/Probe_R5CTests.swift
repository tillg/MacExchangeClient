import Foundation
import SQLite3
import Testing
@testable import EWS
@testable import MailModel

/// Round 5, hunter C: search and storage. Real SQLite files in temp folders, the real MailStore, and for the outbox
/// the real EWSClient/EWSBackend against a loopback endpoint (no mocks).
@MainActor
@Suite(.serialized)
struct Probe_R5CSearch {
    let work = Account(name: "Work", address: "me@work.com")

    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Probe_R5C-\(UUID())/Mail.sqlite")
    }

    func msg(_ subject: String, body: String = "", box: MailboxKind = .inbox, date: Double = 800_000_000) -> Message {
        Message(accountID: work.id, mailbox: box, from: Contact(name: "Ann", email: "ann@x.com"),
                to: [Contact(name: "Me", email: "me@work.com")], subject: subject, body: body,
                date: Date(timeIntervalSinceReferenceDate: date), remoteID: "R-\(UUID())")
    }

    /// Writes `msgs` to a fresh database and runs `query` against its index, lowercased as the store does.
    func indexSearch(_ msgs: [Message], _ query: String) throws -> [Message.ID] {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = try MailDatabase(url: url)
        try db.write(StoreChanges(upserts: msgs))
        return try db.search(query.trimmingCharacters(in: .whitespaces).lowercased(), accounts: nil)
    }

    /// The memory path: a store without a searcher (sample data, launch before the index, after an index error).
    func memorySearch(_ msgs: [Message], _ query: String) -> [Message.ID] {
        let s = MailStore(accounts: [work], messages: msgs)
        s.searchText = query
        return s.visibleMessages.map(\.id)
    }

    /// R5C-01: Thai (and Lao, Khmer, Myanmar) are written without spaces, like Chinese and Japanese, so the tokenizer
    /// sees a whole sentence as one token; half-width katakana isn't in `isCJK` either. A word inside such a sentence
    /// isn't found by the index, while memory search finds it.
    @Test func wordsInsideThaiOrHalfwidthKatakanaTextAreFound() throws {
        let thai = msg("ประชุมวันจันทร์")         // "meeting Monday"
        let kana = msg("ｶﾀｶﾅﾃｽﾄ会議")              // half-width katakana, as in older Japanese mail
        #expect(memorySearch([thai], "วันจันทร์").count == 1)
        #expect(try indexSearch([thai], "วันจันทร์").count == 1, "Thai word inside a sentence not found by the index")
        #expect(try indexSearch([kana], "ﾃｽﾄ").count == 1, "half-width katakana word inside text not found by the index")
    }

    /// R5C-02: memory search keeps words with no letter or digit, which the index drops (search.md). A dash typed
    /// between words hides the mail; a query of only invisible characters lists every message.
    @Test func memorySearchDropsWordsWithoutLettersLikeTheIndex() throws {
        let q3 = msg("Q3 report")
        #expect(try indexSearch([q3], "q3 - report").count == 1)
        #expect(memorySearch([q3], "Q3 - report").count == 1, "memory path requires the dash itself")
        #expect(try indexSearch([q3], "report, q3").count == 1)
        #expect(memorySearch([q3], "report, q3").count == 1, "memory path requires the comma typed after a word")
        #expect(memorySearch([q3], "\u{200B}").isEmpty, "a zero-width space alone lists every message")
        #expect(memorySearch([q3], "\u{2028}").isEmpty, "a line separator alone lists every message")
    }

    /// R5C-03: Arabic harakat and Hebrew niqqud are diacritics, but neither path ignores them, unlike Latin accents
    /// ("Case and accents don't matter", README Search) and Greek tonos (BUG-082).
    @Test func arabicAndHebrewVowelMarksDontMatter() throws {
        let ar = msg("مَرْحَبًا بكم"), he = msg("שָׁלוֹם עולם")
        #expect(try indexSearch([ar], "مرحبا").count == 1, "Arabic word with harakat not found without them (index)")
        #expect(memorySearch([ar], "مرحبا").count == 1, "Arabic word with harakat not found without them (memory)")
        #expect(try indexSearch([he], "שלום").count == 1, "Hebrew word with niqqud not found without it (index)")
    }

    /// R5C-04 probe: Georgian written in Mtavruli (capitals, Unicode 11) — the FTS5 tokenizer's Unicode tables
    /// predate it, so a capitalised Georgian word isn't a word at all for the index; memory finds it.
    @Test func georgianCapitalsAreFound() throws {
        let ka = msg("ᲡᲐᲥᲐᲠᲗᲕᲔᲚᲝ")
        #expect(memorySearch([ka], "საქართველო").count == 1)
        #expect(try indexSearch([ka], "საქართველო").count == 1, "Mtavruli word not found by its lowercase (index)")
    }
}

@MainActor
@Suite(.serialized)
struct Probe_R5CStorage {
    let acct = Account(name: "Exchange", address: "me@work.com")

    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Probe_R5C-\(UUID())")
    }

    /// R5C-05: a Mail.sqlite that isn't a database (damaged file) makes every launch fail with "Couldn't load mail
    /// from disk … Changes aren't saved until relaunch", and a relaunch fails the same way: nothing is ever saved
    /// again. Cache.json in the same situation is set aside (DECISIONS #d-bug-009).
    @Test func aDamagedDatabaseFileIsSetAsideAndANewOneCreated() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Mail.sqlite")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 8192).write(to: url)
        var opened: MailDatabase?
        do { opened = try MailDatabase(url: url) } catch {
            Issue.record("damaged database isn't recovered: \(error.localizedDescription)")
        }
        #expect(opened != nil)
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0 != "Mail.sqlite" && !$0.hasPrefix("Mail.sqlite-") }
        #expect(!kept.isEmpty, "the damaged file should be kept aside, never deleted")
    }

    /// R5C-06: a file of 2 GiB or more kept with a draft (or a send waiting in the outbox) is bound with
    /// `Int32(v.count)`, which traps: the save crashes the app instead of failing.
    @Test func aHugeKeptFileDoesNotCrashTheSave() async {
        await #expect(processExitsWith: .success) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Probe_R5C-big-\(UUID())")
            defer { try? FileManager.default.removeItem(at: dir) }
            let db = try! MailDatabase(url: dir.appendingPathComponent("Mail.sqlite"))
            let big = Data(count: Int(Int32.max) + 1)  // zero pages: not touched before the bind
            _ = try? db.write(StoreChanges(files: [UUID(): [big]]))
        }
    }
}
