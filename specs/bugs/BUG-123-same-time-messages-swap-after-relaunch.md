---
title: 'Messages with the same time swap places in Flagged (and other mixed lists) after a relaunch'
priority: P4
area: MailStore
status: open
found: 2026-11-13
---
## Summary
Lists sort only by date. Ties keep the order of the `messages` array, which the staged launch changes (Inboxes first, then the rest), so two messages received in the same second in different mailboxes (a mailing-list burst, a reply and its copy) swap places in Flagged after a relaunch (not probed: Delete would then select a different 'next' message).

## Repro
Run: `swift test --filter Probe_E2ETests/sameTimeMessagesKeepTheirOrderAfterRelaunch` (all in `specs/bugs/probes/Probe_E2ETests.swift` of the copy).

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
    /// Messages received in the same second (a mailing-list burst) keep their order in Flagged across a relaunch.
    @Test func sameTimeMessagesKeepTheirOrderAfterRelaunch() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = MailStore(accounts: [a], messages: [])
        let db = try MailDatabase(url: url)
        s.apply(page([server("ARCH", flagged: true, minutes: 5)]), account: a.id, mailbox: .archive)
        s.apply(page([server("INB", flagged: true, minutes: 5)]), account: a.id, mailbox: .inbox)
        s.selectedMailbox = .smart(.flagged)
        let before = s.visibleMessages.map(\.remoteID)
        let (s2, _) = try relaunch(s, db, url)
        s2.selectedMailbox = .smart(.flagged)
        #expect(s2.visibleMessages.map(\.remoteID) == before)
    }
}
```

## Expected vs actual
Expected: [ARCH, INB] as before the relaunch.
Actual: [INB, ARCH].

Actual (test run):
```
􀢄  Test sameTimeMessagesKeepTheirOrderAfterRelaunch() recorded an issue at Probe_E2ETests.swift:450:9: Expectation failed: s2.visibleMessages.map(\.remoteID) == before
􀄵  s2.visibleMessages.map(\.remoteID) == before → false
􀄵    s2.visibleMessages.map(\.remoteID) → [Optional("INB"), Optional("ARCH")]
􀄵    before → [Optional("ARCH"), Optional("INB")]
􀢄  Test sameTimeMessagesKeepTheirOrderAfterRelaunch() failed after 12.502 seconds with 1 issue.
```

## Why expected
Brief invariant: the same state after relaunch. ⚠️ Mail's list keeps a fixed order for equal dates (recalled).

## Likely cause
`Sources/MailModel/MailStore.swift:206` (and `hitList`, `:223`): `.sorted { $0.date > $1.date }` without a tie-breaker; `restore(_:boxes:)`/`finishLoading` (`:706-716`) put the Inbox first.
