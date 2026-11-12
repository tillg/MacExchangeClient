---
title: 'A send that is on its way when the app quits (or crashes) is sent again at the next launch'
priority: P2
area: MailStore
status: open
found: 2026-11-13
---
## Summary
A queued `.send` stays in the outbox until the server has answered. The save on quit (`saveChanges(now: true)`) or the 15-second save therefore stores the send while its request is on the way. If the app quits or crashes before the next save, the next launch restores the send and sends the mail a second time, without asking. (Not probed: other changes in flight, e.g. a move replayed with its old ID, would be repeated the same way.)

## Repro
Run: `swift test --filter Probe_E2ETests/sendInFlightWhenTheAppQuitsIsNotSentAgainAfterRelaunch` (all in `specs/bugs/probes/Probe_E2ETests.swift` of the copy).

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
    /// A send queued while the request is on its way is written by the 15-second save (or the save on quit).
    /// If the app quits before the next save, the next launch restores the send and sends the mail again.
    @Test func sendInFlightWhenTheAppQuitsIsNotSentAgainAfterRelaunch() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ok = try responseFile(success)  // file:// fixture
        let s = MailStore(accounts: [], messages: [])
        s.add(a, backend: backend(ok))
        let db = try MailDatabase(url: url)
        s.apply(page([server("A1")]), account: a.id, mailbox: .inbox)
        s.send(Draft(accountID: a.id, to: "boss@x.com", subject: "Resignation", body: "Once only"))
        await Task.yield()  // the drain has started: the request is on its way
        try #require(s.outbox.contains(where: isSend))
        try db.write(s.takeChanges())  // the save on quit (saveChanges(now: true)) while the request is on its way
        await s.refresh(history: false)  // the server accepted it
        try #require(!s.outbox.contains(where: isSend))
        // The app quit (or crashed) before the next save. Next launch:
        let s2 = MailStore(accounts: [], messages: [])
        s2.add(a, backend: backend(ok))
        let db2 = try MailDatabase(url: url)
        s2.restore(try db2.meta())
        s2.finishLoading(try db2.messages())
        await s2.refresh(history: false)
        #expect(s2.messages.contains { $0.mailbox == .drafts && $0.subject == "Resignation" },
                "sent a second time without asking (outbox now \(s2.outbox.count)); not kept in Drafts")
    }
}
```

## Expected vs actual
Expected: a send that may already have gone out is never repeated automatically; after the relaunch it is kept in Drafts on this Mac (as after a timeout), or at least not sent again.
Actual: the `#require` checks pass (the send was in the saved outbox while its request was running, and the server accepted it), and after the relaunch the restored send is drained again: the outbox empties, nothing is in Drafts.

Actual (test run):
```
􀢄  Test sendInFlightWhenTheAppQuitsIsNotSentAgainAfterRelaunch() recorded an issue at Probe_E2ETests.swift:227:9: Expectation failed: s2.messages.contains { $0.mailbox == .drafts && $0.subject == "Resignation" }
􀄵  sent a second time without asking (outbox now 0); not kept in Drafts
􀄵  s2.messages.contains { $0.mailbox == .drafts && $0.subject == "Resignation" } → <not evaluated>
􀢄  Test sendInFlightWhenTheAppQuitsIsNotSentAgainAfterRelaunch() failed after 12.517 seconds with 1 issue.
```

## Why expected
README: "A message that fails to send is never resent automatically." MailStore.drain's own comment: "a send is never retried, because a timed-out send may have gone out" (URLError on `.send` goes to Drafts for exactly that reason). A send interrupted by quit is the same uncertain case, but is retried.

## Likely cause
`Sources/MailModel/MailStore.swift:811-814`: `drain()` removes the change only after `perform` returns, and `takeChanges()` (`:658`) writes `outbox` as it is, including the change being performed. `restore(_ meta:)` (`:699`) then queues it again and `finishLoading` (`:718`) drains it. Nothing marks a change as started.
