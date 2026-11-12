import Foundation
import Testing
@testable import MailModel

/// The SQLite store, with a real database file in a temporary folder.
@MainActor
struct MailDatabaseTests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")
    let launch = MailboxKind.folder("L")

    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MailDatabaseTests-\(UUID())/Mail.sqlite")
    }

    func remote(_ rid: String, _ box: MailboxKind = .inbox, read: Bool = false) -> Message {
        Message(accountID: work.id, mailbox: box, from: Contact(name: "Ann", email: "ann@x.com"),
                to: [Contact(name: "Me", email: "me@work.com")], subject: "S \(rid)", body: "",
                date: Date(timeIntervalSinceReferenceDate: 800_000_000.25), isRead: read, remoteID: rid,
                serverPreview: "P \(rid)", bodyLoaded: false)
    }

    /// Every field set, including the rare ones.
    var full: Message {
        var m = Message(accountID: work.id, mailbox: launch, from: Contact(name: "Ann, Smith", email: "ann@x.com"),
                        to: [Contact(name: "Me", email: "me@work.com"), Contact(name: "Bob", email: "bob@x.com")],
                        cc: [Contact(name: "Cy", email: "")], subject: "Ünïcode ✓", body: "Line 1\nLine 2",
                        date: Date(timeIntervalSinceReferenceDate: 812_345_678.123), isRead: true, flag: .purple,
                        category: .updates, isVIP: true, attachments: [MailModel.Attachment(name: "a.pdf", size: 1234, contentType: "application/pdf"), "b, c.png"], remoteID: "R-full",
                        hasAttachments: true, serverPreview: "Preview", bodyLoaded: true,
                        invite: Invite(start: Date(timeIntervalSinceReferenceDate: 812_400_000),
                                       end: Date(timeIntervalSinceReferenceDate: 812_403_600), location: "Room 1",
                                       organizer: Contact(name: "Org", email: "org@x.com"),
                                       required: [Contact(name: "Me", email: "me@work.com")], optional: []))
        m.html = "<p>Hi</p>"
        m.htmlChecked = true
        return m
    }

    func reopen(_ url: URL) throws -> MailDatabase { try MailDatabase(url: url) }

    /// Rows written before attachments had a size and type still read, as names.
    @Test func attachmentNamesFromOlderRowsStillRead() {
        #expect(MailDatabase.attachments("a.pdf\u{1E}b.png") == ["a.pdf", "b.png"])
        #expect(MailDatabase.attachments("") == [])
        let list: [MailModel.Attachment] = [MailModel.Attachment(name: "x", size: 5, contentType: "text/plain"), "y"]
        #expect(MailDatabase.attachments(MailDatabase.attachments(list)) == list)
    }

    @Test func everyFieldOfAMessageSurvives() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let full = full, plain = remote("A")
        try MailDatabase(url: url).write(StoreChanges(upserts: [full, plain]))
        let back = try reopen(url).messages()
        #expect(Set(back) == [full, plain])
    }

    @Test func foldersSyncPositionsAndWaitingChangesSurvive() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let folders = [work.id: [Folder(box: launch, name: "Launch", parent: .inbox)]]
        let sync = [SyncState(account: work.id, mailbox: .inbox, token: "T1", complete: true),
                    SyncState(account: work.id, mailbox: launch, token: nil, complete: false)]
        let outbox = [PendingChange(account: work.id, change: .setRead(["A"], true), previous: [remote("A")]),
                      PendingChange(account: work.id, change: .move(["B"], to: launch), previous: [remote("B")])]
        try MailDatabase(url: url).write(StoreChanges(sync: sync, folders: folders, outbox: outbox))
        let meta = try reopen(url).meta()
        #expect(meta.folders == folders)
        #expect(Set(meta.sync) == Set(sync))
        #expect(meta.outbox == outbox)  // in order
    }

    @Test func someMailboxesLoadFirstAndTheRestAfter() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = try MailDatabase(url: url)
        try db.write(StoreChanges(upserts: [remote("I1"), remote("I2"), remote("S1", .sent), remote("L1", launch)]))
        let first = try db.messages(in: [MailboxKey(account: work.id, mailbox: .inbox)])
        #expect(Set(first.compactMap(\.remoteID)) == ["I1", "I2"])
        let rest = try db.messages(notIn: [MailboxKey(account: work.id, mailbox: .inbox)])
        #expect(Set(rest.compactMap(\.remoteID)) == ["S1", "L1"])
    }

    @Test func removedMessagesAreGone() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let a = remote("A"), b = remote("B")
        let db = try MailDatabase(url: url)
        try db.write(StoreChanges(upserts: [a, b]))
        try db.write(StoreChanges(removed: [a.id]))
        #expect(try reopen(url).messages() == [b])
    }

    // MARK: Change tracking in the store

    /// A server account's store whose changes are written after every step; the file must then hold exactly
    /// the account's messages as they are in memory.
    final class Harness {
        let url: URL, db: MailDatabase, store: MailStore, account: UUID
        @MainActor init(_ s: MailStore, account: UUID, url: URL) throws {
            self.url = url; store = s; self.account = account
            db = try MailDatabase(url: url)
        }
        @MainActor func check(_ step: String) throws {
            try db.write(store.takeChanges())
            let stored = try MailDatabase(url: url).messages()
            let memory = store.messages.filter { $0.accountID == account }
            #expect(Set(stored) == Set(memory), "after \(step)")
            #expect(stored.count == memory.count, "after \(step)")
        }
    }

    @Test func everyChangeToServerMailIsWritten() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = MailStore(accounts: [work, home], messages: [])
        let h = try Harness(s, account: work.id, url: url)
        func id(_ rid: String) -> Message.ID { s.messages.first { $0.remoteID == rid }!.id }

        s.apply(SyncResult(upserts: ["A", "B", "C", "D", "E"].map { remote($0) }, deletedRemoteIDs: [], token: "t", more: false),
                account: work.id, mailbox: .inbox)
        try h.check("sync")
        s.toggleRead([id("A")]); try h.check("toggleRead")
        s.setFlag(.green, for: [id("B")]); try h.check("setFlag")
        s.move([id("C")], to: launch); try h.check("move")
        s.archive([id("D")]); try h.check("archive")
        s.toggleJunk([id("E")]); try h.check("toggleJunk")
        s.markAllRead(in: .account(work.id, .inbox)); try h.check("markAllRead")
        s.drop([id("E")], on: .account(work.id, .inbox)); try h.check("drop")
        s.delete([id("A")]); try h.check("delete to Trash")
        s.delete([id("A")]); try h.check("erase from Trash")
        s.renameRemote(["B": "B2"], account: work.id); try h.check("renameRemote")
        s.setBody(MessageBody(text: "Full", attachments: ["x.pdf"], html: "<b>x</b>"), for: id("B2")); try h.check("setBody")
        s.merge([remote("F", .sent)], deleted: ["D"], reads: ["E": false], account: work.id, mailbox: .sent)
        try h.check("merge with deletion and read change")
        s.apply([SyncResult(upserts: [remote("G", .sent)], deletedRemoteIDs: ["F"], token: "p", more: false)],
                account: work.id, mailbox: .sent)
        try h.check("apply pages")
        var invite = remote("H"); invite.invite = full.invite
        s.merge([invite], account: work.id, mailbox: .inbox)
        s.respond(.accept, to: id("H")); try h.check("respond")
        s.respond(InviteReply(response: .decline, comment: "No"), to: id("H")); try h.check("respond with reply")
        let pending = try #require(s.outbox.first)
        s.failed(pending, "refused"); try h.check("failed change undone")
        s.failed(PendingChange(account: work.id, change: .send(Draft(accountID: work.id, subject: "Unsent")), previous: []), "offline")
        try h.check("failed send kept as local draft")
        #expect(s.messages.contains { $0.subject == "Unsent" && $0.remoteID == nil })
    }

    @Test func syncPositionsFoldersAndOutboxAreWrittenWhenTheyChange() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = MailStore(accounts: [work], messages: [])
        let db = try MailDatabase(url: url)
        s.apply(SyncResult(upserts: [remote("A")], deletedRemoteIDs: [], token: "t1", more: false), account: work.id, mailbox: .inbox)
        s.setFolders([Folder(box: launch, name: "Launch", parent: .inbox)], account: work.id)
        s.toggleRead([s.messages[0].id])
        try db.write(s.takeChanges())
        #expect(s.takeChanges().isEmpty)
        let meta = try MailDatabase(url: url).meta()
        #expect(meta.sync == [SyncState(account: work.id, mailbox: .inbox, token: "t1", complete: true)])
        #expect(meta.folders[work.id]?.map(\.name) == ["Launch"])
        #expect(meta.outbox.map(\.change) == [.setRead(["A"], true)])
    }

    @Test func sampleAccountsAreNotWritten() throws {
        let s = MailStore(accounts: [home], messages: [
            Message(accountID: home.id, from: Contact(name: "B", email: "b@x.com"), to: [], subject: "Local", body: "x", date: .now),
        ])
        s.toggleRead([s.messages[0].id])
        #expect(s.takeChanges().isEmpty)
    }

    // MARK: Loading in stages

    @Test func inboxFirstThenTheRestWithoutDuplicates() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = try MailDatabase(url: url)
        try db.write(StoreChanges(upserts: [remote("I1"), remote("S1", .sent), remote("L1", launch)],
                                  sync: [SyncState(account: work.id, mailbox: .inbox, token: "ti", complete: true),
                                         SyncState(account: work.id, mailbox: .sent, token: "ts", complete: true)],
                                  folders: [work.id: [Folder(box: launch, name: "Launch")]]))
        let s = MailStore(accounts: [work], messages: [])
        let inbox = [MailboxKey(account: work.id, mailbox: .inbox)]
        s.restore(try db.meta())
        s.restore(try db.messages(in: inbox), boxes: inbox)
        #expect(s.isLoading)
        #expect(s.count(.account(work.id, .inbox)) == 1)
        #expect(s.children(of: nil, account: work.id).map(\.name) == ["Launch"])
        // Only loaded mailboxes are checked with the server meanwhile: Sent isn't in memory yet.
        s.selectedMailbox = .account(work.id, .sent)
        #expect(s.quickCheckRoles(work.id) == [.inbox])
        // The user moves the inbox message to Sent before Sent has loaded; memory wins over the stored copy.
        s.move([s.messages[0].id], to: .sent)
        s.finishLoading(try db.messages(notIn: inbox))
        #expect(!s.isLoading)
        #expect(s.messages.count == 3)
        #expect(s.count(.account(work.id, .sent)) == 2)
        #expect(s.quickCheckRoles(work.id) == [.inbox, .sent])
        #expect(s.takeChanges().resolved().upserts.map(\.remoteID) == ["I1"])  // only the moved one; loading isn't a change
    }

    // MARK: Moving from the JSON cache

    /// An import stopped halfway (quit, crash) leaves only a temporary file; the next launch imports again.
    @Test func anInterruptedImportIsRedone() async throws {
        let dir = tempURL().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cacheURL = dir.appendingPathComponent("Cache.json"), dbURL = dir.appendingPathComponent("Mail.sqlite")
        let old = MailStore(accounts: [work], messages: [])
        old.apply(SyncResult(upserts: [remote("A")], deletedRemoteIDs: [], token: "t", more: false), account: work.id, mailbox: .inbox)
        try old.cache().save(to: cacheURL)
        // What the interrupted import left: a database with its tables but no mail, under the temporary name.
        _ = try MailDatabase(url: MailDatabase.importingURL(for: dbURL))
        #expect(!FileManager.default.fileExists(atPath: dbURL.path))

        let s = MailStore(accounts: [work], messages: [])
        let db = try #require(try await MailDatabase.importCache(from: cacheURL, into: dbURL, store: s))
        #expect(try db.messages().map(\.remoteID) == ["A"])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("importing") }
        #expect(leftovers.isEmpty)
    }

    @Test func theJSONCacheIsImportedOnce() async throws {
        let dir = tempURL().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cacheURL = dir.appendingPathComponent("Cache.json"), dbURL = dir.appendingPathComponent("Mail.sqlite")
        let old = MailStore(accounts: [work], messages: [])
        old.apply(SyncResult(upserts: [remote("A"), remote("B")], deletedRemoteIDs: [], token: "t", more: false),
                  account: work.id, mailbox: .inbox)
        old.setFlag(.orange, for: [old.messages[0].id])  // a colour exists only on this Mac
        try old.cache().save(to: cacheURL)

        let s = MailStore(accounts: [work], messages: [])
        let db = try #require(try await MailDatabase.importCache(from: cacheURL, into: dbURL, store: s))
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
        #expect(FileManager.default.fileExists(atPath: cacheURL.path + ".imported"))
        #expect(Set(try db.messages()) == Set(old.messages))
        #expect(Set(s.messages) == Set(old.messages))
        #expect(try db.meta().outbox == old.outbox)
        // No cache file, nothing to import.
        #expect(try await MailDatabase.importCache(from: cacheURL, into: dbURL, store: s) == nil)
    }
}
