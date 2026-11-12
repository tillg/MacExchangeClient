---
title: 'Mark as Read with the unread filter on, or Clear Flag in Flagged, leaves the messages selected after they left the list'
priority: P4
area: MailStore
status: open
found: 2026-11-13
---
## Summary
Read and flag changes don't go through `keepingSelectionVisible`. With the unread filter on, marking a multi-selection read (Message ▸ Mark as Read, ⇧⌘U) takes the messages out of the list but they stay selected; in Trash, the next Delete erases them unseen (probed). The same in Flagged with Clear Flag: the message leaves the list and stays selected.

## Repro
Run: `swift test --filter Probe_E2ETests/markingAHiddenSelectionReadDoesNotLeaveItSelectedForErase` (all in `specs/bugs/probes/Probe_E2ETests.swift` of the copy).

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
    /// With the unread filter on (Trash), two selected unread messages are marked read: they leave the list
    /// but stay selected. Delete then erases them from Trash without them being on screen.
    @Test func markingAHiddenSelectionReadDoesNotLeaveItSelectedForErase() {
        let s = MailStore(accounts: [a], messages: [])
        s.apply(page([server("T1", minutes: 2), server("T2", minutes: 1), server("T3", minutes: 0)]), account: a.id, mailbox: .trash)
        let t1 = s.messages.first { $0.remoteID == "T1" }!.id, t2 = s.messages.first { $0.remoteID == "T2" }!.id
        s.selectedMailbox = .account(a.id, .trash)
        s.filterUnread = true
        s.selection = [t1, t2]
        s.toggleRead(s.selection)  // Message ▸ Mark as Read (⇧⌘U)
        let visible = Set(s.visibleMessages.map(\.id))
        #expect(s.selection.isSubset(of: visible), "selection \(s.selection.count) not in the list of \(visible.count)")
        s.deleteSelection()
        #expect(s.message(t1) != nil && s.message(t2) != nil, "Delete erased the two hidden messages from Trash")
    }

    /// Same with the flag: in Flagged, unflagging the selected message takes it out of the list, it stays selected.
    @Test func unflaggingInFlaggedDoesNotKeepAHiddenSelection() {
        let s = MailStore(accounts: [a], messages: [])
        s.apply(page([server("F1", flagged: true, minutes: 1), server("F2", flagged: true)]), account: a.id, mailbox: .inbox)
        let f1 = s.messages.first { $0.remoteID == "F1" }!.id
        s.selectedMailbox = .smart(.flagged)
        s.selection = [f1]
        s.setFlag(nil, for: [f1])
        #expect(s.selection.isSubset(of: Set(s.visibleMessages.map(\.id))))
    }
}
```

## Expected vs actual
Expected: the selection only holds messages in the list.
Actual: two selected Trash messages not in the list of 1, and Delete erases both; the unflagged message stays selected in Flagged.

Actual (test run):
```
􀢄  Test markingAHiddenSelectionReadDoesNotLeaveItSelectedForErase() recorded an issue at Probe_E2ETests.swift:188:9: Expectation failed: s.selection.isSubset(of: visible)
􀄵  selection 2 not in the list of 1
􀄵  s.selection.isSubset(of: visible) → false
􀄵    s.selection → [012127A8-A367-4F93-8217-9F5B7E30814E, 4A6B6291-4AFB-4C00-8BB1-66AAB95E0166]
􀄵    visible → [313FF822-DC4D-44EE-B648-A22ACB957F05]
􀢄  Test markingAHiddenSelectionReadDoesNotLeaveItSelectedForErase() recorded an issue at Probe_E2ETests.swift:190:9: Expectation failed: s.message(t1) != nil && s.message(t2) != nil
􀄵  Delete erased the two hidden messages from Trash
􀄵  s.message(t1) != nil && s.message(t2) != nil → false
􀄵    s.message(t1) != nil → false
􀄵    s.message(t2) != nil → <not evaluated>
􀢄  Test markingAHiddenSelectionReadDoesNotLeaveItSelectedForErase() failed after 12.505 seconds with 2 issues.

􀢄  Test unflaggingInFlaggedDoesNotKeepAHiddenSelection() recorded an issue at Probe_E2ETests.swift:201:9: Expectation failed: s.selection.isSubset(of: Set(s.visibleMessages.map(\.id)))
􀄵  s.selection.isSubset(of: Set(s.visibleMessages.map(\.id))) → false
􀄵    s.selection → [4AA7231B-A6BB-4ADC-9752-380588897688]
􀄵    Set(s.visibleMessages.map(\.id)) → [9CAB308F-B78C-4488-AAC9-F3C473A9E102]
􀢄  Test unflaggingInFlaggedDoesNotKeepAHiddenSelection() failed after 12.505 seconds with 1 issue.
```

## Why expected
README (BUG-002 and BUG-006 fixes): "a message that leaves the list … never stays selected"; opened-unread messages are kept on purpose (BUG-006), these are not opened messages.

## Likely cause
`Sources/MailModel/MailStore.swift:430-435`: `setFlag` and `toggleRead` call `update` directly, unlike `move`/`delete` (`:385-400`) which wrap it in `keepingSelectionVisible`.
