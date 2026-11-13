import Foundation
import SQLite3
import Testing
@testable import EWS
@testable import MailModel

/// Folder syncs and the outbox against the server, over several pages, launches and accounts.
@MainActor
@Suite(.serialized)
struct MailStoreSyncTests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "Home", address: "me@home.com")

    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MailStoreSyncTests-\(UUID())/Mail.sqlite")
    }

    func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    /// Like a server summary: no body, recipients as names only.
    func remote(_ rid: String, account: Account? = nil, read: Bool = false, minutesAgo: Double = 0) -> Message {
        Message(accountID: (account ?? work).id, from: Contact(name: "Ann", email: ""), to: [Contact(name: "Me", email: "")],
                subject: "S \(rid)", body: "", date: Date(timeIntervalSinceReferenceDate: 800_000_000 - minutesAgo * 60),
                isRead: read, remoteID: rid, serverPreview: "P \(rid)", bodyLoaded: false)
    }

    func page(_ rids: [String], del: [String] = [], token: String, more: Bool = false) -> SyncResult {
        SyncResult(upserts: rids.map { remote($0) }, deletedRemoteIDs: del, token: token, more: more)
    }

    func inbox(_ s: MailStore, _ account: Account? = nil) -> [String] {
        s.messages.filter { $0.accountID == (account ?? work).id && $0.mailbox == .inbox }.compactMap(\.remoteID).sorted()
    }

    /// What `AppSetup.loadMail` does at launch.
    func launch(_ accounts: [Account], from url: URL) throws -> MailStore {
        let d = try MailDatabase(url: url)
        let s = MailStore(accounts: accounts, messages: [])
        let first = accounts.map { MailboxKey(account: $0.id, mailbox: .inbox) }
        s.restore(try d.meta())
        s.restore(try d.messages(in: first), boxes: first)
        s.finishLoading(try d.messages(notIn: first))
        return s
    }

    // MARK: file:// fixture backend (real EWSClient/EWSBackend, no network, no fake classes)

    /// A file standing in for every server response. // file:// fixture
    func responseFile(_ xml: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ews-sync-\(UUID().uuidString).xml")
        try Data(xml.utf8).write(to: url)
        return url
    }

    func envelope(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><s:Body>\(body)</s:Body></s:Envelope>
        """
    }

    /// Every operation "succeeds" and returns nothing. // file:// fixture
    var success: String {
        envelope("<m:X><m:ResponseMessages><m:R ResponseClass=\"Success\"><m:ResponseCode>NoError</m:ResponseCode></m:R></m:ResponseMessages></m:X>")
    }

    func backend(_ url: URL) -> EWSBackend { EWSBackend(client: EWSClient(url: url, username: "u", password: "p")) }  // file:// fixture

    // MARK: A from-scratch sync is authoritative (BUG-053)

    /// After the conversation upgrade every folder syncs from the start. Mail deleted on the server meanwhile
    /// is not in the complete re-sync, so it goes.
    @Test func upgradeResyncDropsMailDeletedOnTheServer() throws {
        let url = tempURL(); defer { cleanup(url) }
        let s0 = MailStore(accounts: [work], messages: [])
        s0.apply(page(["R1", "R2"], token: "T1"), account: work.id, mailbox: .inbox)
        try MailDatabase(url: url).write(s0.takeChanges())
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        #expect(sqlite3_exec(raw, "ALTER TABLE messages DROP COLUMN conversation", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)
        let s = try launch([work], from: url)
        #expect(s.syncToken(work.id, .inbox) == nil)
        var r1 = remote("R1"); r1.conversationID = "C1"
        s.apply(SyncResult(upserts: [r1], deletedRemoteIDs: [], token: "T2", more: false), account: work.id, mailbox: .inbox)
        #expect(s.isComplete(work.id, .inbox))
        #expect(inbox(s) == ["R1"])
        // The removal is written to disk too.
        let removed = s.takeChanges().removed
        #expect(removed.count == 1)
    }

    /// A pass over several pages (and history batches) removes only what none of its pages listed, and only once
    /// it is complete.
    @Test func fromScratchSyncOverSeveralPagesDropsOnlyWhatNoPageListed() {
        let s = MailStore(accounts: [work], messages: [])
        s.merge(["A", "B", "C", "D"].map { remote($0) }, account: work.id, mailbox: .inbox)  // e.g. the newest lookup
        s.apply(page(["A"], token: "T1", more: true), account: work.id, mailbox: .inbox)
        #expect(inbox(s) == ["A", "B", "C", "D"], "nothing goes before the pass is complete")
        s.apply([page(["B"], token: "T2", more: true), page(["E"], token: "T3", more: true)], account: work.id, mailbox: .inbox)
        #expect(inbox(s) == ["A", "B", "C", "D", "E"])
        s.apply(page(["D"], token: "T4"), account: work.id, mailbox: .inbox)
        #expect(inbox(s) == ["A", "B", "D", "E"])
    }

    /// A pass that finds the folder empty empties it.
    @Test func emptyFromScratchSyncEmptiesTheFolder() {
        let s = MailStore(accounts: [work], messages: [])
        s.merge(["A", "B"].map { remote($0) }, account: work.id, mailbox: .inbox)
        s.apply(page([], token: "T1"), account: work.id, mailbox: .inbox)
        #expect(inbox(s).isEmpty)
    }

    /// Changes since a token list only what changed: nothing else is removed.
    @Test func incrementalSyncRemovesOnlyWhatTheServerReports() {
        let s = MailStore(accounts: [work], messages: [])
        s.apply(page(["A", "B", "C"], token: "T1"), account: work.id, mailbox: .inbox)
        s.apply(page(["A"], del: ["B"], token: "T2"), account: work.id, mailbox: .inbox)
        s.apply([page([], token: "T3", more: true), page([], token: "T4")], account: work.id, mailbox: .inbox)
        #expect(inbox(s) == ["A", "C"])
    }

    /// Other folders and accounts, and local messages without a server ID, are left alone.
    @Test func fromScratchSyncTouchesOnlyItsOwnFolder() {
        let s = MailStore(accounts: [work, home], messages: [])
        s.merge([remote("A"), remote("B")], account: work.id, mailbox: .inbox)
        s.merge([remote("S")], account: work.id, mailbox: .sent)
        s.merge([remote("H", account: home)], account: home.id, mailbox: .inbox)
        s.failed(PendingChange(account: work.id, change: .send(Draft(accountID: work.id, to: "a@x.com", subject: "Kept")),
                               previous: []), "busy")  // a draft kept on this Mac
        s.apply(page(["A"], token: "T1"), account: work.id, mailbox: .inbox)
        #expect(inbox(s) == ["A"])
        #expect(s.messages.contains { $0.remoteID == "S" })
        #expect(s.messages.contains { $0.remoteID == "H" })
        #expect(s.messages.contains { $0.subject == "Kept" })
    }

    /// A message with a change still queued stays until that change is done; then it goes.
    @Test func fromScratchSyncKeepsMailWithQueuedChangesUntilTheyAreDone() async throws {
        let s = MailStore(accounts: [], messages: [])
        s.add(work, backend: backend(try responseFile(success)))  // file:// fixture
        s.merge([remote("A"), remote("B")], account: work.id, mailbox: .inbox)
        let b = try #require(s.messages.first { $0.remoteID == "B" }?.id)
        s.selection = [b]
        s.toggleRead([b])  // queued; the fixture answers once the outbox drains
        s.apply(page(["A"], token: "T1"), account: work.id, mailbox: .inbox)
        if !s.outbox.isEmpty { #expect(inbox(s) == ["A", "B"]) }
        for _ in 0..<250 where !s.outbox.isEmpty || inbox(s) != ["A"] { try await Task.sleep(for: .milliseconds(20)) }
        #expect(s.outbox.isEmpty)
        #expect(inbox(s) == ["A"])
        #expect(s.selection.isEmpty)
    }
}
