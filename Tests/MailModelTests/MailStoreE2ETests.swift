import Foundation
import Testing
@testable import MailModel

/// User scenarios through MailStore and MailDatabase: what is saved, selected and loaded.
@MainActor
struct MailStoreE2ETests {
    let a = Account(name: "Exchange", address: "me@work.com")
    let home = Account(name: "Home", address: "me@home.com")

    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("e2e-\(UUID().uuidString)")
            .appendingPathComponent("Mail.sqlite")
    }

    func server(_ rid: String, read: Bool = false, flagged: Bool = false, minutes: Int = 0) -> Message {
        Message(accountID: UUID(), from: Contact(name: "Ann", email: "ann@x.com"), to: [Contact(name: "Me", email: "me@work.com")],
                subject: "S \(rid)", body: "", date: Date(timeIntervalSince1970: 1_700_000_000 + Double(minutes) * 60), isRead: read,
                flag: flagged ? .red : nil, remoteID: rid, serverPreview: "p \(rid)", bodyLoaded: false)
    }

    func page(_ ups: [Message], del: [String] = [], token: String = "t", more: Bool = false) -> SyncResult {
        SyncResult(upserts: ups, deletedRemoteIDs: del, token: token, more: more)
    }

    /// What `AppSetup.loadMail` does at launch: meta, the Inboxes, then the rest.
    func launch(_ accounts: [Account], from url: URL) throws -> MailStore {
        let d = try MailDatabase(url: url)
        let s = MailStore(accounts: accounts, messages: [])
        let first = accounts.map { MailboxKey(account: $0.id, mailbox: .inbox) }
        s.restore(try d.meta())
        s.restore(try d.messages(in: first), boxes: first)
        s.finishLoading(try d.messages(notIn: first))
        return s
    }

    // MARK: Saving only what changed (BUG-120, BUG-121)

    /// Mark All as Read on a mailbox where one message is unread writes one row, not every message.
    @Test func markAllReadWritesOnlyTheMessagesItChanged() {
        let s = MailStore(accounts: [a], messages: [])
        s.apply(page((0..<1000).map { server("R\($0)", read: $0 != 7) }), account: a.id, mailbox: .inbox)
        _ = s.takeChanges()
        s.markAllRead(in: .account(a.id, .inbox))
        let written = s.takeChanges().resolved().upserts
        #expect(s.outbox.count == 1)
        #expect(written.count == 1, "Mark All as Read on 1 unread of 1,000 rewrites \(written.count) rows")
    }

    /// Setting the flag colour a message already has, opening a read message or moving it where it is writes nothing.
    @Test func noOpActionsWriteNothing() {
        let s = MailStore(accounts: [a], messages: [])
        s.apply(page([server("R1", read: true, flagged: true)]), account: a.id, mailbox: .inbox)
        _ = s.takeChanges()
        let id = s.messages[0].id
        s.setFlag(.red, for: [id])
        s.selection = [id]
        s.markSelectionRead()
        s.move([id], to: .inbox)
        #expect(s.takeChanges().resolved().upserts.isEmpty)
    }

    /// Archiving a whole opened Inbox (2,870 messages, half with bodies) keeps the outbox small: the queued
    /// changes don't carry the message bodies, so one more flag doesn't rewrite megabytes.
    @Test func archivingAWholeInboxKeepsTheOutboxSmall() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = MailStore(accounts: [a], messages: [])
        let db = try MailDatabase(url: url)
        let html = "<html><body>" + String(repeating: "<p>Quarterly numbers and some text</p>", count: 500) + "</body></html>"
        s.apply(page((0..<2870).map { i in
            var m = server("R\(i)", read: true, minutes: i)
            if i % 2 == 0 {
                m.body = String(repeating: "Plain text line of the body. ", count: 150)
                m.html = html; m.htmlChecked = true; m.bodyLoaded = true
            }
            return m
        }), account: a.id, mailbox: .inbox)
        try db.write(s.takeChanges())
        s.selectedMailbox = .account(a.id, .inbox)
        s.selection = Set(s.visibleMessages.map(\.id))
        s.archiveSelection()
        try db.write(s.takeChanges())
        s.setFlag(.red, for: [s.messages[0].id])  // one more change while offline
        let changes = s.takeChanges()
        let bytes = try (changes.outbox ?? []).reduce(0) { $0 + (try JSONEncoder().encode($1)).count }
        try db.write(changes)
        #expect(bytes < 2_000_000, "flagging one message rewrites \(bytes / 1_000_000) MB of outbox")
    }

    /// A refused move still puts the message back where it was, from the slim copy kept in the outbox.
    @Test func refusedArchiveOfAnOpenedMessageIsUndone() {
        let s = MailStore(accounts: [a], messages: [])
        var m = server("R1", read: true)
        m.body = "The whole text"; m.bodyLoaded = true
        s.apply(page([m]), account: a.id, mailbox: .inbox)
        let id = s.messages[0].id
        s.archive([id])
        s.failed(s.outbox[0], "refused")
        #expect(s.message(id)?.mailbox == .inbox)
        #expect(s.message(id)?.body == "The whole text")
    }

    // MARK: Selection (BUG-119)

    /// With the unread filter on (Trash), two selected unread messages marked read leave the list and the
    /// selection, so the next Delete can't erase them unseen.
    @Test func markingAHiddenSelectionReadDoesNotLeaveItSelectedForErase() {
        let s = MailStore(accounts: [a], messages: [])
        s.apply(page([server("T1", minutes: 2), server("T2", minutes: 1), server("T3", minutes: 0)]), account: a.id, mailbox: .trash)
        let t1 = s.messages.first { $0.remoteID == "T1" }!.id, t2 = s.messages.first { $0.remoteID == "T2" }!.id
        s.selectedMailbox = .account(a.id, .trash)
        s.filterUnread = true
        s.selection = [t1, t2]
        s.toggleRead(s.selection)  // Message ▸ Mark as Read (⇧⌘U)
        let visible = Set(s.visibleMessages.map(\.id))
        #expect(s.selection.isSubset(of: visible), "selection \(s.selection.count) not in the list of \(visible.count)")
        s.deleteSelection()
        #expect(s.message(t1) != nil && s.message(t2) != nil, "Delete erased the two hidden messages from Trash")
    }

    /// In Flagged, clearing the flag of the selected message takes it out of the list and out of the selection.
    @Test func unflaggingInFlaggedDoesNotKeepAHiddenSelection() {
        let s = MailStore(accounts: [a], messages: [])
        s.apply(page([server("F1", flagged: true, minutes: 1), server("F2", flagged: true)]), account: a.id, mailbox: .inbox)
        let f1 = s.messages.first { $0.remoteID == "F1" }!.id
        s.selectedMailbox = .smart(.flagged)
        s.selection = [f1]
        s.setFlag(nil, for: [f1])
        #expect(s.selection.isSubset(of: Set(s.visibleMessages.map(\.id))))
    }

    // MARK: Launch (BUG-079, BUG-092, BUG-122)

    /// Stored mail of an account that is no longer set up isn't loaded: it doesn't show in All Inboxes.
    @Test func mailOfAccountNoLongerSetUpIsNotLoaded() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let d = try MailDatabase(url: url)
        func mail(_ subject: String, _ acct: Account, _ box: MailboxKind = .inbox) -> Message {
            Message(accountID: acct.id, mailbox: box, from: Contact(name: "Ann", email: "ann@x.com"), to: [], subject: subject,
                    body: "", date: Date(timeIntervalSinceReferenceDate: 800_000_000), remoteID: UUID().uuidString, bodyLoaded: false)
        }
        try d.write(StoreChanges(upserts: [mail("work inbox", a), mail("old home inbox", home), mail("old home archive", home, .archive)],
                                 sync: [SyncState(account: a.id, mailbox: .inbox, token: "w", complete: true),
                                        SyncState(account: home.id, mailbox: .inbox, token: "h", complete: true)]))
        let s = try launch([a], from: url)
        let foreign = s.messages.filter { $0.accountID == home.id }.map(\.subject)
        #expect(foreign.isEmpty, "mail of a removed account loaded: \(foreign)")
        #expect(s.visibleMessages.map(\.subject) == ["work inbox"], "All Inboxes shows \(s.visibleMessages.map(\.subject))")
    }

    /// A check that runs before launch has restored the stored Inbox (a mailbox clicked while "Loading Mail…")
    /// doesn't duplicate its messages, and the sync position it fetched isn't put back to the stored one.
    @Test func refreshBeforeLaunchRestoreDoesNotDuplicateTheInbox() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = try MailDatabase(url: url)
        var stored = server("A"); stored.accountID = a.id; stored.body = "stored text"; stored.bodyLoaded = true
        try db.write(StoreChanges(upserts: [stored], sync: [SyncState(account: a.id, mailbox: .sent, token: "old", complete: true)]))
        let s = MailStore(accounts: [a], messages: [])
        // Early check: Inbox not known yet → newest merged; Sent moved on to "new".
        s.merge([server("A"), server("B")], account: a.id, mailbox: .inbox)
        s.apply(page([], token: "new"), account: a.id, mailbox: .sent)
        let first = [MailboxKey(account: a.id, mailbox: .inbox)]
        s.restore(try db.meta())
        s.restore(try db.messages(in: first), boxes: first)
        s.finishLoading(try db.messages(notIn: first))
        #expect(s.messages.filter { $0.remoteID == "A" }.count == 1, "Inbox shows A \(s.messages.filter { $0.remoteID == "A" }.count) times")
        #expect(s.syncToken(a.id, .sent) == "new")
        // Saved and launched again: still one A, and the newer position.
        try db.write(s.takeChanges())
        let s2 = try launch([a], from: url)
        #expect(s2.messages.filter { $0.remoteID == "A" }.count == 1)
        #expect(s2.syncToken(a.id, .sent) == "new")
    }
}
