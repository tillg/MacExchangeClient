---
title: 'Mark All as Read while launch is still loading leaves the mail loaded afterwards unread'
priority: P4
area: MailStore
status: open
found: 2026-11-13
---
## Summary
During launch only the Inboxes are in memory until `finishLoading`. Mark All Messages as Read on a mailbox that spans other mailboxes (Flagged) or on an account mailbox not loaded yet marks only what is in memory; the rest arrives unread a moment later, so the badge comes back.

## Repro
Run: `swift test --filter Probe_E2ETests/markAllReadWhileLoadingCoversMailLoadedAfterwards` (all in `specs/bugs/probes/Probe_E2ETests.swift` of the copy).

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
    /// Mark All as Read while launch is still loading (Flagged spans every mailbox) leaves the mail that
    /// loads afterwards unread.
    @Test func markAllReadWhileLoadingCoversMailLoadedAfterwards() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = MailStore(accounts: [a], messages: [])
        let db = try MailDatabase(url: url)
        s.apply(page([server("I1", flagged: true)]), account: a.id, mailbox: .inbox)
        s.apply(page([server("R1", flagged: true), server("R2", flagged: true)]), account: a.id, mailbox: .archive)
        try db.write(s.takeChanges())
        let s2 = MailStore(accounts: [a], messages: [])
        let first = [MailboxKey(account: a.id, mailbox: .inbox)]
        s2.restore(try db.meta())
        s2.restore(try db.messages(in: first), boxes: first)
        #expect(s2.unreadCount(.smart(.flagged)) == 1)
        s2.markAllRead(in: .smart(.flagged))
        s2.finishLoading(try db.messages(notIn: first))
        #expect(s2.unreadCount(.smart(.flagged)) == 0, "\(s2.unreadCount(.smart(.flagged))) flagged still unread")
    }
}
```

## Expected vs actual
Expected: Flagged unread 0 after loading.
Actual: 2 flagged messages still unread.

Actual (test run):
```
􀢄  Test markAllReadWhileLoadingCoversMailLoadedAfterwards() recorded an issue at Probe_E2ETests.swift:248:9: Expectation failed: s2.unreadCount(.smart(.flagged)) == 0
􀄵  2 flagged still unread
􀄵  s2.unreadCount(.smart(.flagged)) == 0 → false
􀄵    s2.unreadCount(.smart(.flagged)) → 2
􀢄  Test markAllReadWhileLoadingCoversMailLoadedAfterwards() failed after 12.502 seconds with 1 issue.
```

## Why expected
The action is "all messages" of the mailbox; README describes launch loading as invisible apart from "Loading Mail…". ⚠️ Mail applies Mark All as Read to the whole mailbox (recalled).

## Likely cause
`Sources/MailModel/MailStore.swift:446-448`: `markAllRead` filters `messages` (memory only) and `finishLoading` (`:714-716`) adds the stored versions unchanged; nothing defers or re-applies it.
