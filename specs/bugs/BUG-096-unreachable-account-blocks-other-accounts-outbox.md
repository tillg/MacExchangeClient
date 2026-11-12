---
title: 'One unreachable account holds up every other account''s changes and sends'
priority: P2
area: MailStore
status: open
found: 2026-11-13
---
## Summary
The outbox is one queue for all accounts, and `drain()` stops at the first network error. With two Exchange accounts where one server can't be reached (VPN-only work server, server down), a change queued for it first blocks everything queued after it for the other, reachable account: read state, flags, moves and sends from account B wait until account A is reachable again. (Not probed: a Save Draft that keeps timing out should block the same way.)

## Repro
Run: `swift test --filter Probe_E2ETests/unreachableAccountDoesNotBlockTheOtherAccountsChanges` (all in `specs/bugs/probes/Probe_E2ETests.swift` of the copy).

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
    /// Two Exchange accounts: one server unreachable (e.g. only over VPN) must not hold up the other account's
    /// changes. drain() stops at the first URLError, and the outbox is one queue for all accounts.
    @Test func unreachableAccountDoesNotBlockTheOtherAccountsChanges() async throws {
        let ok = try responseFile(success)  // file:// fixture
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("ews-e2e-missing-\(UUID().uuidString).xml")
        let s = MailStore(accounts: [], messages: [])
        s.add(a, backend: backend(missing))
        s.add(b, backend: backend(ok))
        s.apply(page([server("A1")]), account: a.id, mailbox: .inbox)
        s.apply(page([server("B1")]), account: b.id, mailbox: .inbox)
        let a1 = s.messages.first { $0.accountID == a.id }!.id, b1 = s.messages.first { $0.accountID == b.id }!.id
        s.toggleRead([a1])
        s.toggleRead([b1])
        s.send(Draft(accountID: b.id, to: "x@y.com", subject: "From B", body: "b"))
        await s.refresh(history: false)
        let left = s.outbox.filter { $0.account == b.id }.map(\.change)
        #expect(left.isEmpty, "account B's changes still waiting because account A is unreachable: \(left)")
    }
}
```

## Expected vs actual
Expected: account B's `setRead` and its Send go out; only account A's change waits.
Actual: both of B's changes are still queued after the check.

Actual (test run):
```
􀢄  Test unreachableAccountDoesNotBlockTheOtherAccountsChanges() recorded an issue at Probe_E2ETests.swift:138:9: Expectation failed: left.isEmpty
􀄵  account B's changes still waiting because account A is unreachable: [MailModel.ServerChange.setRead(["B1"], true), MailModel.ServerChange.send(MailModel.Draft(accountID: A44B4977-FD12-4A4D-8A12-3DDF2E7403BA, to: "x@y.com", cc: "", subject: "From B", body: "b", inviteAnswer: nil, files: nil, loadingOriginal: nil, original: nil))]
􀄵  left.isEmpty → false
􀄵    left → [MailModel.ServerChange.setRead(["B1"], true), MailModel.ServerChange.send(MailModel.Draft(accountID: A44B4977-FD12-4A4D-8A12-3DDF2E7403BA, to: "x@y.com", cc: "", subject: "From B", body: "b", inviteAnswer: nil, files: nil, loadingOriginal: nil, original: nil))]
􀄵    isEmpty → false
􀢄  Test unreachableAccountDoesNotBlockTheOtherAccountsChanges() failed after 12.513 seconds with 1 issue.
```

## Why expected
README: "Offline, changes wait until the next refresh" – offline is per server; B is online. ⚠️ Mail.app sends per account (recalled). The quick check in `refresh()` already treats accounts independently (a failing account doesn't stop the others).

## Likely cause
`Sources/MailModel/MailStore.swift:811-823`: `while let p = outbox.first(where: canSend)` takes the oldest change of any account; on `URLError` (`catch let e as URLError`) it sets "Offline…" and `return`s, ending the drain for all accounts instead of skipping that account's changes.
