import Foundation
import Testing
@testable import EWS
@testable import MailModel

/// Hunter R5F: logic of the view layer (Sources/MailReplica), reached through the MailModel calls the views make.
@MainActor
struct Probe_R5F_Windows {
    let work = Account(name: "Work", address: "me@work.com")

    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Probe_R5F-\(UUID())/Mail.sqlite")
    }

    func remote(_ rid: String, _ box: MailboxKind = .inbox) -> Message {
        Message(accountID: work.id, mailbox: box, from: Contact(name: "Ann", email: "ann@x.com"),
                to: [Contact(name: "Me", email: "me@work.com")], subject: "S \(rid)", body: "",
                date: Date(timeIntervalSinceReferenceDate: 800_000_000), remoteID: rid, serverPreview: "P", bodyLoaded: false)
    }

    /// The steps of `AppSetup.loadMail` (AccountsSettings.swift:34-46) after the database exists.
    func loadMail(_ s: MailStore, _ db: MailDatabase) throws {
        let first = s.accounts.map { MailboxKey(account: $0.id, mailbox: .inbox) }
        s.restore(try db.meta())
        s.restore(try db.messages(in: first), boxes: first)
        s.finishLoading(try db.messages(notIn: first))
    }

    /// R5F-01: every viewer window runs `.task { await pollForMail() }` (MailReplicaApp.swift:25), which starts
    /// with `AppSetup.loadMail(into: store)`. File ▸ New Viewer Window (⌥⌘N) therefore loads the database into the
    /// running store a second time. A send waiting in the outbox (offline, or the account has no password) is then
    /// in the outbox twice (same ID; a successful drain removes both, so the visible harm is the in-flight case below).
    @Test func secondViewerWindowDoesNotDuplicateTheOutbox() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = try MailDatabase(url: url)
        let s = MailStore(accounts: [], messages: [])
        s.add(work, backend: nil)  // signed in, no password in the Keychain: changes wait
        // Launch: the first window loads mail.
        try loadMail(s, db)
        s.apply(SyncResult(upserts: [remote("A")], deletedRemoteIDs: [], token: "t1", more: false), account: work.id, mailbox: .inbox)
        // The user sends a message; it waits in the outbox. The 15 s poll saves it (AppSetup.saveChanges).
        #expect(s.send(Draft(accountID: work.id, to: "bob@x.com", subject: "Quarterly report", body: "Hi")))
        try db.write(s.takeChanges())
        let sendsBefore = s.outbox.filter { if case .send = $0.change { true } else { false } }.count
        // File ▸ New Viewer Window: the new window's task runs loadMail again.
        try loadMail(s, db)
        let sendsAfter = s.outbox.filter { if case .send = $0.change { true } else { false } }.count
        #expect(sendsBefore == 1)
        #expect(sendsAfter == 1, "the waiting send is queued \(sendsAfter) times after a second viewer window opened")
        #expect(s.messages.count == 1)
    }

    /// R5F-01: the same, while a send is on its way. `saveBeforeSending` (AccountsSettings.swift:12) has just written
    /// it to disk marked in flight; the new window's loadMail reads that mark as "the app quit while sending": it
    /// copies the message to Drafts and says it may already have been sent, while it is being sent right now.
    @Test func secondViewerWindowDuringASendDoesNotReportAnInterruptedSend() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = try MailDatabase(url: url)
        let server = LoopbackEndpoint()
        server.start { nil }  // a slow server: the send stays on its way
        defer { server.stop() }
        let s = MailStore(accounts: [], messages: [])
        s.add(work, backend: EWSBackend(client: EWSClient(url: server.url, username: "u", password: "p")))
        s.saveBeforeSending = { try? db.write(s.takeChanges()) }
        try loadMail(s, db)
        #expect(s.send(Draft(accountID: work.id, to: "bob@x.com", subject: "Quarterly report", body: "Hi")))
        for _ in 0..<200 where !(s.outbox.first?.inFlight ?? false) { try await Task.sleep(for: .milliseconds(10)) }
        try #require(s.outbox.first?.inFlight == true)
        // File ▸ New Viewer Window.
        try loadMail(s, db)
        let copies = s.messages.filter { $0.subject == "Quarterly report" }.map(\.mailbox)
        #expect(copies.isEmpty, "a message being sent was copied to \(copies) by the second window's loadMail")
        #expect(s.status == nil, "status: \(s.status ?? "")")
    }

    /// R5F-01: the second load also resets the "outbox changed" mark (`restore(meta)`: `outboxChanged = interrupted`).
    /// A message sent while offline in the seconds before the new window opened, and not saved yet, then never
    /// reaches disk: the next save leaves it out, and quitting loses it.
    @Test func secondViewerWindowKeepsAnUnsavedSendForTheNextSave() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = try MailDatabase(url: url)
        let s = MailStore(accounts: [], messages: [])
        s.add(work, backend: nil)
        try loadMail(s, db)
        try db.write(s.takeChanges())
        #expect(s.send(Draft(accountID: work.id, to: "bob@x.com", subject: "Quarterly report", body: "Hi")))
        // Not saved yet (the poll saves every 15 s); File ▸ New Viewer Window.
        try loadMail(s, db)
        let saved = s.takeChanges().outbox ?? []
        #expect(saved.count == 1, "the next save writes \(saved.count) outbox entries; the queued send is only in memory")
        try db.write(StoreChanges(outbox: saved.isEmpty ? nil : saved))
        let onDisk = try db.meta().outbox.count
        #expect(onDisk == 1, "on disk after the next save: \(onDisk) outbox entries")
    }
}
