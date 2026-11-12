---
title: 'One unreachable account stops the background history and background checks of every other account'
priority: P3
area: MailStore
status: open
found: 2026-11-13
---
## Summary
`syncHistory()` returns as soon as one folder fails with a network error. Accounts are tried in order, so while the first account's server is unreachable, the other accounts' histories never progress and their complete folders never get their background delta check; only their Inbox and the mailbox on screen are checked.

## Repro
Run: `swift test --filter Probe_E2ETests/unreachableAccountDoesNotStopTheOtherAccountsHistory` (all in `specs/bugs/probes/Probe_E2ETests.swift` of the copy).

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
    /// The same for the background history: the first account's folder fails with a network error and
    /// syncHistory returns, so the other account's history (and its background checks) never run while the
    /// first one is unreachable.
    @Test func unreachableAccountDoesNotStopTheOtherAccountsHistory() async throws {
        let ok = try responseFile(success)  // file:// fixture
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("ews-e2e-missing-\(UUID().uuidString).xml")
        let s = MailStore(accounts: [], messages: [])
        s.add(a, backend: backend(missing))
        s.add(b, backend: backend(ok))
        // Both folder lists were read while A was still reachable (e.g. before the VPN dropped).
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "FA"), RemoteFolder(role: .sent, id: "FA2")], account: a.id)
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "FB"), RemoteFolder(role: .sent, id: "FB2")], account: b.id)
        await s.syncHistory()
        await s.syncHistory()  // the next round, 15 s later
        #expect(s.isComplete(b.id, .inbox) && s.isComplete(b.id, .sent),
                "account B's history: inbox \(s.isComplete(b.id, .inbox)), sent \(s.isComplete(b.id, .sent))")
    }
}
```

## Expected vs actual
Expected: account B's Inbox and Sent complete their history.
Actual: neither completes, also after a second round.

Actual (test run):
```
􀢄  Test unreachableAccountDoesNotStopTheOtherAccountsHistory() recorded an issue at Probe_E2ETests.swift:155:9: Expectation failed: s.isComplete(b.id, .inbox) && s.isComplete(b.id, .sent)
􀄵  account B's history: inbox false, sent false
􀄵  s.isComplete(b.id, .inbox) && s.isComplete(b.id, .sent) → false
􀄵    s.isComplete(b.id, .inbox) → false
􀄵    s.isComplete(b.id, .sent) → <not evaluated>
􀢄  Test unreachableAccountDoesNotStopTheOtherAccountsHistory() failed after 12.512 seconds with 1 issue.
```

## Why expected
README, How mail is fetched: "A folder whose history fails is skipped"; `syncHistory`'s doc comment: "A failing folder doesn't stop the others; offline, the history waits for the next check" – B is not offline. Same independence as in the quick check.

## Likely cause
`Sources/MailModel/MailStore.swift:1201-1202`: `catch is URLError { return }` inside the `while let … = nextHistoryFolder()` loop exits the whole history (and skips the background delta loop at `:1211`), and `nextHistoryFolder()` (`:1234`) always returns the unreachable account's folder first.
