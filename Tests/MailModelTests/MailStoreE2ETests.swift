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
