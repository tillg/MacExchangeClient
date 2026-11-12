---
title: 'Send from an Exchange account without a Keychain password: shown in Sent though nothing is sent, or queued with no word'
priority: P3
area: MailStore
status: open
found: 2026-11-13
---
## Summary
An Exchange account whose password is missing from the Keychain is added without a backend (`AppSetup.connect`). (1) Before it has any stored sync position (new, deleted or unopenable database), `send` treats it as a sample account: the message is filed under Sent as if sent, and nothing is queued (not probed: the account isn't stored, so it would also be gone after a relaunch). (2) With stored sync positions, Send queues the message, which can never drain; nothing says so (not probed: it would go out whenever a password is added, possibly days later).

## Repro
Run: `swift test --filter Probe_E2ETests/sendFromAnExchangeAccountWithoutPasswordIsNotShownAsSent` (all in `specs/bugs/probes/Probe_E2ETests.swift` of the copy).

```swift
// Shared harness (from Probe_E2ETests.swift; whole file in the copy's Tests/MailModelTests)
import Foundation
import Testing
@testable import EWS
@testable import MailModel

@MainActor
struct Probe_E2ETests {
    let a = Account(name: "Exchange", address: "me@work.com")
    let b = Account(name: "Exchange", address: "team@work.com")
    let c = Account(name: "Exchange", address: "team@work.com")
    var all: [Account] { [a, b, c] }

    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("probe-e2e-\(UUID().uuidString)")
            .appendingPathComponent("Mail.sqlite")
    }
    func server(_ rid: String, read: Bool = false, flagged: Bool = false, minutes: Int = 0, from: String = "Ann",
                conv: String? = nil) -> Message {
        var m = Message(accountID: UUID(), from: Contact(name: from, email: "\(from.lowercased())@x.com"),
                        to: [Contact(name: "Me", email: "me@work.com")], subject: "S \(rid)", body: "",
                        date: Date(timeIntervalSince1970: 1_700_000_000 + Double(minutes) * 60), isRead: read,
                        flag: flagged ? .red : nil, remoteID: rid, serverPreview: "p \(rid)", bodyLoaded: false)
        m.conversationID = conv
        return m
    }
    func page(_ ups: [Message], del: [String] = [], token: String = "t", more: Bool = false) -> SyncResult {
        SyncResult(upserts: ups, deletedRemoteIDs: del, token: token, more: more)
    }
    /// Saves everything, then launches again as the app does: meta, the Inboxes, then the rest.
    func relaunch(_ s: MailStore, _ db: MailDatabase, _ url: URL, accounts: [Account]? = nil) throws -> (MailStore, MailDatabase) {
        try db.write(s.takeChanges())
        let db2 = try MailDatabase(url: url)
        let s2 = MailStore(accounts: accounts ?? s.accounts, messages: [])
        let first = s2.accounts.map { MailboxKey(account: $0.id, mailbox: .inbox) }
        s2.restore(try db2.meta())
        s2.restore(try db2.messages(in: first), boxes: first)
        s2.finishLoading(try db2.messages(notIn: first))
        return (s2, db2)
    }
    // file:// fixture: the real EWSClient/EWSBackend reading a hand-written response file. No network, no fakes.
    func responseFile(_ xml: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ews-e2e-\(UUID().uuidString).xml")
        try Data(xml.utf8).write(to: url)
        return url
    }
    var success: String {
        """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><s:Body><m:X><m:ResponseMessages>\
        <m:R ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode></m:R></m:ResponseMessages></m:X></s:Body></s:Envelope>
        """
    }
    func error(_ code: String) -> String {
        success.replacingOccurrences(of: "<m:R ResponseClass=\"Success\"><m:ResponseCode>NoError</m:ResponseCode></m:R>",
                                     with: "<m:R ResponseClass=\"Error\"><m:MessageText>\(code) text</m:MessageText><m:ResponseCode>\(code)</m:ResponseCode></m:R>")
    }
    func backend(_ url: URL) -> EWSBackend { EWSBackend(client: EWSClient(url: url, username: "u", password: "p")) }
    func isSend(_ p: PendingChange) -> Bool { if case .send = p.change { true } else { false } }
    func waitUntil(_ cond: () -> Bool) async throws {
        for _ in 0..<500 where !cond() { try await Task.sleep(for: .milliseconds(10)) }
    }

    // ---- the probe(s) of this finding ----
    /// An Exchange account whose Keychain password is missing has no backend. Before it has any stored sync
    /// position (fresh database), Send files the message under Sent as if sent, and nothing is queued.
    @Test func sendFromAnExchangeAccountWithoutPasswordIsNotShownAsSent() {
        let ex = ExchangeAccount(email: "till@work.com", username: "W\\till", server: "mail.work.com")
        let s = MailStore(accounts: [], messages: [])
        s.accounts.append(ex.account)  // AppSetup.connect without a Keychain password
        s.send(Draft(accountID: ex.id, to: "x@y.com", subject: "Important", body: "b"))
        let sent = s.messages.filter { $0.mailbox == .sent && $0.subject == "Important" }
        #expect(sent.isEmpty && s.outbox.contains(where: isSend), "shown in Sent \(sent.count), queued \(s.outbox.count)")
    }

    /// The same account after a relaunch (its sync positions are stored): Send queues the message, which can never
    /// go out (no backend) and nothing says so; it stays queued across relaunches and goes out whenever a
    /// password is added, maybe days later.
    @Test func sendFromARestoredExchangeAccountWithoutPasswordSaysItCannotSend() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ex = ExchangeAccount(email: "till@work.com", username: "W\\till", server: "mail.work.com")
        let s = MailStore(accounts: [ex.account], messages: [])
        s.apply(page([server("A1")]), account: ex.id, mailbox: .inbox)
        try MailDatabase(url: url).write(s.takeChanges())
        let db = try MailDatabase(url: url)
        let s2 = MailStore(accounts: [], messages: [])
        s2.accounts.append(ex.account)  // AppSetup.connect without a Keychain password
        s2.status = "No password in the Keychain for W\\till"
        s2.restore(try db.meta())
        s2.finishLoading(try db.messages())
        let before = s2.status
        s2.send(Draft(accountID: ex.id, to: "x@y.com", subject: "Important", body: "b"))
        #expect(s2.status != before || s2.messages.contains { $0.subject == "Important" && $0.mailbox == .drafts },
                "queued: \(s2.outbox.count), status: \(s2.status ?? "nil")")
    }
}
```

## Expected vs actual
Expected: Send says the account can't send (or keeps the message in Drafts), and never shows unsent mail in Sent.
Actual: (1) shown in Sent 1, queued 0; (2) status unchanged and nothing in Drafts, the send sits in the outbox.

Actual (test run):
```
􀢄  Test sendFromAnExchangeAccountWithoutPasswordIsNotShownAsSent() recorded an issue at Probe_E2ETests.swift:272:9: Expectation failed: sent.isEmpty && s.outbox.contains(where: isSend)
􀄵  shown in Sent 1, queued 0
􀄵  sent.isEmpty && s.outbox.contains(where: isSend) → false
􀄵    sent.isEmpty → false
􀄵    s.outbox.contains(where: isSend) → <not evaluated>
􀢄  Test sendFromAnExchangeAccountWithoutPasswordIsNotShownAsSent() failed after 12.505 seconds with 1 issue.

􀢄  Test sendFromARestoredExchangeAccountWithoutPasswordSaysItCannotSend() recorded an issue at Probe_E2ETests.swift:293:9: Expectation failed: s2.status != before || s2.messages.contains { $0.subject == "Important" && $0.mailbox == .drafts }
􀄵  queued: 1, status: No password in the Keychain for W\till
􀄵  s2.status != before || s2.messages.contains { $0.subject == "Important" && $0.mailbox == .drafts } → false
􀄵    s2.status != before → false
􀄵    s2.messages.contains { $0.subject == "Important" && $0.mailbox == .drafts } → false
􀢄  Test sendFromARestoredExchangeAccountWithoutPasswordSaysItCannotSend() failed after 12.505 seconds with 1 issue.
```

## Why expected
README: "A message that fails to send is never resent automatically. It is kept in Drafts on this Mac instead." Showing a message in Sent means it was sent.

## Likely cause
`Sources/MailModel/MailStore.swift:1385-1394`: `send` decides by `serverAccounts.contains(acct.id)`, which for a backend-less account depends only on stored sync rows (`restore(_ meta:)`, `:690-697`); otherwise it takes the sample-data path. `canSend` (`:830`) silently skips changes of accounts without a backend.
