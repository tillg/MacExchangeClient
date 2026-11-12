---
title: 'Actions that change nothing still rewrite their rows: Mark All as Read on a read mailbox rewrites every message'
priority: P4
area: MailStore
status: open
found: 2026-11-13
---
## Summary
`update()` marks every targeted message as changed before applying the change. Mark All as Read on a mailbox of 1,000 with one unread message writes 1,000 rows (bodies and HTML included) instead of one; setting the colour a message already has, opening an already read message or moving it where it is also rewrite its row.

## Repro
Run: `swift test --filter Probe_E2ETests/markAllReadWritesOnlyTheMessagesItChanged` (all in `specs/bugs/probes/Probe_E2ETests.swift` of the copy).

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
    /// README: "Saving: ... only what changed: one flag change is one row". Mark All as Read on a mailbox where
    /// only one message is unread should write one row, not every message of the mailbox.
    @Test func markAllReadWritesOnlyTheMessagesItChanged() {
        let s = MailStore(accounts: [a], messages: [])
        s.apply(page((0..<1000).map { server("R\($0)", read: $0 != 7) }), account: a.id, mailbox: .inbox)
        _ = s.takeChanges()
        s.markAllRead(in: .account(a.id, .inbox))
        let written = s.takeChanges().resolved().upserts
        #expect(s.outbox.count == 1)
        #expect(written.count == 1, "Mark All as Read on 1 unread of 1,000 rewrites \(written.count) rows")
    }

    /// Same: setting the flag colour a message already has, or selecting an already read message, changes nothing.
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
}
```

## Expected vs actual
Expected: 1 row (the one unread message); no row for the no-op actions.
Actual: 1,000 rows; the no-op actions write the message.

Actual (test run):
```
􀢄  Test markAllReadWritesOnlyTheMessagesItChanged() recorded an issue at Probe_E2ETests.swift:106:9: Expectation failed: written.count == 1
􀄵  Mark All as Read on 1 unread of 1,000 rewrites 1000 rows
􀄵  written.count == 1 → false
􀄵    written.count → 1000
􀢄  Test markAllReadWritesOnlyTheMessagesItChanged() failed after 10.593 seconds with 1 issue.

􀢄  Test noOpActionsWriteNothing() recorded an issue at Probe_E2ETests.swift:119:9: Expectation failed: s.takeChanges().resolved().upserts.isEmpty
􀄵  s.takeChanges().resolved().upserts.isEmpty → false
􀄵    s.takeChanges().resolved().upserts → [MailModel.Message(id: AE6E3327-AD71-4E1E-964A-5821E2E6A390, accountID: 260B1A3C-BE8D-4AE8-8B72-AAE8662C93B9, mailbox: MailModel.MailboxKind(rawValue: "inbox"), from: MailModel.Contact(name: "Ann", email: "ann@x.com"), to: [MailModel.Contact(name: "Me", email: "me@work.com")], cc: [], subject: "S R1", body: "", date: 2023-11-14 22:13:20 +0000, isRead: true, flag: Optional(MailModel.FlagColor.red), category: MailModel.MailCategory.primary, isVIP: false, attachments: [], remoteID: Optional("R1"), hasAttachments: false, serverPreview: Optional("p R1"), bodyLoaded: false, isInvite: nil, invite: nil, html: nil, htmlChecked: nil, conversationID: nil)]
􀄵    isEmpty → false
􀢄  Test noOpActionsWriteNothing() failed after 12.502 seconds with 1 issue.
```

## Why expected
README, Saving: "only what changed: one flag change is one row, a few milliseconds."

## Likely cause
`Sources/MailModel/MailStore.swift:334`: `changedIDs.formUnion(ids)` before the loop, instead of inserting only the IDs where `messages[i] != old`.
