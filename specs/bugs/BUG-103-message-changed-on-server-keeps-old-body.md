---
title: 'A draft changed on the server keeps its old loaded body: new subject, old text and files'
priority: P3
area: MailStore
status: open
found: 2026-11-13
---
## Summary
Once a message's body is loaded, later summaries from the server never replace it: `merge` copies the old body, attachments and HTML into the update and marks it loaded. A draft edited in Outlook/OWA (Exchange keeps its ItemId) therefore shows the new subject with the old text and old attachments, also after a relaunch; it is never fetched again. ⚠️ The EWS update shape for an edited draft (Update with summary only) is from the protocol, not from a live capture. This pulls against BUG-057 (summary wipes addresses): the merge must keep the body only when the item did not change.

## Repro
Run: `swift test --filter Probe_E2ETests/draftEditedOnTheServerShowsItsNewText` (all in `specs/bugs/probes/Probe_E2ETests.swift` of the copy).

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
    /// A draft saved from here (or Outlook) and opened once, then edited elsewhere: the Drafts sync brings the new
    /// summary, but the merge keeps the old loaded body and never fetches it again; subject and text disagree.
    @Test func draftEditedOnTheServerShowsItsNewText() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = MailStore(accounts: [a], messages: [])
        var v1 = server("D1"); v1.subject = "Offer v1"; v1.serverPreview = "Price 100"
        s.apply(page([v1], token: "d1"), account: a.id, mailbox: .drafts)
        let id = s.messages[0].id
        s.setBody(MessageBody(text: "Price 100", attachments: [Attachment(name: "v1.pdf", size: 1000, contentType: "application/pdf")]), for: id)
        var v2 = server("D1"); v2.subject = "Offer v2"; v2.serverPreview = "Price 250"; v2.hasAttachments = true
        s.apply(page([v2], token: "d2"), account: a.id, mailbox: .drafts)
        let db = try MailDatabase(url: url)
        let (s2, _) = try relaunch(s, db, url)
        let m = try #require(s2.message(id))
        #expect(m.subject == "Offer v2")
        #expect(m.body == "Price 250" || m.needsBody, "subject 'Offer v2' with body '\(m.body)', needsBody \(m.needsBody)")
    }
}
```

## Expected vs actual
Expected: body "Price 250" or `needsBody == true`.
Actual: subject "Offer v2", body "Price 100", needsBody false.

Actual (test run):
```
􀢄  Test draftEditedOnTheServerShowsItsNewText() recorded an issue at Probe_E2ETests.swift:435:9: Expectation failed: m.body == "Price 250" || m.needsBody
􀄵  subject 'Offer v2' with body 'Price 100', needsBody false
􀄵  m.body == "Price 250" || m.needsBody → false
􀄵    m.body == "Price 250" → false
􀄵    m.needsBody → false
􀢄  Test draftEditedOnTheServerShowsItsNewText() failed after 10.594 seconds with 1 issue.
```

## Why expected
README: Drafts are synced ("Inbox, Drafts, Sent, Junk, Deleted Items and Archive are synced"); ⚠️ Mail shows a draft as last saved (recalled).

## Likely cause
`Sources/MailModel/MailStore.swift:608-611`: `if old.bodyLoaded && !m.bodyLoaded { m.body = old.body; m.attachments = old.attachments; … m.bodyLoaded = true }` – no check whether the item changed (subject, change key, size).

## Also seen by
The EWS-flow hunt hit the same root cause (`probeDraftEditedElsewhereShowsNewText`, `probeDraftEditedElsewhereShowsNewTextStaticFile` in `specs/bugs/probes/Probe_EWSFlowTests.swift`).
