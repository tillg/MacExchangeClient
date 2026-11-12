---
title: 'Respond with Comments that fails with a network error is undone and the typed comment is lost'
priority: P3
area: MailStore
status: open
found: 2026-11-13
---
## Summary
An invite answer with a comment that hits a network error (`URLError`) is treated like a refusal: the invite goes back to the Inbox unanswered, the status says "Exchange refused a change: …", and the comment the user wrote in the message window is discarded. A failed send in the same situation is kept in Drafts. The fixture is a missing response file (`URLError` fileDoesNotExist), standing in for any network error. Different from BUG-061 (server-side transient errors) and BUG-069 (invite gone): here the user's text is lost.

## Repro
Run: `swift test --filter Probe_E2ETests/inviteAnswerWithCommentIsNotLostWhenOffline` (all in `specs/bugs/probes/Probe_E2ETests.swift` of the copy).

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
    /// Respond with Comments while the server can't be reached: the answer is undone ("Exchange refused a
    /// change") and the comment the user typed is gone, while a failed send is kept in Drafts.
    @Test func inviteAnswerWithCommentIsNotLostWhenOffline() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("ews-e2e-missing-\(UUID().uuidString).xml")
        let s = MailStore(accounts: [], messages: [])
        s.add(a, backend: backend(missing))  // file:// fixture (absent: offline)
        var inv = server("INV")
        inv.invite = Invite(start: Date(timeIntervalSince1970: 1_800_000_000), end: Date(timeIntervalSince1970: 1_800_003_600))
        s.apply(page([inv]), account: a.id, mailbox: .inbox)
        let id = s.messages[0].id
        s.selectedMailbox = .account(a.id, .inbox)
        s.selection = [id]
        let comment = "I can join for the first half hour only, then I have to leave for the airport."
        s.send(Draft(accountID: a.id, to: "org@x.com", subject: "Accepted: Q4", body: comment,
                     inviteAnswer: InviteAnswer(messageID: id, response: .accept)))
        try await waitUntil { s.outbox.isEmpty }
        let kept = s.messages.contains { $0.body.contains(comment) } || s.outbox.contains {
            if case let .reply(_, r) = $0.change { r.comment == comment } else { false }
        }
        #expect(kept, "status: \(s.status ?? "nil"); invite back in \(s.message(id)?.mailbox.rawValue ?? "-")")
    }
}
```

## Expected vs actual
Expected: the comment survives somewhere (kept queued, or kept in Drafts like a failed send).
Actual: status "Exchange refused a change: The requested URL was not found on this server.", invite back in inbox, comment nowhere.

Actual (test run):
```
􀢄  Test inviteAnswerWithCommentIsNotLostWhenOffline() recorded an issue at Probe_E2ETests.swift:472:9: Expectation failed: kept
􀄵  status: Exchange refused a change: The requested URL was not found on this server.; invite back in inbox
􀄵  kept → <not evaluated>
􀢄  Test inviteAnswerWithCommentIsNotLostWhenOffline() failed after 12.502 seconds with 1 issue.
```

## Why expected
README: "A message that fails to send is never resent automatically. It is kept in Drafts on this Mac instead." The Respond with Comments window is a message window (README: "its text becomes the comment").

## Likely cause
`Sources/MailModel/MailStore.swift:820-821`: on `URLError`, `.respond`/`.reply` go to `failed()`, whose default branch (`:783-795`) restores the old message; only `.send`/`.saveDraft` (`:773-782`) keep the text.
