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
}
