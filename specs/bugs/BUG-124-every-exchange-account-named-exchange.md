---
title: 'Every Exchange account is called "Exchange": two accounts can''t be told apart'
priority: P4
area: EWS
status: open
found: 2026-11-13
---
## Summary
`ExchangeAccount.account` names every account "Exchange". With two accounts (README supports several: All Inboxes opens into each account's Inbox), per `SidebarView.swift` (read, not run) the sidebar shows two "Exchange" sections and two "Exchange" rows under All Inboxes, the window title is "Inbox – Exchange" for both, and "Found in Sent – Exchange", "Synchronizing “Exchange”" and sign-in errors don't say which account. There is no way to rename an account.

## Repro
Run: `swift test --filter Probe_E2ETests/twoExchangeAccountsCanBeToldApart` (all in `specs/bugs/probes/Probe_E2ETests.swift` of the copy).

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
    /// Two Exchange accounts look the same everywhere: every one is called "Exchange" (sidebar sections,
    /// All Inboxes rows, window title, "Found in Sent – …", sync progress, sign-in errors).
    @Test func twoExchangeAccountsCanBeToldApart() {
        let one = ExchangeAccount(email: "till@work.com", username: "W\\till", server: "mail.work.com")
        let two = ExchangeAccount(email: "till@club.org", username: "C\\till", server: "mail.club.org")
        let s = MailStore(accounts: [one.account, two.account], messages: [])
        s.selectedMailbox = .account(one.id, .inbox)
        let t1 = s.title
        s.selectedMailbox = .account(two.id, .inbox)
        #expect(t1 != s.title, "both Inboxes are titled \(t1)")
        #expect(one.account.name != two.account.name)
    }
}
```

## Expected vs actual
Expected: different names (e.g. the email address) for different accounts.
Actual: both "Exchange"; both Inbox titles "Inbox – Exchange".

Actual (test run):
```
􀢄  Test twoExchangeAccountsCanBeToldApart() recorded an issue at Probe_E2ETests.swift:260:9: Expectation failed: t1 != s.title
􀄵  both Inboxes are titled Inbox – Exchange
􀄵  t1 != s.title → false
􀄵    t1 → "Inbox – Exchange"
􀄵    s.title → "Inbox – Exchange"
􀢄  Test twoExchangeAccountsCanBeToldApart() recorded an issue at Probe_E2ETests.swift:261:9: Expectation failed: one.account.name != two.account.name
􀄵  one.account.name != two.account.name → false
􀄵    one.account.name → "Exchange"
􀄵    two.account.name → "Exchange"
􀢄  Test twoExchangeAccountsCanBeToldApart() failed after 12.502 seconds with 2 issues.
```

## Why expected
README: "With more than one account, Favorites ▸ All Inboxes opens into each account's Inbox" – rows the user must tell apart. ⚠️ Mail.app defaults the description to the account type but lets you change it, and shows the address where needed (recalled, not checked).

## Likely cause
`Sources/EWS/ExchangeAccount.swift:24`: `Account(id: id, name: "Exchange", address: email)`.
