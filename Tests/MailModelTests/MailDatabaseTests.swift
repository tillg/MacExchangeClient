import Foundation
import SQLite3
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
        m.conversationID = "CONV"
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

    /// BUG-186: Reply-To is stored; a message whose body was never asked for it keeps nil (not known yet).
    @Test func replyToSurvives() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var m = remote("RT"); m.replyTo = [Contact(name: "Support", email: "support@x.com")]
        var empty = remote("E"); empty.replyTo = []
        try MailDatabase(url: url).write(StoreChanges(upserts: [m, empty, remote("N")]))
        let back = Dictionary(uniqueKeysWithValues: try reopen(url).messages().map { ($0.remoteID!, $0.replyTo) })
        #expect(back["RT"] == [Contact(name: "Support", email: "support@x.com")])
        #expect(back["E"] == [])
        #expect(back["N"] == .some(nil))
    }

    /// BUG-186: a database from before Reply-To gets the column; its loaded bodies stay loaded (Reply fetches Reply-To
    /// when needed, `loadedDraft`), so nothing is fetched again just to open a message.
    @Test func bodiesLoadedBeforeReplyToStayLoaded() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var m = remote("L"); m.body = "Text"; m.bodyLoaded = true; m.htmlChecked = true; m.replyTo = []
        try MailDatabase(url: url).write(StoreChanges(upserts: [m, remote("U")]))
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        #expect(sqlite3_exec(raw, "ALTER TABLE messages DROP COLUMN reply_to", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)
        let back = Dictionary(uniqueKeysWithValues: try reopen(url).messages().map { ($0.remoteID!, $0) })
        #expect(back["L"]?.needsBody == false)
        #expect(back["L"]?.replyTo == nil)
        #expect(back["L"]?.body == "Text")
        #expect(back["U"]?.htmlChecked == nil)
    }

    /// A meeting response ("Accepted: …") stored with an invite, as bodies loaded before BUG-038 were, reads without
    /// it: no answer buttons on someone's answer.
    @Test func aStaleInviteOnAMeetingResponseIsDroppedOnLoad() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var m = full
        m.isInvite = false
        try MailDatabase(url: url).write(StoreChanges(upserts: [m]))
        let back = try #require(try reopen(url).messages().first)
        #expect(back.invite == nil)
        #expect(back.body == m.body)
    }

    /// A NUL character in a subject or body is stored, not the end of the text, and a search with one never throws.
    @Test func nulCharacterInSubjectAndBodySurvives() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var m = remote("N")
        m.subject = "before\u{0}after"; m.body = "line one\u{0}line two"; m.bodyLoaded = true
        let d = try MailDatabase(url: url)
        try d.write(StoreChanges(upserts: [m]))
        let back = try reopen(url).messages()
        #expect(back.first?.subject.debugDescription == m.subject.debugDescription)
        #expect(back.first?.body.debugDescription == m.body.debugDescription)
        #expect(throws: Never.self) { _ = try d.search("hel\u{0}\"lo", accounts: nil) }
        #expect(try d.search("after", accounts: nil) == [m.id])
    }

    /// Rows written before (the text cut at a NUL, as the old binding stored it) read as they always did.
    @Test func rowsWrittenBeforeReadAsBefore() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let m = remote("O")
        try MailDatabase(url: url).write(StoreChanges(upserts: [m]))
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        var st: OpaquePointer?
        #expect(sqlite3_prepare_v2(raw, "UPDATE messages SET subject = ?", -1, &st, nil) == SQLITE_OK)
        sqlite3_bind_text(st, 1, "old\u{0}tail", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        #expect(sqlite3_step(st) == SQLITE_DONE)
        sqlite3_finalize(st)
        sqlite3_close(raw)
        var old = m
        old.subject = "old"
        #expect(try reopen(url).messages() == [old])
    }

    /// Names, addresses and file names holding the list separators (or their escape) come back as they were.
    @Test func separatorCharactersInListsSurvive() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var m = remote("S")
        m.to = [Contact(name: "A\u{1E}B", email: "a@x.com"), Contact(name: "C", email: "c\u{1F}d@x.com")]
        m.cc = [Contact(name: "Unit\u{1F}Sep\u{1D}", email: "u@x.com"), Contact(name: "\u{1D}1", email: "")]
        m.attachments = [MailModel.Attachment(name: "report\u{1E}2026.pdf", size: 10, contentType: "application/pdf"),
                         MailModel.Attachment(name: "a\u{1F}b.txt", size: 3, contentType: "text/plain")]
        m.hasAttachments = true
        try MailDatabase(url: url).write(StoreChanges(upserts: [m]))
        let back = try reopen(url).messages().first
        #expect(back?.to == m.to)
        #expect(back?.cc == m.cc)
        #expect(back?.attachments == m.attachments)
    }

    /// Lists written before the escaping read as they always did.
    @Test func listsWrittenBeforeReadAsBefore() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let m = remote("L")
        try MailDatabase(url: url).write(StoreChanges(upserts: [m]))
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        let old = "UPDATE messages SET to_list = 'Ann, Smith' || char(31) || 'ann@x.com' || char(30) || 'Bob' || char(31), "
            + "cc_list = 'Cy', attachments = 'a.pdf' || char(31) || '12' || char(31) || 'application/pdf' || char(30) || 'b.png'"
        #expect(sqlite3_exec(raw, old, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)
        let back = try reopen(url).messages().first
        #expect(back?.to == [Contact(name: "Ann, Smith", email: "ann@x.com"), Contact(name: "Bob", email: "")])
        #expect(back?.cc == [Contact(name: "Cy", email: "")])
        #expect(back?.attachments == [MailModel.Attachment(name: "a.pdf", size: 12, contentType: "application/pdf"), "b.png"])
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

    /// A Cache.json.imported from an earlier import (copied back to go back) doesn't fail this one: the cache
    /// gets the next free name and the earlier copy stays.
    @Test func importWhenAnImportedCacheIsAlreadyThere() async throws {
        let dir = tempURL().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cacheURL = dir.appendingPathComponent("Cache.json"), dbURL = dir.appendingPathComponent("Mail.sqlite")
        let old = MailStore(accounts: [work], messages: [])
        old.apply(SyncResult(upserts: [remote("A")], deletedRemoteIDs: [], token: "t", more: false), account: work.id, mailbox: .inbox)
        try old.cache().save(to: cacheURL)
        try FileManager.default.copyItem(at: cacheURL, to: cacheURL.appendingPathExtension("imported"))
        let s = MailStore(accounts: [work], messages: [])
        let db = try #require(try await MailDatabase.importCache(from: cacheURL, into: dbURL, store: s))
        #expect(try db.messages().map(\.remoteID) == ["A"])
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
        #expect(FileManager.default.fileExists(atPath: cacheURL.path + ".imported"))
        #expect(FileManager.default.fileExists(atPath: cacheURL.path + ".imported-2"))
    }

    /// A Cache.json that can't be decoded is set aside (never deleted) and an empty database is created, so the
    /// next launch doesn't fail the same way again; mail comes back from the server.
    @Test func anUnreadableCacheIsSetAsideAndTheDatabaseIsCreated() async throws {
        let dir = tempURL().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cacheURL = dir.appendingPathComponent("Cache.json"), dbURL = dir.appendingPathComponent("Mail.sqlite")
        let broken = Data("{\"accounts\": [ truncated".utf8)
        try broken.write(to: cacheURL)
        // Launch after launch, as AppSetup.loadMail does: import while there is no database.
        var errors: [String] = []
        var last: MailStore?
        for _ in 0..<3 where !FileManager.default.fileExists(atPath: dbURL.path) {
            let s = MailStore(accounts: [work], messages: [])
            last = s
            do { _ = try await MailDatabase.importCache(from: cacheURL, into: dbURL, store: s) } catch { errors.append(error.localizedDescription) }
        }
        #expect(errors.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dbURL.path))
        #expect(try MailDatabase(url: dbURL).count() == 0)
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
        #expect(try Data(contentsOf: dir.appendingPathComponent("Cache.json.unreadable")) == broken)
        #expect(last?.status?.contains("Cache.json.unreadable") == true)
    }

    /// Cache.json as written by builds up to b75308d, where attachments were plain names: it still imports,
    /// with its waiting change.
    @Test func cacheWithAttachmentNamesOnlyStillImports() async throws {
        let json = #"{"accounts":["00000000-0000-0000-0000-000000000001",{"complete":["inbox"],"messages":[{"accountID":"00000000-0000-0000-0000-000000000001","attachments":["Rechnung.pdf"],"body":"Hallo","bodyLoaded":true,"category":"primary","cc":[],"date":800000000,"from":{"email":"ann@x.com","name":"Ann"},"hasAttachments":true,"id":"00000000-0000-0000-0000-000000000002","isRead":false,"isVIP":false,"mailbox":"inbox","remoteID":"R1","subject":"S","to":[]}],"outbox":[{"account":"00000000-0000-0000-0000-000000000001","change":{"move":{"_0":["R1"],"to":"archive"}},"id":"00000000-0000-0000-0000-000000000003","previous":[]}],"syncTokens":["inbox","T1"]}]}"#
        let dir = tempURL().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cacheURL = dir.appendingPathComponent("Cache.json"), dbURL = dir.appendingPathComponent("Mail.sqlite")
        try Data(json.utf8).write(to: cacheURL)
        #expect(MailCache.load(from: cacheURL) != nil)
        let acct = Account(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "W", address: "w@x.com")
        let s = MailStore(accounts: [acct], messages: [])
        let db = try #require(try await MailDatabase.importCache(from: cacheURL, into: dbURL, store: s))
        #expect(s.messages.first?.attachments == ["Rechnung.pdf"])
        #expect(s.outbox.map(\.change) == [.move(["R1"], to: .archive)])
        #expect(try db.messages().first?.attachments == ["Rechnung.pdf"])
    }

    /// An outbox row written before attachments had a size (9f0dcba..94d679c): `previous` holds the message
    /// with attachment names only. The waiting change must not be dropped.
    @Test func outboxRowWithAttachmentNamesOnlyStillLoads() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try MailDatabase(url: url)
        let change = #"{"account":"00000000-0000-0000-0000-000000000001","change":{"move":{"_0":["R1"],"to":"archive"}},"id":"00000000-0000-0000-0000-000000000003","previous":[{"accountID":"00000000-0000-0000-0000-000000000001","attachments":["Vertrag.pdf"],"body":"x","bodyLoaded":true,"category":"primary","cc":[],"date":800000000,"from":{"email":"ann@x.com","name":"Ann"},"hasAttachments":true,"id":"00000000-0000-0000-0000-000000000002","isRead":true,"isVIP":false,"mailbox":"inbox","remoteID":"R1","subject":"S","to":[]}]}"#
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        #expect(sqlite3_exec(raw, "INSERT INTO outbox VALUES(0, CAST('\(change)' AS BLOB))", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)
        let outbox = try reopen(url).meta().outbox
        #expect(outbox.map(\.change) == [.move(["R1"], to: .archive)])
        #expect(outbox.first?.previous.first?.attachments == ["Vertrag.pdf"])
    }

    // MARK: Search (FTS5)

    func mail(_ subject: String, from: Contact = Contact(name: "Ann", email: "ann@x.com"), to: [Contact] = [],
              preview: String? = nil, body: String = "", account: Account? = nil, minutesAgo: Double = 0) -> Message {
        Message(accountID: (account ?? work).id, from: from, to: to, subject: subject, body: body,
                date: Date(timeIntervalSinceReferenceDate: 800_000_000 - minutesAgo * 60), remoteID: subject,
                serverPreview: preview, bodyLoaded: !body.isEmpty)
    }

    /// A database with these messages written, ready to search.
    func searchable(_ msgs: [Message]) throws -> (MailDatabase, URL) {
        let url = tempURL()
        let db = try MailDatabase(url: url)
        try db.write(StoreChanges(upserts: msgs))
        try db.prepareSearch()
        return (db, url)
    }

    @Test func searchFindsEveryIndexedField() throws {
        let m = mail("Quarterly report", from: Contact(name: "Bob Builder", email: "bob.builder@acme.com"),
                     to: [Contact(name: "Carol", email: "carol.king@corp.com")], preview: "Kickoff agenda",
                     body: "Bring the spreadsheet")
        let (db, url) = try searchable([m, mail("Other")])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        for q in ["quarterly", "builder", "acme", "carol", "king", "kickoff", "spreadsheet"] {
            #expect(try db.search(q, accounts: nil) == [m.id], "\(q)")
        }
    }

    /// Accents don't matter in Greek either, typed with or without the tonos; Latin keeps working.
    @Test(arguments: [("καλημερα", "Καλημέρα σας"), ("αθηνα", "Ταξίδι στην Αθήνα"), ("ελληνικα", "ΕΛΛΗΝΙΚΆ"),
                      ("ελληνικά", "ΕΛΛΗΝΙΚΑ"), ("καλημ", "Καλημέρα"), ("cafe", "Café"), ("zurich", "Zürich"),
                      ("sao", "São Paulo")])
    func searchIgnoresAccentsOfGreekToo(query: String, subject: String) throws {
        let m = mail(subject)
        let (db, url) = try searchable([m, mail("Other")])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try db.search(query, accounts: nil) == [m.id], "\(query) → \(subject)")
    }

    /// Chinese and Japanese are written without spaces: a word inside a sentence is found, also next to other words.
    @Test func searchFindsChineseAndJapaneseWordsInsideSentences() throws {
        let zh = mail("明天的会议取消了"), ja = mail("会議の議事録を送ります", body: "Budget attached"), pct = mail("50%折扣")
        let (db, url) = try searchable([zh, ja, pct, mail("Other"), mail("50x折扣")])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try db.search("明天", accounts: nil) == [zh.id])
        #expect(try db.search("会议", accounts: nil) == [zh.id])
        #expect(try db.search("議事録", accounts: nil) == [ja.id])
        #expect(try db.search("議事録 budget", accounts: nil) == [ja.id])
        #expect(try db.search("議事録 other", accounts: nil) == [])
        #expect(try db.search("%折扣", accounts: nil) == [pct.id])
    }

    @Test func searchMatchesWordPrefixesNotFragments() throws {
        let m = mail("Rechnung März")
        let (db, url) = try searchable([m])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try db.search("rech", accounts: nil) == [m.id])
        #expect(try db.search("chnung", accounts: nil) == [])
    }

    @Test func searchIgnoresCaseAndDiacritics() throws {
        let m = mail("Hello", from: Contact(name: "Jürgen Müller", email: "j@x.com"))
        let (db, url) = try searchable([m])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try db.search("muller", accounts: nil) == [m.id])
        #expect(try db.search("MÜLLER", accounts: nil) == [m.id])
    }

    @Test func searchANDsWordsAcrossFields() throws {
        let invoice = mail("Invoice", from: Contact(name: "Bob", email: "b@x.com"))
        let lunch = mail("Lunch", from: Contact(name: "Bob", email: "b@x.com"))
        let (db, url) = try searchable([invoice, lunch])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try db.search("bob invoice", accounts: nil) == [invoice.id])
        #expect(Set(try db.search("bob", accounts: nil)) == [invoice.id, lunch.id])
    }

    @Test func hostileSearchInputNeverThrows() throws {
        let m = mail("Bob says hi")
        let (db, url) = try searchable([m])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        for q in ["\"", "-x", "AND (", "*", "\"\"", "bob -", "bob \"", "NEAR(", "a:b", "^", "  ", ""] {
            #expect(throws: Never.self, "\(q)") { _ = try db.search(q, accounts: nil) }
        }
        #expect(try db.search("bob -", accounts: nil) == [m.id])
        #expect(try db.search("", accounts: nil) == [])
    }

    /// A rewritten message is found by its new words only; a removed one not at all.
    @Test func writesKeepTheSearchIndexExact() throws {
        var m = mail("Oldword")
        let (db, url) = try searchable([m])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        m.subject = "Newword"
        try db.write(StoreChanges(upserts: [m]))
        #expect(try db.search("newword", accounts: nil) == [m.id])
        #expect(try db.search("oldword", accounts: nil) == [])
        // A change to no indexed text (read, mailbox) skips the index and keeps it matching the table.
        m.isRead.toggle(); m.mailbox = .archive
        try db.write(StoreChanges(upserts: [m]))
        #expect(try db.search("newword", accounts: nil) == [m.id])
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        #expect(sqlite3_exec(raw, "INSERT INTO messages_fts(messages_fts, rank) VALUES('integrity-check', 1)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)
        try db.write(StoreChanges(removed: [m.id]))
        #expect(try db.search("newword", accounts: nil) == [])
        #expect(try db.messages().isEmpty)
    }

    @Test func searchIsNewestFirstAndLimited() throws {
        let msgs = (0..<5).map { mail("Note \($0)", minutesAgo: Double($0)) }
        let (db, url) = try searchable(msgs.shuffled())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try db.search("note", accounts: nil) == msgs.map(\.id))
        #expect(try db.search("note", accounts: nil, limit: 2) == Array(msgs.prefix(2).map(\.id)))
    }

    @Test func searchKeepsToTheGivenAccounts() throws {
        let w = mail("Shared word"), h = mail("Shared word too", account: home)
        let (db, url) = try searchable([w, h])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try db.search("shared", accounts: [home.id]) == [h.id])
        #expect(Set(try db.search("shared", accounts: nil)) == [w.id, h.id])
    }

    /// BUG-248: a search's own notice (the 2,000 limit) doesn't erase another notice; clearing the search brings it back.
    @Test func searchNoticeDoesNotEraseAnotherNotice() async throws {
        let msgs = (0..<2001).map { mail("Report \($0)", minutesAgo: Double($0)) }
        let (db, url) = try searchable(msgs)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = MailStore(accounts: [work], messages: msgs)
        s.searchDebounce = .zero
        s.searcher = { q, a in try db.search(q, accounts: a) }
        let notice = "Couldn't send “Budget”: The server refused it"
        s.status = notice
        s.searchText = "report"
        await s.searchTask?.value
        #expect(s.status == "Showing the newest 2,000 results")
        s.searchText = ""
        #expect(s.status == notice)
    }

    /// Trash and Junk are left out before the 2,000 limit, so newer hits there can't crowd out real ones.
    @Test func trashAndJunkHitsDontCrowdOutResults() async throws {
        var msgs: [Message] = []
        for i in 0..<2100 {
            var m = mail("Rechnung trash \(i)", minutesAgo: Double(i)); m.mailbox = i % 2 == 0 ? .trash : .junk
            msgs.append(m)
        }
        for i in 0..<10 { msgs.append(mail("Rechnung inbox \(i)", minutesAgo: Double(10_000 + i))) }
        let (db, url) = try searchable(msgs)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try db.search("rechnung", accounts: nil).count == 10)
        let s = MailStore(accounts: [work], messages: msgs)
        s.searchDebounce = .zero
        s.searcher = { q, a in try db.search(q, accounts: a) }
        s.searchText = "rechnung"
        await s.searchTask?.value
        #expect(s.visibleMessages.count == 10)
        #expect(s.status != MailStore.limitNotice, "status says \(s.status ?? "") over \(s.visibleMessages.count) results")
    }

    /// A database from before search: no index, version 0. `prepareSearch` builds the index once.
    @Test func anOlderDatabaseGetsItsSearchIndexOnce() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let m = mail("Legacy subject")
        try MailDatabase(url: url).write(StoreChanges(upserts: [m]))
        // Take it back to the old schema.
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        #expect(sqlite3_exec(raw, """
            DROP TRIGGER IF EXISTS messages_fts_insert; DROP TRIGGER IF EXISTS messages_fts_delete;
            DROP TRIGGER IF EXISTS messages_fts_update; DROP TABLE IF EXISTS messages_fts;
            DROP INDEX IF EXISTS messages_date; PRAGMA user_version = 0;
            """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)

        let db = try reopen(url)
        #expect(try db.prepareSearch() == true)
        #expect(try db.search("legacy", accounts: nil) == [m.id])
        #expect(try db.schemaVersion() == 1)
        // Written after the migration: indexed by the triggers.
        let n = mail("Fresh subject")
        try db.write(StoreChanges(upserts: [n]))
        #expect(try db.search("fresh", accounts: nil) == [n.id])
        #expect(try reopen(url).prepareSearch() == false)
    }

    /// A database from before conversations gets the column, and its folders sync again from the start so every
    /// message already on the Mac learns which conversation it belongs to. Nothing else is lost.
    @Test func anOlderDatabaseGetsConversationsAndSyncsAgain() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let m = remote("A")
        let sync = [SyncState(account: work.id, mailbox: .inbox, token: "T1", complete: true)]
        try MailDatabase(url: url).write(StoreChanges(upserts: [m], sync: sync))
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        #expect(sqlite3_exec(raw, "ALTER TABLE messages DROP COLUMN conversation", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)

        let db = try reopen(url)
        #expect(try db.messages() == [m])
        #expect(try db.meta().sync == [SyncState(account: work.id, mailbox: .inbox, token: nil, complete: false)])
        var c = m; c.conversationID = "C"
        try db.write(StoreChanges(upserts: [c]))
        #expect(try reopen(url).messages() == [c])
        #expect(try reopen(url).meta().sync == [SyncState(account: work.id, mailbox: .inbox, token: nil, complete: false)])
    }

    /// A new database is searchable at once, without a rebuild.
    @Test func aNewDatabaseNeedsNoRebuild() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = try MailDatabase(url: url)
        #expect(try db.schemaVersion() == 1)
        try db.write(StoreChanges(upserts: [mail("Brandnew")]))
        #expect(try db.prepareSearch() == false)
        #expect(try db.search("brandnew", accounts: nil).count == 1)
    }

    /// Search reads on its own connection: neither an open write transaction nor a busy write queue holds it up.
    @Test func searchRunsWhileAWriteIsInProgress() throws {
        let m = mail("Concurrent")
        let (db, url) = try searchable([m])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let inTransaction = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        db.holdWriteTransaction { inTransaction.signal(); release.wait() }
        inTransaction.wait()
        defer { release.signal() }
        #expect(try db.search("concurrent", accounts: nil) == [m.id])
    }

    /// Every Cache.json predates conversations: like a database from before them, the imported folders sync once more
    /// from the start, so the imported mail learns its conversation (BUG-058).
    @Test func importedCacheSyncsAgainToLearnConversations() async throws {
        let dir = tempURL().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cacheURL = dir.appendingPathComponent("Cache.json"), dbURL = dir.appendingPathComponent("Mail.sqlite")
        let old = MailStore(accounts: [work], messages: [])
        old.apply(SyncResult(upserts: [remote("A"), remote("B")], deletedRemoteIDs: [], token: "T-old", more: false),
                  account: work.id, mailbox: .inbox)
        try old.cache().save(to: cacheURL)
        let s = MailStore(accounts: [work], messages: [])
        let d = try #require(try await MailDatabase.importCache(from: cacheURL, into: dbURL, store: s))
        #expect(s.messages.count == 2)
        #expect(s.syncToken(work.id, .inbox) == nil && !s.isComplete(work.id, .inbox),
                "imported store: token \(s.syncToken(work.id, .inbox) ?? "nil"), complete \(s.isComplete(work.id, .inbox))")
        let stored = try d.meta().sync
        #expect(stored.allSatisfy { $0.token == nil && !$0.complete }, "stored sync: \(stored)")
    }

    /// BUG-176: a file of 2 GiB or more kept with a draft (or a send waiting in the outbox) is bound with
    /// `Int32(v.count)`, which traps: the save crashes the app instead of failing.
    @Test func aHugeKeptFileDoesNotCrashTheSave() async {
        await #expect(processExitsWith: .success) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MailDatabaseTests-big-\(UUID())")
            defer { try? FileManager.default.removeItem(at: dir) }
            let db = try! MailDatabase(url: dir.appendingPathComponent("Mail.sqlite"))
            let big = Data(count: Int(Int32.max) + 1)  // zero pages: not touched before the bind
            _ = try? db.write(StoreChanges(files: [UUID(): [big]]))
        }
    }

    /// BUG-175: a Mail.sqlite that isn't a database (damaged file) makes every launch fail with "Couldn't load mail
    /// from disk … Changes aren't saved until relaunch", and a relaunch fails the same way: nothing is ever saved
    /// again. Cache.json in the same situation is set aside (DECISIONS #d-bug-009).
    @Test func aDamagedDatabaseFileIsSetAsideAndANewOneCreated() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MailDatabaseTests-bad-\(UUID())")
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
        #expect(kept == ["Mail.sqlite.unreadable"], "the damaged file should be kept aside, never deleted: \(kept)")
        #expect(opened?.setAside?.lastPathComponent == "Mail.sqlite.unreadable")
    }
}
