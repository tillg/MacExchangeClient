---
title: 'An invite answered while it is part of a multi-selection stays selected in Trash; Delete then erases it'
priority: P3
area: MailStore
status: open
found: 2026-11-13
---
## Summary
Answering moves the invite to Trash. `answer()` only takes care of the selection when the invite is the whole selection. When it is one of several selected messages (e.g. Send in the Respond with Comments window after selecting more messages in the main window), it stays selected while it sits unseen in Trash; the next Delete erases it from Trash along with moving the others.

## Repro
Run: `swift test --filter Probe_E2ETests/inviteAnsweredWhileInAMultiSelectionIsNotErasedByDelete` (all in `specs/bugs/probes/Probe_E2ETests.swift` of the copy).

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
    /// A message answered while it is part of a multi-selection (the comment window's Send, pressed after
    /// selecting more messages in the main window) goes to Trash but stays selected; Delete then erases it
    /// from Trash, unseen.
    @Test func inviteAnsweredWhileInAMultiSelectionIsNotErasedByDelete() {
        let s = MailStore(accounts: [a], messages: [])
        var inv = server("INV", minutes: 2)
        inv.invite = Invite(start: Date(timeIntervalSince1970: 1_800_000_000), end: Date(timeIntervalSince1970: 1_800_003_600))
        s.apply(page([inv, server("X", minutes: 1), server("Y", minutes: 0)]), account: a.id, mailbox: .inbox)
        let invID = s.messages.first { $0.remoteID == "INV" }!.id, x = s.messages.first { $0.remoteID == "X" }!.id
        s.selectedMailbox = .account(a.id, .inbox)
        s.selection = [invID, x]
        s.respond(InviteReply(response: .accept, comment: "ok"), to: invID)
        #expect(s.message(invID)?.mailbox == .trash)
        #expect(!s.selection.contains(invID), "the answered invite (now in Trash) is still selected")
        s.deleteSelection()
        #expect(s.message(invID) != nil, "Delete erased the answered invite from Trash")
    }
}
```

## Expected vs actual
Expected: the answered invite leaves the selection (as after any move out of the list), and Delete doesn't erase it.
Actual: it is still selected and Delete erases it.

Actual (test run):
```
􀢄  Test inviteAnsweredWhileInAMultiSelectionIsNotErasedByDelete() recorded an issue at Probe_E2ETests.swift:172:9: Expectation failed: !s.selection.contains(invID)
􀄵  the answered invite (now in Trash) is still selected
􀄵  !s.selection.contains(invID) → true
􀄵    s.selection.contains(invID) → false
􀄵      s.selection → [0199D7C1-25DF-4128-B663-CD31CE13CACB, 3CF53BEF-EAA2-4F9A-A136-3F3633F83018]
􀄵      invID → 3CF53BEF-EAA2-4F9A-A136-3F3633F83018
􀢄  Test inviteAnsweredWhileInAMultiSelectionIsNotErasedByDelete() recorded an issue at Probe_E2ETests.swift:174:9: Expectation failed: s.message(invID) != nil
􀄵  Delete erased the answered invite from Trash
􀄵  s.message(invID) != nil → false
􀄵    s.message(invID) → nil
􀢄  Test inviteAnsweredWhileInAMultiSelectionIsNotErasedByDelete() failed after 12.502 seconds with 2 issues.
```

## Why expected
README: "a message that leaves the list (also by swipe or context menu) never stays selected, so a second Delete can't erase it from Trash unseen" (the BUG-002 fix). This path was left out of that fix.

## Likely cause
`Sources/MailModel/MailStore.swift:938`: `if selection == [id] { actOnSelection(apply) } else { apply([id]) }` – the multi-selection branch moves the message to Trash without `keepingSelectionVisible`.
