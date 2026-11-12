---
title: 'Queued changes keep a full copy of every message: archiving an opened Inbox makes a 35 MB outbox, rewritten after one more flag'
priority: P4
area: MailStore
status: open
found: 2026-11-13
---
## Summary
Each queued change keeps `previous: [Message]` – whole messages including body and HTML – only to undo mailbox, read state and flag. Select All ▸ Archive on an Inbox of 2,870 messages (the README's size) with half of them opened puts about 35 MB into the outbox. The outbox table is rewritten completely on every outbox change, so while offline every later action (here one flag) makes the next save write the 35 MB again (not probed: each batch drained would rewrite the rest). The control with summaries only stays at about 1.2 MB.

## Repro
Run: `swift test --filter Probe_E2ETests/archivingAWholeInboxKeepsTheOutboxSmall` (all in `specs/bugs/probes/Probe_E2ETests.swift` of the copy).

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
    /// Select All ▸ Archive on an Inbox of 2,870 messages (README's size), half of them opened: the queued move
    /// holds a full copy of every message, bodies and HTML included, and every later change to the outbox
    /// (one more flag, one batch sent) rewrites all of it on the next save.
    @Test func archivingAWholeInboxKeepsTheOutboxSmall() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = MailStore(accounts: [a], messages: [])
        let db = try MailDatabase(url: url)
        let html = "<html><body>" + String(repeating: "<p>Quarterly numbers and some text</p>", count: 500) + "</body></html>"
        s.apply(page((0..<2870).map { i in
            var m = server("R\(i)", read: true, minutes: i)
            if i % 2 == 0 {
                m.body = String(repeating: "Plain text line of the body. ", count: 150)
                m.html = html; m.htmlChecked = true; m.bodyLoaded = true
            }
            return m
        }), account: a.id, mailbox: .inbox)
        try db.write(s.takeChanges())
        s.selectedMailbox = .account(a.id, .inbox)
        s.selection = Set(s.visibleMessages.map(\.id))
        s.archiveSelection()
        try db.write(s.takeChanges())
        s.setFlag(.red, for: [s.messages[0].id])  // one more change while offline
        let changes = s.takeChanges()
        let bytes = try (changes.outbox ?? []).reduce(0) { $0 + (try JSONEncoder().encode($1)).count }
        let start = ContinuousClock.now
        try db.write(changes)
        let t = start.duration(to: .now)
        print("PROBE outbox \(changes.outbox?.count ?? 0) changes, \(bytes / 1_000_000) MB JSON, write \(t)")
        #expect(bytes < 2_000_000, "flagging one message rewrites \(bytes / 1_000_000) MB of outbox; the save took \(t)")
    }

    /// Control: the same with summaries only (nothing opened) stays small.
    @Test func archivingAWholeInboxOfSummariesIsSmall() throws {
        let s = MailStore(accounts: [a], messages: [])
        s.apply(page((0..<2870).map { server("R\($0)", read: true, minutes: $0) }), account: a.id, mailbox: .inbox)
        s.archive(Set(s.messages.map(\.id)))
        let bytes = try s.outbox.reduce(0) { $0 + (try JSONEncoder().encode($1)).count }
        print("PROBE summaries-only outbox \(bytes / 1000) kB")
        #expect(bytes < 5_000_000)
    }
}
```

## Expected vs actual
Expected: the outbox stays small (well under 2 MB) – the undo needs a few fields per message.
Actual: 30 changes, 35 MB JSON rewritten for one flag change.

Actual (test run):
```
􀢄  Test archivingAWholeInboxKeepsTheOutboxSmall() recorded an issue at Probe_E2ETests.swift:387:9: Expectation failed: bytes < 2_000_000
􀄵  flagging one message rewrites 35 MB of outbox; the save took 0.166183209 seconds
􀄵  bytes < 2_000_000 → false
􀄵    bytes → 35523373
􀄵    2_000_000 → 2000000
􀢄  Test archivingAWholeInboxKeepsTheOutboxSmall() failed after 12.505 seconds with 1 issue.
PROBE summaries-only outbox 1193 kB
PROBE outbox 30 changes, 35 MB JSON, write 0.166183209 seconds

􁁛  Test archivingAWholeInboxOfSummariesIsSmall() passed after 12.505 seconds.
PROBE summaries-only outbox 1193 kB
PROBE outbox 30 changes, 35 MB JSON, write 0.166183209 seconds
```

## Why expected
README, Saving: "changes are written every 15 seconds … only what changed: one flag change is one row, a few milliseconds."

## Likely cause
`Sources/MailModel/MailStore.swift:380`: `previous: chunk` stores full messages; `Sources/MailModel/MailDatabase.swift:354-359`: `DELETE FROM outbox` and re-insert of every entry whenever `outbox` changed.
