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

    // MARK: A sync token the server rejects (BUG-054)

    func syncError(_ code: String) -> String {  // file:// fixture
        envelope("<m:SyncFolderItemsResponse><m:ResponseMessages><m:SyncFolderItemsResponseMessage ResponseClass=\"Error\">"
                 + "<m:MessageText>\(code) text</m:MessageText><m:ResponseCode>\(code)</m:ResponseCode>"
                 + "<m:DescriptiveLinkKey>0</m:DescriptiveLinkKey></m:SyncFolderItemsResponseMessage></m:ResponseMessages>"
                 + "</m:SyncFolderItemsResponse>")
    }

    func store(answering xml: String) throws -> MailStore {
        let s = MailStore(accounts: [], messages: [])
        s.add(work, backend: backend(try responseFile(xml)))  // file:// fixture
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX"), RemoteFolder(role: .sent, id: "SENT")], account: work.id)
        return s
    }

    /// The backend reports a rejected token as `SyncTokenRejected`, not as any server error.
    @Test func rejectedSyncStateIsReportedAsSuch() async throws {
        let b = backend(try responseFile(syncError("ErrorInvalidSyncStateData")))  // file:// fixture
        await #expect(throws: SyncTokenRejected.self) { _ = try await b.sync(RemoteFolder(role: .inbox, id: "INBOX"), token: "OLD") }
        // Without a token there is nothing to reject: the server's error comes through as it is.
        await #expect(throws: EWSError.self) { _ = try await b.sync(RemoteFolder(role: .inbox, id: "INBOX"), token: nil) }
    }

    /// The quick check of a complete folder whose token Exchange rejects drops it, so the folder syncs again from
    /// the start instead of failing on every check.
    @Test func rejectedSyncStateIsDroppedByTheQuickCheck() async throws {
        let s = try store(answering: syncError("ErrorInvalidSyncStateData"))
        s.apply(page(["A"], token: "OLD"), account: work.id, mailbox: .inbox)
        await s.refresh(history: false)
        await s.refresh(history: false)
        #expect(s.syncToken(work.id, .inbox) == nil, "status: \(s.status ?? "")")
        #expect(!s.isComplete(work.id, .inbox))
        #expect(inbox(s) == ["A"], "mail stays until the new pass is complete")
    }

    /// The same in the history (a folder in the middle of its sync) and in the background checks of complete
    /// folders. Once the token is gone the history doesn't retry the same failure forever.
    @Test(.timeLimit(.minutes(1))) func rejectedSyncStateIsDroppedByTheHistory() async throws {
        let s = try store(answering: syncError("ErrorInvalidSyncStateData"))
        s.apply(page(["A"], token: "MID", more: true), account: work.id, mailbox: .inbox)
        s.apply(page(["S"], token: "OLD"), account: work.id, mailbox: .sent)
        await s.syncHistory()
        #expect(s.syncToken(work.id, .inbox) == nil)
        #expect(s.syncToken(work.id, .sent) == nil && !s.isComplete(work.id, .sent))
    }

    /// Dropping a rejected token happens once per folder and session: if the server rejects the new token too, the
    /// folder is reported and kept as it is instead of being downloaded again on every check.
    @Test func rejectedSyncStateIsDroppedOnlyOnce() async throws {
        let s = try store(answering: syncError("ErrorInvalidSyncStateData"))
        s.apply(page(["A"], token: "OLD"), account: work.id, mailbox: .inbox)
        await s.refresh(history: false)
        #expect(s.syncToken(work.id, .inbox) == nil)
        s.apply(page(["A"], token: "NEW"), account: work.id, mailbox: .inbox)  // the new pass, complete
        await s.refresh(history: false)
        #expect(s.syncToken(work.id, .inbox) == "NEW" && s.isComplete(work.id, .inbox))
        #expect(s.status?.contains("sync position") == true, "status: \(s.status ?? "nil")")
    }

    // MARK: A message kept in Drafts after a failed send keeps its files (BUG-055)

    func keptDraft(_ s: MailStore, files: [DraftAttachment]) throws -> Message.ID {
        var d = Draft(accountID: work.id, to: "bo@x.com", subject: "Report", body: "See attached")
        d.attachments = files
        s.failed(PendingChange(account: work.id, change: .send(d), previous: []), "The server is busy")
        return try #require(s.messages.first { $0.mailbox == .drafts && $0.subject == "Report" }?.id)
    }

    /// The files of a message Exchange refused to send are written with it, so they still open after a relaunch.
    @Test func failedSendKeepsAttachmentContentAcrossRelaunch() async throws {
        let url = tempURL(); defer { cleanup(url) }
        let s = MailStore(accounts: [work], messages: [])
        s.merge([(.inbox, [])], account: work.id)  // work is a server account
        let id = try keptDraft(s, files: [DraftAttachment(name: "report.pdf", contentType: "application/pdf", data: Data("PDFDATA".utf8)),
                                          DraftAttachment(name: "b.txt", contentType: "text/plain", data: Data("B".utf8))])
        try MailDatabase(url: url).write(s.takeChanges())
        let s2 = try launch([work], from: url)
        s2.downloadsFolder = url.deletingLastPathComponent().appendingPathComponent("Mail Downloads")
        #expect(s2.message(id)?.attachments.map(\.name) == ["report.pdf", "b.txt"])
        let file = await s2.attachmentFile(0, of: id)
        #expect(file.flatMap { try? Data(contentsOf: $0) } == Data("PDFDATA".utf8), "status: \(s2.status ?? "nil")")
        let second = await s2.attachmentFile(1, of: id)
        #expect(second.flatMap { try? Data(contentsOf: $0) } == Data("B".utf8))
    }

    /// Erasing the kept draft erases its files on disk too.
    @Test func erasingAKeptDraftErasesItsFiles() throws {
        let url = tempURL(); defer { cleanup(url) }
        let db = try MailDatabase(url: url)
        let s = MailStore(accounts: [work], messages: [])
        s.merge([(.inbox, [])], account: work.id)
        let id = try keptDraft(s, files: [DraftAttachment(name: "a.pdf", contentType: nil, data: Data("A".utf8))])
        try db.write(s.takeChanges())
        #expect(try db.meta().files[id] == [Data("A".utf8)])
        s.delete([id])
        s.delete([id])  // erased from Trash
        try db.write(s.takeChanges())
        #expect(try MailDatabase(url: url).meta().files.isEmpty)
    }

    /// A database from before kept files gets their table when opened; its rows still read.
    @Test func databaseWithoutTheFilesTableStillOpens() throws {
        let url = tempURL(); defer { cleanup(url) }
        let s0 = MailStore(accounts: [work], messages: [])
        s0.apply(page(["R1"], token: "T1"), account: work.id, mailbox: .inbox)
        try MailDatabase(url: url).write(s0.takeChanges())
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        #expect(sqlite3_exec(raw, "DROP TABLE files", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)
        let s = try launch([work], from: url)
        #expect(inbox(s) == ["R1"])
        let id = try keptDraft(s, files: [DraftAttachment(name: "a.pdf", contentType: nil, data: Data("A".utf8))])
        try MailDatabase(url: url).write(s.takeChanges())
        #expect(try MailDatabase(url: url).meta().files[id] == [Data("A".utf8)])
    }

    // MARK: An Exchange account without a password is not sample data (BUG-056)

    /// Set up in Settings, unlike the sample data's accounts.
    var exchange: Account { Account(id: work.id, name: "Exchange", address: "me@work.com", isServer: true) }

    /// An Exchange account whose password is missing has no backend, but its mail is from the server: signing in
    /// another account must not remove it while its mail stays in All Inboxes.
    @Test func removeLocalAccountsKeepsExchangeAccountWithoutPassword() {
        var r = remote("R1"); r.accountID = exchange.id
        let sample = Message(accountID: home.id, from: Contact(name: "Ann", email: "ann@x.com"), to: [], subject: "sample",
                             body: "b", date: .now)
        let s = MailStore(accounts: [exchange, home], messages: [sample])
        s.merge([r], account: exchange.id, mailbox: .inbox)  // exchange's mail came from the server (or the database)
        s.removeLocalAccounts()
        #expect(s.accounts.map(\.id) == [exchange.id])
        #expect(s.messages.allSatisfy { m in s.accounts.contains { $0.id == m.accountID } })
    }

    /// Its draft kept after a failed send stays too.
    @Test func removeLocalAccountsKeepsTheDraftsOfAnExchangeAccountWithoutPassword() {
        let s = MailStore(accounts: [exchange, home], messages: [])
        s.merge([(.inbox, [])], account: exchange.id)
        s.failed(PendingChange(account: exchange.id, change: .send(Draft(accountID: exchange.id, to: "a@x.com", subject: "S")),
                               previous: []), "busy")
        let kept = s.messages[0].id
        _ = s.takeChanges()
        s.removeLocalAccounts()
        #expect(s.message(kept) != nil)
        #expect(s.takeChanges().removed.isEmpty)
    }

    /// Connected without a password (and before any mail is stored), the account is still an Exchange account:
    /// it isn't removed, and what is sent from it waits in the outbox instead of showing as sent.
    @Test func exchangeAccountWithoutPasswordIsAServerAccount() {
        let s = MailStore(accounts: [home], messages: [])
        s.add(exchange, backend: nil)
        s.send(Draft(accountID: exchange.id, to: "a@x.com", subject: "Waits", body: "b"))
        #expect(s.outbox.count == 1)
        #expect(!s.messages.contains { $0.subject == "Waits" })
        s.removeLocalAccounts()
        #expect(s.accounts.map(\.id) == [exchange.id])
    }

    /// Send from an Exchange account that has no password: never shown in Sent, queued, and the status says it
    /// waits for the sign-in, also before the account has stored anything (BUG-101).
    @Test func sendFromAnAccountWithoutPasswordSaysItWaits() {
        let ex = ExchangeAccount(email: "till@work.com", username: "W\\till", server: "mail.work.com")
        let s = MailStore(accounts: [], messages: [])
        s.accounts.append(ex.account)  // nothing stored for it yet
        s.status = "No password in the Keychain for W\\till"
        let before = s.status
        s.send(Draft(accountID: ex.id, to: "x@y.com", subject: "Important", body: "b"))
        #expect(!s.messages.contains { $0.mailbox == .sent }, "shown in Sent")
        #expect(s.outbox.contains(where: isSend))
        #expect(s.status != before && s.status?.contains("Important") == true, "status: \(s.status ?? "nil")")
    }

    /// Signing in again (the password entered) gives the same account its backend: no second account, and what
    /// waited goes out.
    @Test func signingInAgainConnectsTheSameAccount() async throws {
        let s = MailStore(accounts: [], messages: [])
        s.add(exchange, backend: nil)
        s.merge([remote("R1")], account: exchange.id, mailbox: .inbox)
        s.send(Draft(accountID: exchange.id, to: "a@x.com", subject: "Waits", body: "b"))
        s.add(exchange, backend: backend(try responseFile(success)))  // file:// fixture
        #expect(s.accounts.map(\.id) == [exchange.id])
        await s.refresh(history: false)
        #expect(s.outbox.isEmpty, "status: \(s.status ?? "")")
    }

    // MARK: A summary doesn't overwrite what the loaded body knows (BUG-057)

    func id(_ s: MailStore, _ rid: String) -> Message.ID { s.messages.first { $0.remoteID == rid }!.id }

    /// EWS summaries carry From/To/Cc as names only. After the body filled in the addresses, a later summary of the
    /// same message (read on the phone) keeps them: Reply and Reply All still have somewhere to go.
    @Test func laterSummaryKeepsTheRecipientAddressesOfALoadedBody() {
        var sum = remote("A"); sum.cc = [Contact(name: "Bob", email: "")]
        let s = MailStore(accounts: [work], messages: [])
        s.apply(SyncResult(upserts: [sum], deletedRemoteIDs: [], token: "t0", more: false), account: work.id, mailbox: .inbox)
        let a = id(s, "A")
        let from = Contact(name: "Ann", email: "ann@x.com")
        let to = [Contact(name: "Me", email: "me@work.com")], cc = [Contact(name: "Bob", email: "bob@y.com")]
        s.setBody(MessageBody(text: "Full", attachments: [], from: from, to: to, cc: cc), for: a)
        sum.isRead = true
        s.apply(SyncResult(upserts: [sum], deletedRemoteIDs: [], token: "t1", more: false), account: work.id, mailbox: .inbox)
        #expect(s.message(a)?.isRead == true)
        #expect(s.message(a)?.needsBody == false)
        #expect(s.message(a)?.from == from)
        #expect(s.message(a)?.to == to)
        #expect(s.message(a)?.cc == cc)
        #expect(s.draft(.reply, to: a).to == "ann@x.com")
        #expect(s.draft(.replyAll, to: a).to.contains("ann@x.com"))
        #expect(s.draft(.replyAll, to: a).cc == "bob@y.com")
    }

    /// The same through the newest-50 lookup, which merges the same summaries on every check of a folder still syncing.
    @Test func newestLookupKeepsTheRecipientAddressesOfALoadedBody() {
        let s = MailStore(accounts: [work], messages: [])
        s.merge([remote("A")], account: work.id, mailbox: .inbox)
        let a = id(s, "A")
        s.setBody(MessageBody(text: "Full", attachments: [], from: Contact(name: "Ann", email: "ann@x.com"),
                              to: [Contact(name: "Me", email: "me@work.com")], cc: []), for: a)
        s.merge([remote("A")], account: work.id, mailbox: .inbox)
        #expect(s.draft(.reply, to: a).to == "ann@x.com")
    }

    /// The paperclip follows the attachment list the body brought (Exchange counts inline pictures as attachments).
    @Test func laterSummaryKeepsWhatTheBodySaidAboutAttachments() {
        var sum = remote("A"); sum.hasAttachments = true
        let s = MailStore(accounts: [work], messages: [])
        s.apply(SyncResult(upserts: [sum], deletedRemoteIDs: [], token: "t0", more: false), account: work.id, mailbox: .inbox)
        let a = id(s, "A")
        s.setBody(MessageBody(text: "Full", attachments: []), for: a)
        sum.isRead = true
        s.apply(SyncResult(upserts: [sum], deletedRemoteIDs: [], token: "t1", more: false), account: work.id, mailbox: .inbox)
        #expect(s.message(a)?.hasAttachments == false)
    }

    /// When the summary's names differ from the loaded ones (a draft edited elsewhere), the server changed the
    /// message: the new names show and the body is fetched again, so addresses are never left empty unnoticed.
    @Test func summaryWithOtherRecipientsFetchesTheBodyAgain() {
        let s = MailStore(accounts: [work], messages: [])
        s.merge([remote("A")], account: work.id, mailbox: .drafts)
        let a = id(s, "A")
        s.setBody(MessageBody(text: "Old text", attachments: [], from: Contact(name: "Ann", email: "ann@x.com"),
                              to: [Contact(name: "Me", email: "me@work.com")], cc: []), for: a)
        var edited = remote("A"); edited.to = [Contact(name: "Me", email: ""), Contact(name: "Carol", email: "")]
        s.merge([edited], account: work.id, mailbox: .drafts)
        #expect(s.message(a)?.to.map(\.name) == ["Me", "Carol"])
        #expect(s.message(a)?.needsBody == true)
    }

    // MARK: Save in the close sheet while the original's files load (BUG-094)

    /// `saveDraft` refuses while a forward's original files are still loading (Mail's AttachmentsPendingMessage), and
    /// now says so, so the close sheet's Save keeps the window open and saves once the files are in: the text and
    /// the files are kept, nothing is thrown away.
    @Test func saveWhileOriginalFilesLoadWaitsAndThenKeepsEverything() async {
        let original = Message(accountID: home.id, from: Contact(name: "Ann", email: "ann@x.com"),
                               to: [Contact(name: "Me", email: home.address)], subject: "Contract", body: "Body",
                               date: Date(timeIntervalSince1970: 1_000_000), attachments: ["contract.pdf"])
        let s = MailStore(accounts: [work, home], messages: [original])
        s.setAttachmentData([Data("PDF".utf8)], for: original.id)
        s.downloadsFolder = FileManager.default.temporaryDirectory.appendingPathComponent("MailStoreSyncTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: s.downloadsFolder) }
        var d = s.draft(.forward, to: original.id)
        #expect(d.loadingOriginal == original.id)
        d.to = "bo@x.com"
        d.body = "Please sign by Friday." + d.body
        #expect(s.saveDraft(d) == false, "refused while the files load")
        #expect(!s.messages.contains { $0.mailbox == .drafts })
        await s.includeOriginalAttachments(in: &d)  // what the open window does meanwhile
        #expect(s.saveDraft(d))
        let saved = s.messages.first { $0.mailbox == .drafts }
        #expect(saved?.body.contains("Please sign") == true)
        #expect(saved?.attachments.map(\.name) == ["contract.pdf"])
    }

    // MARK: A send under way when the app quits is not sent again (BUG-095)

    func isSend(_ p: PendingChange) -> Bool { if case .send = p.change { true } else { false } }

    /// The save on quit (or the 15-second save) stores a send while its request is on the way. After a relaunch it
    /// isn't sent again: it may have gone out. It is kept in Drafts on this Mac, and the status says to check Sent.
    @Test func sendInFlightWhenTheAppQuitsIsNotSentAgainAfterRelaunch() async throws {
        let url = tempURL(); defer { cleanup(url) }
        let ok = try responseFile(success)  // file:// fixture
        let s = MailStore(accounts: [], messages: [])
        s.add(work, backend: backend(ok))
        let db = try MailDatabase(url: url)
        s.apply(page(["A1"], token: "T1"), account: work.id, mailbox: .inbox)
        s.send(Draft(accountID: work.id, to: "boss@x.com", subject: "Resignation", body: "Once only"))
        // Until the drain has started: the request is on its way.
        for _ in 0..<1000 where s.outbox.first?.inFlight != true { await Task.yield() }
        try #require(s.outbox.contains { isSend($0) && $0.inFlight == true })
        try db.write(s.takeChanges())  // the save on quit while the request is on its way
        await s.refresh(history: false)  // the server accepted it
        try #require(!s.outbox.contains(where: isSend))
        // The app quit before the next save. Next launch:
        let s2 = MailStore(accounts: [], messages: [])
        s2.add(work, backend: backend(ok))
        let db2 = try MailDatabase(url: url)
        s2.restore(try db2.meta())
        // (The next check's success clears any status: BUG-100.)
        #expect(s2.status?.contains("check Sent") == true, "status: \(s2.status ?? "nil")")
        s2.finishLoading(try db2.messages())
        await s2.refresh(history: false)
        #expect(s2.outbox.isEmpty)
        #expect(s2.messages.filter { $0.mailbox == .drafts && $0.subject == "Resignation" }.count == 1)
        // Written to disk: a second relaunch shows the one draft and sends nothing.
        try db2.write(s2.takeChanges())
        let s3 = try launch([work], from: url)
        #expect(s3.outbox.isEmpty)
        #expect(s3.messages.filter { $0.mailbox == .drafts && $0.subject == "Resignation" }.count == 1)
    }

    /// The mark is on disk before the request goes out: the store asks for a save first and waits for it.
    @Test func sendIsMarkedAndSavedBeforeItGoesOut() async throws {
        let s = MailStore(accounts: [], messages: [])
        s.add(work, backend: backend(try responseFile(success)))  // file:// fixture
        s.merge([(.inbox, [])], account: work.id)
        var saved: StoreChanges?
        s.saveBeforeSending = { saved = s.takeChanges() }
        s.send(Draft(accountID: work.id, to: "boss@x.com", subject: "S", body: "b"))
        await s.refresh(history: false)
        #expect(s.outbox.isEmpty)
        let marked = try #require(saved?.outbox?.first)
        #expect(isSend(marked) && marked.inFlight == true)
    }

    /// Outbox rows written before the mark existed still read, as not under way.
    @Test func outboxRowsWithoutTheMarkStillRead() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","account":"7F9619FF-8B86-D011-B42D-00C04FC964FF","#
            + #""change":{"setRead":{"_0":["R1"],"_1":true}},"previous":[]}"#
        let p = try JSONDecoder().decode(PendingChange.self, from: Data(json.utf8))
        #expect(p.change == .setRead(["R1"], true))
        #expect(p.inFlight == nil)
    }

    // MARK: One unreachable account doesn't hold up the others (BUG-096)

    /// Account A's server can't be reached (only over VPN, or down): its changes wait, in order, while account B's
    /// changes and sends go out.
    @Test func unreachableAccountDoesNotBlockTheOtherAccountsChanges() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("ews-sync-missing-\(UUID().uuidString).xml")
        let s = MailStore(accounts: [], messages: [])
        s.add(work, backend: backend(missing))  // file:// fixture that isn't there: a network error
        s.add(home, backend: backend(try responseFile(success)))  // file:// fixture
        s.apply(page(["A1", "A2"], token: "T1"), account: work.id, mailbox: .inbox)
        s.apply(SyncResult(upserts: [remote("B1", account: home)], deletedRemoteIDs: [], token: "T1", more: false),
                account: home.id, mailbox: .inbox)
        let a1 = id(s, "A1"), a2 = id(s, "A2"), b1 = id(s, "B1")
        s.toggleRead([a1])
        s.toggleRead([b1])
        s.setFlag(.red, for: [a2])
        s.send(Draft(accountID: home.id, to: "x@y.com", subject: "From B", body: "b"))
        await s.refresh(history: false)
        #expect(s.outbox.filter { $0.account == home.id }.isEmpty, "B: \(s.outbox.filter { $0.account == home.id }.map(\.change))")
        #expect(s.outbox.map(\.change) == [.setRead(["A1"], true), .setFlagged(["A2"], true)], "A's changes wait in order")
        #expect(s.message(a1)?.isRead == true, "A's change isn't undone")
    }

    // MARK: Batches with one refused item (BUG-059)

    func ok(_ op: String, _ inner: String = "") -> String {  // file:// fixture
        "<m:\(op)ResponseMessage ResponseClass=\"Success\"><m:ResponseCode>NoError</m:ResponseCode>\(inner)</m:\(op)ResponseMessage>"
    }

    func err(_ op: String, _ code: String) -> String {  // file:// fixture
        "<m:\(op)ResponseMessage ResponseClass=\"Error\"><m:MessageText>\(code) text</m:MessageText><m:ResponseCode>\(code)</m:ResponseCode>"
            + "<m:DescriptiveLinkKey>0</m:DescriptiveLinkKey></m:\(op)ResponseMessage>"
    }

    func response(_ op: String, _ messages: String) -> String {  // file:// fixture
        envelope("<m:\(op)Response><m:ResponseMessages>\(messages)</m:ResponseMessages></m:\(op)Response>")
    }

    func movedItem(_ id: String) -> String { ok("MoveItem", "<m:Items><t:Message><t:ItemId Id=\"\(id)\" ChangeKey=\"CK\"/></t:Message></m:Items>") }

    /// A store with one Exchange account whose server answers every request with `xml`.
    func batchStore(_ xml: String, _ rids: [String], in box: MailboxKind = .inbox) throws -> MailStore {
        let s = try store(answering: xml)
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX"), RemoteFolder(role: .trash, id: "DEL"),
                            RemoteFolder(role: .archive, id: "ARCH")], account: work.id)
        s.apply(SyncResult(upserts: rids.map { var m = remote($0); m.mailbox = box; return m }, deletedRemoteIDs: [],
                           token: "T1", more: false), account: work.id, mailbox: box)
        return s
    }

    func waitForOutbox(_ s: MailStore) async throws {
        for _ in 0..<250 where !s.outbox.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// Exchange moved A and C and reports B as gone: the new IDs of A and C come back with the refusal of B.
    @Test func moveKeepsTheNewIDsWhenOneItemIsRefused() async throws {
        let b = backend(try responseFile(response("MoveItem", movedItem("N1") + err("MoveItem", "ErrorItemNotFound") + movedItem("N3"))))
        do {
            _ = try await b.move(["A", "B", "C"], to: RemoteFolder(role: .archive, id: "ARCH"))
            Issue.record("B's refusal was not reported")
        } catch let e as PartlyRefused {
            #expect(e.moved == ["A": "N1", "C": "N3"])
            #expect(Array(e.refused.keys) == ["B"])
        }
    }

    /// Mark three as read; the server marks A and C and reports B as gone. Only B is undone here.
    @Test func readBatchWithOneRefusedItemKeepsTheOthers() async throws {
        let item = { (id: String) in self.ok("UpdateItem", "<m:Items><t:Message><t:ItemId Id=\"\(id)\" ChangeKey=\"K\"/></t:Message></m:Items>") }
        let s = try batchStore(response("UpdateItem", item("A") + err("UpdateItem", "ErrorItemNotFound") + item("C")), ["A", "B", "C"])
        s.toggleRead(Set(s.messages.map(\.id)))
        try await waitForOutbox(s)
        let read = Dictionary(uniqueKeysWithValues: s.messages.map { ($0.remoteID!, $0.isRead) })
        #expect(read == ["A": true, "B": false, "C": true], "status: \(s.status ?? "")")
        #expect(s.status?.contains("ErrorItemNotFound") == true)
    }

    /// Move three to the Archive; B is refused. A and C stay in the Archive with their new IDs, B goes back.
    @Test func moveBatchWithOneRefusedItemKeepsTheOthersMoved() async throws {
        let s = try batchStore(response("MoveItem", movedItem("N1") + err("MoveItem", "ErrorItemNotFound") + movedItem("N3")), ["A", "B", "C"])
        s.move(Set(s.messages.map(\.id)), to: .archive)
        try await waitForOutbox(s)
        let where_ = Dictionary(uniqueKeysWithValues: s.messages.map { ($0.remoteID!, $0.mailbox) })
        #expect(where_ == ["N1": .archive, "B": .inbox, "N3": .archive], "status: \(s.status ?? "")")
    }

    /// Erase three from Trash; the server reports one as already gone. All three are gone, nothing comes back.
    @Test func eraseBatchWithOneItemAlreadyGoneErasesAll() async throws {
        let s = try batchStore(response("DeleteItem", ok("DeleteItem") + err("DeleteItem", "ErrorItemNotFound") + ok("DeleteItem")),
                               ["A", "B", "C"], in: .trash)
        s.delete(Set(s.messages.map(\.id)))
        try await waitForOutbox(s)
        #expect(s.messages.isEmpty, "status: \(s.status ?? "")")
        #expect(s.status == nil)
    }

    /// An answer with fewer response messages than items doesn't count the unanswered ones as changed.
    @Test func batchAnswerMissingItemsIsNotSuccess() async throws {
        let b = backend(try responseFile(response("UpdateItem", ok("UpdateItem"))))
        await #expect(throws: (any Error).self) { try await b.setRead(["A", "B"], true) }
    }

    // MARK: Answers that aren't EWS answers (BUG-060)

    /// An empty SOAP body, or a proxy's error page that happens to be well-formed XML, carries no EWS result.
    nonisolated static let answersWithoutResult = [
        "<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body></s:Body></s:Envelope>",
        "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>503 Service Unavailable</title></head><body><h1>Service Unavailable</h1></body></html>",
        "<?xml version=\"1.0\"?><error><code>503</code><message>Backend not available</message></error>",
    ]

    @Test(arguments: answersWithoutResult) func sendWithAnswerWithoutResultFails(_ xml: String) async throws {
        let b = backend(try responseFile(xml))
        await #expect(throws: (any Error).self) {
            try await b.send(Draft(accountID: work.id, to: "a@x.com", subject: "S", body: "B"))
        }
    }

    @Test func syncWithAnswerWithoutResultFails() async throws {
        let b = backend(try responseFile(envelope("")))
        await #expect(throws: (any Error).self) { _ = try await b.sync(RemoteFolder(role: .inbox, id: "INBOX"), token: "OLD") }
    }

    /// The message is neither sent nor lost: it is kept in Drafts with a status.
    @Test func sendWithAnswerWithoutResultKeepsTheMessage() async throws {
        let s = try store(answering: envelope(""))
        s.send(Draft(accountID: work.id, to: "bob@x.com", subject: "Quarterly report", body: "Hi"))
        try await waitForOutbox(s)
        #expect(s.messages.contains { $0.subject == "Quarterly report" && $0.mailbox == .drafts }, "status: \(s.status ?? "")")
        #expect(s.status != nil)
    }

    /// History against an answer without a result doesn't mark the folder complete with an empty sync position.
    @Test func historyWithAnswerWithoutResultDoesNotCompleteTheFolder() async throws {
        let s = try store(answering: envelope(""))
        await s.syncHistory()
        #expect(!s.isComplete(work.id, .inbox))
        #expect(s.syncToken(work.id, .inbox) == nil)
    }

    // MARK: A busy server keeps changes queued (BUG-061)

    /// Exchange throttling: a SOAP fault ErrorServerBusy with BackOffMilliseconds. // file:// fixture
    let serverBusy = """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
        <s:Fault><faultcode xmlns:a="http://schemas.microsoft.com/exchange/services/2006/types">a:ErrorServerBusy</faultcode>\
        <faultstring xml:lang="en-US">The server cannot service this request right now. Try again later.</faultstring>\
        <detail><e:ResponseCode xmlns:e="http://schemas.microsoft.com/exchange/services/2006/errors">ErrorServerBusy</e:ResponseCode>\
        <e:Message xmlns:e="http://schemas.microsoft.com/exchange/services/2006/errors">The server cannot service this request right now. Try again later.</e:Message>\
        <t:MessageXml xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><t:Value Name="BackOffMilliseconds">29774</t:Value></t:MessageXml>\
        </detail></s:Fault></s:Body></s:Envelope>
        """

    /// A load balancer's 503 page (HTTP.sys "Service Unavailable", not well-formed XML). // file:// fixture
    let serviceUnavailablePage = "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01//EN\"\"http://www.w3.org/TR/html4/strict.dtd\">\r\n<HTML><HEAD><TITLE>Service Unavailable</TITLE>\r\n<META HTTP-EQUIV=\"Content-Type\" Content=\"text/html; charset=us-ascii\"></HEAD>\r\n<BODY><h2>Service Unavailable</h2>\r\n<hr><p>HTTP Error 503. The service is unavailable.</p>\r\n</BODY></HTML>\r\n"

    @Test func serverBusyIsReportedAsSuch() async throws {
        let b = backend(try responseFile(serverBusy))
        do { try await b.setRead(["A"], true); Issue.record("no error") } catch let e as ServerBusy {
            #expect(e.retryAfter == 29.774)
        }
    }

    /// Throttling doesn't undo the change: it stays queued, and isn't tried again before the back-off has passed.
    @Test func serverBusyKeepsTheChangeQueued() async throws {
        let file = try responseFile(serverBusy)
        let s = MailStore(accounts: [], messages: [])
        s.add(work, backend: backend(file))
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX")], account: work.id)
        s.apply(page(["A"], token: "T1"), account: work.id, mailbox: .inbox)
        s.toggleRead([id(s, "A")])
        await s.refresh(history: false)
        #expect(s.message(id(s, "A"))?.isRead == true, "status: \(s.status ?? "")")
        #expect(s.outbox.map(\.change) == [.setRead(["A"], true)])
        try Data(success.utf8).write(to: file)
        await s.refresh(history: false)
        #expect(s.outbox.map(\.change) == [.setRead(["A"], true)], "tried again within the back-off")
    }

    /// A gateway's 503 page isn't a refusal either; the change goes with the next refresh.
    @Test func serviceUnavailablePageKeepsTheChangeQueued() async throws {
        let file = try responseFile(serviceUnavailablePage)
        let s = MailStore(accounts: [], messages: [])
        s.add(work, backend: backend(file))
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX")], account: work.id)
        s.apply(page(["A"], token: "T1"), account: work.id, mailbox: .inbox)
        s.toggleRead([id(s, "A")])
        await s.refresh(history: false)
        #expect(s.message(id(s, "A"))?.isRead == true, "status: \(s.status ?? "")")
        #expect(s.outbox.map(\.change) == [.setRead(["A"], true)])
        try Data(success.utf8).write(to: file)
        await s.refresh(history: false)
        #expect(s.outbox.isEmpty)
        #expect(s.message(id(s, "A"))?.isRead == true)
    }

    // MARK: Accounts are checked independently (BUG-098, BUG-100)

    /// While one account's server can't be reached, the other accounts' history still completes.
    @Test func unreachableAccountDoesNotStopTheOtherAccountsHistory() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("ews-sync-missing-\(UUID().uuidString).xml")
        let s = MailStore(accounts: [work, home], messages: [])
        s.add(work, backend: backend(missing))  // file:// fixture that isn't there: a network error
        s.add(home, backend: backend(try responseFile(success)))  // file:// fixture
        // Both folder lists were read while Work was still reachable.
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "FA"), RemoteFolder(role: .sent, id: "FA2")], account: work.id)
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "FB"), RemoteFolder(role: .sent, id: "FB2")], account: home.id)
        await s.syncHistory()
        #expect(s.isComplete(home.id, .inbox) && s.isComplete(home.id, .sent))
        #expect(!s.isComplete(work.id, .inbox))
    }

    func failing(_ code: String) -> String {  // file:// fixture
        envelope("<m:X><m:ResponseMessages>\(err("X", code))</m:ResponseMessages></m:X>")
    }

    /// "Couldn't send …" stays after the next successful check: it is the only sign the mail didn't go.
    @Test func couldntSendNoticeSurvivesTheNextCheck() async throws {
        let file = try responseFile(failing("ErrorInvalidRecipients"))
        let s = MailStore(accounts: [], messages: [])
        s.add(work, backend: backend(file))
        s.send(Draft(accountID: work.id, to: "nobody", subject: "Quarterly report", body: "b"))
        try await waitForOutbox(s)
        #expect(s.status?.contains("Couldn't send") == true)
        try Data(success.utf8).write(to: file)  // the server answers normally again
        await s.refresh(history: false)
        #expect(s.status?.contains("Couldn't send") == true, "status after the next check: \(s.status ?? "nil")")
    }

    /// One account's failed check isn't hidden by another account's successful one, in either order.
    @Test func oneAccountsErrorIsNotClearedByTheOthersSuccess() async throws {
        let ok = try responseFile(success), bad = try responseFile(failing("ErrorMailboxMoveInProgress"))
        for _ in 0..<16 {
            let x = Account(name: "Work", address: "me@work.com"), y = Account(name: "Club", address: "me@club.org")
            let s = MailStore(accounts: [], messages: [])
            s.add(x, backend: backend(bad))
            s.add(y, backend: backend(ok))
            await s.refresh(history: false)
            #expect(s.status?.contains("ErrorMailboxMoveInProgress") == true, "status: \(s.status ?? "nil")")
        }
    }

    /// An account's own check error, and its offline notice, go once that account's check works again.
    @Test func successfulCheckClearsItsOwnAccountsError() async throws {
        let file = try responseFile(failing("ErrorMailboxMoveInProgress"))
        let s = MailStore(accounts: [], messages: [])
        s.add(work, backend: backend(file))
        await s.refresh(history: false)
        #expect(s.status != nil)
        try Data(success.utf8).write(to: file)
        await s.refresh(history: false)
        #expect(s.status == nil, "status: \(s.status ?? "nil")")

        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("ews-sync-missing-\(UUID().uuidString).xml")
        let t = MailStore(accounts: [], messages: [])
        t.add(work, backend: backend(missing))
        t.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX")], account: work.id)
        t.apply(page(["A"], token: "T1"), account: work.id, mailbox: .inbox)
        t.toggleRead([id(t, "A")])
        await t.refresh(history: false)
        #expect(t.status != nil)
        try Data(success.utf8).write(to: missing)  // reachable again
        defer { try? FileManager.default.removeItem(at: missing) }
        await t.refresh(history: false)
        #expect(t.status == nil, "status: \(t.status ?? "nil")")
        #expect(t.outbox.isEmpty)
    }

    // MARK: Server pages while a change is queued (BUG-072, BUG-073, BUG-074)

    /// A store without a backend: queued changes stay queued, as while their request is on its way.
    func synced(_ rids: [String], in box: MailboxKind = .inbox) -> MailStore {
        let s = MailStore(accounts: [work, home], messages: [])
        s.apply(SyncResult(upserts: rids.map { var m = remote($0); m.mailbox = box; return m }, deletedRemoteIDs: [],
                           token: "t0", more: false), account: work.id, mailbox: box)
        return s
    }

    /// A message erased from Trash doesn't come back from a Trash page, or the newest lookup, fetched before the
    /// queued erase reached the server.
    @Test func erasedMessageIsNotBroughtBackWhileItsEraseIsQueued() {
        let s = synced(["A"], in: .trash)
        let a = id(s, "A")
        s.delete([a])
        #expect(s.outbox.map(\.change) == [.delete(["A"])])
        s.apply(page(["A"], token: "t1"), account: work.id, mailbox: .trash)
        #expect(s.messages.filter { $0.remoteID == "A" }.isEmpty, "erased message is back in Trash")
        s.merge([remote("A")], account: work.id, mailbox: .trash)
        #expect(s.messages.filter { $0.remoteID == "A" }.isEmpty, "erased message is back from the newest lookup")
    }

    /// While a move is on its way, the destination's sync can already list the moved copy under its new ID; when the
    /// move's answer then renames the message, it stays one message, with its local ID and selection.
    @Test func renameOntoAnIDTheSyncAlreadyBroughtDoesNotDuplicate() {
        let s = synced(["A"])
        let a = id(s, "A")
        s.archive([a])
        s.apply(page(["A2"], token: "a1"), account: work.id, mailbox: .archive)
        s.selection = Set(s.messages.map(\.id))
        s.renameRemote(["A": "A2"], account: work.id)
        #expect(s.messages.map(\.id) == [a])
        #expect(s.message(a)?.remoteID == "A2" && s.message(a)?.mailbox == .archive)
        #expect(s.count(.account(work.id, .archive)) == 1)
        #expect(s.selection == [a])
    }

    /// The Inbox sync says A was deleted (elsewhere) while a move of A was queued. When the move then fails (the item
    /// is gone), A goes: no later sync reports the deletion again.
    @Test func deletionSeenDuringAPendingMoveIsAppliedWhenTheMoveFails() {
        let s = synced(["A", "B"])
        let a = id(s, "A"), b = id(s, "B")
        s.archive([a, b])
        s.apply(page([], del: ["A", "B"], token: "t1"), account: work.id, mailbox: .inbox)
        #expect(s.message(a)?.mailbox == .archive, "the deletion may be the move's own")
        s.failed(s.outbox[0], "The specified object was not found in the store.")
        s.apply(page([], token: "t2"), account: work.id, mailbox: .inbox)
        #expect(s.message(a) == nil, "deleted on the server but shown in \(s.message(a)?.mailbox.rawValue ?? "-")")
        #expect(s.message(b) == nil)
    }

    /// A move that goes through: the source's deletion was its own, and nothing is removed.
    @Test func deletionSeenDuringAPendingMoveIsDroppedWhenTheMoveWorks() async throws {
        let s = try batchStore(response("MoveItem", movedItem("N1")), ["A"])
        let a = id(s, "A")
        s.archive([a])
        s.apply(page([], del: ["A"], token: "t1"), account: work.id, mailbox: .inbox)
        try await waitForOutbox(s)
        #expect(s.message(a)?.remoteID == "N1" && s.message(a)?.mailbox == .archive)
    }

    /// A folder whose history keeps getting a page that isn't an Exchange answer is skipped with a status; it doesn't
    /// hold up the account's other folders.
    @Test func historyAgainstANonAnswerSkipsTheFolder() async throws {
        let s = try store(answering: serviceUnavailablePage)
        await s.syncHistory()
        // Inbox comes first; the history went on to Sent, the last folder, which failed the same way.
        #expect(s.status?.hasPrefix("Sent: Unreadable EWS response") == true, "status: \(s.status ?? "nil")")
    }

    /// Throttling sets the account aside for this run only: the next run completes the folder.
    @Test func historyAfterThrottlingGoesOnNextTime() async throws {
        let file = try responseFile(serverBusy)
        let s = MailStore(accounts: [], messages: [])
        s.add(work, backend: backend(file))
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX")], account: work.id)
        await s.syncHistory()
        #expect(!s.isComplete(work.id, .inbox))
        try Data(success.utf8).write(to: file)
        await s.syncHistory()
        #expect(s.isComplete(work.id, .inbox))
    }

    // MARK: A queued change protects only the property it changes (BUG-075)

    /// A queued read change doesn't swallow a flag set on the phone.
    @Test func pendingReadChangeKeepsTheServersFlag() {
        let s = synced(["A"])
        let a = id(s, "A")
        s.toggleRead([a])  // queued: setRead true
        var flagged = remote("A"); flagged.flag = .red
        s.apply(SyncResult(upserts: [flagged], deletedRemoteIDs: [], token: "t1", more: false), account: work.id, mailbox: .inbox)
        #expect(s.message(a)?.isRead == true)
        #expect(s.message(a)?.flag != nil, "flagged on the phone, lost here")
    }

    /// A queued flag change doesn't swallow a read change from the server.
    @Test func pendingFlagChangeKeepsTheServersReadState() {
        let s = synced(["A"])
        let a = id(s, "A")
        s.setFlag(.red, for: [a])
        s.apply(SyncResult(upserts: [], deletedRemoteIDs: [], readChanges: ["A": true], token: "t1", more: false),
                account: work.id, mailbox: .inbox)
        #expect(s.message(a)?.isRead == true, "read on the phone, still unread here")
        #expect(s.message(a)?.flag == .red)
    }

    /// Nor does a queued move.
    @Test func pendingMoveKeepsTheServersReadState() {
        let s = synced(["A"])
        let a = id(s, "A")
        s.archive([a])
        s.apply(SyncResult(upserts: [], deletedRemoteIDs: [], readChanges: ["A": true], token: "t1", more: false),
                account: work.id, mailbox: .inbox)
        #expect(s.message(a)?.mailbox == .archive)
        #expect(s.message(a)?.isRead == true, "read on the phone, still unread here")
    }

    /// Launch: a move made offline last session is still queued and the moved message is in Archive on disk, not yet
    /// in memory. The Inbox check reports it (read on the phone); after loading there is one message, not two (BUG-076).
    @Test func quickCheckDuringLaunchDoesNotDuplicateAMessageMovedOfflineLastSession() {
        var moved = remote("A"); moved.mailbox = .archive
        let s = MailStore(accounts: [work, home], messages: [])
        var meta = StoredMeta()
        meta.sync = [SyncState(account: work.id, mailbox: .inbox, token: "t0", complete: true)]
        meta.outbox = [PendingChange(account: work.id, change: .move(["A"], to: .archive), previous: [remote("A")])]
        s.restore(meta)
        s.restore([remote("B")], boxes: [MailboxKey(account: work.id, mailbox: .inbox)])
        #expect(s.quickCheckRoles(work.id) == [.inbox])
        s.apply(SyncResult(upserts: [remote("A", read: true)], deletedRemoteIDs: [], token: "t1", more: false),
                account: work.id, mailbox: .inbox)
        s.finishLoading([moved])
        #expect(s.messages.filter { $0.remoteID == "A" }.map(\.mailbox) == [.archive])
    }

    // MARK: A folder removed on the server (BUG-077)

    /// Its mail goes with it: not in Flagged, not in search, not on disk; and its sync position is forgotten.
    @Test func mailOfARemovedServerFolderIsDropped() throws {
        let url = tempURL(); defer { cleanup(url) }
        let d = try MailDatabase(url: url)
        let s = MailStore(accounts: [work], messages: [])
        let x = MailboxKind.folder("X")
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "i"), RemoteFolder(role: x, id: "X", name: "Projects")], account: work.id)
        var a = remote("A"); a.subject = "Quarterly plan"; a.flag = .red
        s.apply(SyncResult(upserts: [a], deletedRemoteIDs: [], token: "x1", more: false), account: work.id, mailbox: x)
        s.apply(page(["B"], token: "i1"), account: work.id, mailbox: .inbox)
        try d.write(s.takeChanges())
        #expect(s.count(.smart(.flagged)) == 1)
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "i")], account: work.id)
        #expect(s.children(of: nil, account: work.id).isEmpty)
        #expect(s.count(.smart(.flagged)) == 0, "flagged mail of a deleted folder")
        s.searchText = "quarterly"
        #expect(s.visibleMessages.isEmpty, "search finds mail of a deleted folder")
        #expect(s.syncToken(work.id, x) == nil && !s.isComplete(work.id, x))
        try d.write(s.takeChanges())
        #expect(try d.messages().compactMap(\.remoteID) == ["B"])
        #expect(try d.meta().sync.map(\.mailbox) == [.inbox])
    }

    /// The selected folder is removed: the account's Inbox is selected instead of a mailbox without a name.
    @Test func selectedRemovedFolderKeepsATitle() {
        let s = MailStore(accounts: [work], messages: [])
        let x = MailboxKind.folder("X")
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "i"), RemoteFolder(role: x, id: "X", name: "Projects")], account: work.id)
        s.selectedMailbox = .account(work.id, x)
        #expect(s.title == "Projects")
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "i")], account: work.id)  // next launch: folder gone
        #expect(s.selectedMailbox == .account(work.id, .inbox))
        #expect(s.title != "")
    }

    /// The folder list can arrive while launch is still loading: the removed folder's stored mail, loaded after it,
    /// isn't shown and leaves the disk.
    @Test func removedFolderSeenDuringLaunchDropsItsStoredMail() throws {
        let url = tempURL(); defer { cleanup(url) }
        let x = MailboxKind.folder("X")
        do {
            let s = MailStore(accounts: [work], messages: [])
            s.setRemoteFolders([RemoteFolder(role: .inbox, id: "i"), RemoteFolder(role: x, id: "X", name: "Projects")], account: work.id)
            s.apply(SyncResult(upserts: [remote("A")], deletedRemoteIDs: [], token: "x1", more: false), account: work.id, mailbox: x)
            s.apply(page(["B"], token: "i1"), account: work.id, mailbox: .inbox)
            try MailDatabase(url: url).write(s.takeChanges())
        }
        let d = try MailDatabase(url: url)
        let s = MailStore(accounts: [work], messages: [])
        let first = [MailboxKey(account: work.id, mailbox: .inbox)]
        s.restore(try d.meta())
        s.restore(try d.messages(in: first), boxes: first)
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "i")], account: work.id)  // the first check's folder list
        s.finishLoading(try d.messages(notIn: first))
        #expect(s.messages.compactMap(\.remoteID) == ["B"])
        try d.write(s.takeChanges())
        #expect(try d.messages().compactMap(\.remoteID) == ["B"])
    }

    /// Delete twice before anything is written: a move to Trash and an erase are queued. The move renames the
    /// message; when the erase is then refused, the message comes back under its new ID, once (BUG-141).
    @Test func refusedEraseAfterARenameBringsTheMessageBackWithItsNewID() {
        let s = synced(["R1"])
        let a = id(s, "R1")
        s.delete([a])  // to Trash
        s.delete([a])  // erase from Trash
        #expect(s.outbox.map(\.change) == [.move(["R1"], to: .trash), .delete(["R1"])])
        s.renameRemote(["R1": "T1"], account: work.id)  // the move's answer
        s.failed(s.outbox[1], "Access is denied.")
        #expect(s.message(a)?.remoteID == "T1")
        var t1 = remote("T1"); t1.subject = "S R1"
        s.apply(SyncResult(upserts: [t1], deletedRemoteIDs: [], token: "d1", more: false), account: work.id, mailbox: .trash)
        #expect(s.count(.account(work.id, .trash)) == 1, "trash \(s.messages.filter { $0.mailbox == .trash }.compactMap(\.remoteID))")
    }

    // MARK: A message changed on the server drops its loaded body (BUG-103)

    /// A draft opened here and then edited elsewhere: the Drafts sync brings another subject and preview; the old
    /// body isn't kept, so the new text is fetched when it is shown, also after a relaunch.
    @Test func draftEditedOnTheServerShowsItsNewText() throws {
        let url = tempURL(); defer { cleanup(url) }
        let s = MailStore(accounts: [work], messages: [])
        var v1 = remote("D1"); v1.subject = "Offer v1"; v1.serverPreview = "Price 100"
        s.apply(SyncResult(upserts: [v1], deletedRemoteIDs: [], token: "d1", more: false), account: work.id, mailbox: .drafts)
        let id = s.messages[0].id
        s.setBody(MessageBody(text: "Price 100", attachments: [Attachment(name: "v1.pdf", size: 1000, contentType: "application/pdf")]), for: id)
        var v2 = remote("D1"); v2.subject = "Offer v2"; v2.serverPreview = "Price 250"; v2.hasAttachments = true
        s.apply(SyncResult(upserts: [v2], deletedRemoteIDs: [], token: "d2", more: false), account: work.id, mailbox: .drafts)
        try MailDatabase(url: url).write(s.takeChanges())
        let m = try #require(try launch([work], from: url).message(id))
        #expect(m.subject == "Offer v2")
        #expect(m.needsBody, "subject 'Offer v2' with body '\(m.body)'")
    }

    /// Only the text changed (same subject): the preview tells.
    @Test func editedTextWithTheSameSubjectDropsTheLoadedBody() {
        let s = MailStore(accounts: [work], messages: [])
        s.apply(page(["A"], token: "t0"), account: work.id, mailbox: .inbox)
        let a = id(s, "A")
        s.setBody(MessageBody(text: "Old text", attachments: []), for: a)
        var v2 = remote("A"); v2.serverPreview = "New text"
        s.apply(SyncResult(upserts: [v2], deletedRemoteIDs: [], token: "t1", more: false), account: work.id, mailbox: .inbox)
        #expect(s.message(a)?.needsBody == true)
        // Control: an unchanged summary (read on the phone) keeps the body.
        s.setBody(MessageBody(text: "New text", attachments: []), for: a)
        var read = v2; read.isRead = true
        s.apply(SyncResult(upserts: [read], deletedRemoteIDs: [], token: "t2", more: false), account: work.id, mailbox: .inbox)
        #expect(s.message(a)?.needsBody == false && s.message(a)?.body == "New text")
    }

    // MARK: Reply and forward of a message not opened yet (BUG-068)

    /// Like a server summary (FindItem/SyncFolderItems): no body, names only for From/To.
    func summary(_ rid: String) -> Message {
        var m = Message(accountID: work.id, from: Contact(name: "Ann Lee", email: ""), to: [Contact(name: "Me", email: "")],
                        subject: "Hi", body: "", date: Date(timeIntervalSince1970: 1_000_000),
                        remoteID: rid, serverPreview: "Can we meet on Friday?", bodyLoaded: false)
        m.conversationID = nil
        return m
    }

    /// What the server has for it. // file:// fixture
    var annsMessage: String {
        envelope("<m:GetItemResponse><m:ResponseMessages><m:GetItemResponseMessage ResponseClass=\"Success\">"
                 + "<m:ResponseCode>NoError</m:ResponseCode><m:Items><t:Message><t:ItemId Id=\"A\"/>"
                 + "<t:Body BodyType=\"Text\">Can we meet on Friday?</t:Body>"
                 + "<t:From><t:Mailbox><t:Name>Ann Lee</t:Name><t:EmailAddress>ann@x.com</t:EmailAddress></t:Mailbox></t:From>"
                 + "<t:ToRecipients><t:Mailbox><t:Name>Me</t:Name><t:EmailAddress>me@work.com</t:EmailAddress></t:Mailbox></t:ToRecipients>"
                 + "</t:Message></m:Items></m:GetItemResponseMessage></m:ResponseMessages></m:GetItemResponse>")
    }

    /// Reply from the list's context menu (or ⌘R before the body is in) on a message never opened: the body is
    /// fetched first, so the reply has the sender's address and quotes the message.
    @Test func replyToUnopenedServerMessageLoadsItFirst() async throws {
        let s = try store(answering: annsMessage)
        s.merge([summary("A")], account: work.id, mailbox: .inbox)
        let id = s.messages[0].id
        let d = await s.loadedDraft(.reply, to: id)
        #expect(d.to == "ann@x.com", "to: '\(d.to)'")
        #expect(d.body.contains("Ann Lee <ann@x.com> wrote:") && d.body.contains("> Can we meet on Friday?"), "body: \(d.body)")
        let f = await s.loadedDraft(.forward, to: id)
        #expect(f.body.contains("Can we meet on Friday?"), "body: \(f.body)")
    }

    /// Without a connection the body can't be had: the attribution shows the name alone, not "Ann Lee <>".
    @Test func replyToUnopenedMessageOfflineHasNoEmptyAddress() async {
        let s = MailStore(accounts: [work], messages: [])
        s.merge([summary("A")], account: work.id, mailbox: .inbox)
        let d = await s.loadedDraft(.reply, to: s.messages[0].id)
        #expect(!d.body.contains("<>") && d.body.contains("Ann Lee wrote:"), "body: \(d.body)")
        let f = s.draft(.forward, to: s.messages[0].id)
        #expect(!f.body.contains("<>"), "body: \(f.body)")
    }

    /// Include Attachments With Replies ▸ When Adding Recipients: writing to the sender of a message whose
    /// addresses aren't known yet is not adding a recipient.
    @Test func replyToSenderOfUnopenedMessageIsNotANewRecipient() {
        var m = summary("A"); m.hasAttachments = true
        let s = MailStore(accounts: [work], messages: [])
        s.merge([m], account: work.id, mailbox: .inbox)
        var d = s.draft(.reply, to: s.messages[0].id)
        d.to = "Ann Lee <ann@x.com>"  // the sender, typed by hand because To was empty
        #expect(!s.addsNewRecipient(d))
        d.to += ", Cy <cy@x.com>"
        #expect(s.addsNewRecipient(d))
    }
}
