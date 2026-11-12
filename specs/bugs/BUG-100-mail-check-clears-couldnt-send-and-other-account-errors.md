---
title: 'Each mail check clears the status: "Couldn''t send …" and another account''s error disappear'
priority: P3
area: MailStore
status: open
found: 2026-11-13
---
## Summary
`refresh()` sets `status = historyError` (usually nil) after every account it checked successfully. The notice that a message couldn't be sent ("Couldn't send “…”: … It's in Drafts on this Mac.") is gone at the next 15-second check (not probed: also at once when the failed send is drained inside a check); a user who was not looking never learns the mail didn't go. With two accounts, the second account's successful check also wipes the first one's error.

## Repro
Run: `swift test --filter Probe_E2ETests/couldntSendNoticeSurvivesTheNextCheck` (all in `specs/bugs/probes/Probe_E2ETests.swift` of the copy).

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
    /// A send Exchange refuses is kept in Drafts with "Couldn't send …" under the window title. The next
    /// quick check (at most 15 s later, also one already running) replaces the notice with nil.
    @Test func couldntSendNoticeSurvivesTheNextCheck() async throws {
        let file = try responseFile(error("ErrorInvalidRecipients"))  // file:// fixture
        let s = MailStore(accounts: [], messages: [])
        s.add(a, backend: backend(file))
        s.send(Draft(accountID: a.id, to: "nobody", subject: "Quarterly report", body: "b"))
        try await waitUntil { s.outbox.isEmpty }
        #expect(s.status?.contains("Couldn't send") == true)
        try Data(success.utf8).write(to: file)  // the server answers normally again
        await s.refresh(history: false)  // the next 15-second check
        #expect(s.status?.contains("Couldn't send") == true, "status after the next check: \(s.status ?? "nil")")
    }

    /// Two accounts: the first one's check fails, the second one's succeeds and clears the error, so nothing
    /// says the first account wasn't checked. Run over several account pairs: the order follows the dictionary.
    @Test func oneAccountsErrorIsNotClearedByTheOthersSuccess() async throws {
        let ok = try responseFile(success)  // file:// fixture
        let bad = try responseFile(error("ErrorMailboxMoveInProgress"))
        var cleared = 0
        for _ in 0..<32 {
            let x = Account(name: "Work", address: "me@work.com"), y = Account(name: "Club", address: "me@club.org")
            let s = MailStore(accounts: [], messages: [])
            s.add(x, backend: backend(bad))
            s.add(y, backend: backend(ok))
            await s.refresh(history: false)
            if s.status == nil { cleared += 1 }
        }
        #expect(cleared == 0, "the failing account's error was gone after \(cleared) of 32 checks")
    }
}
```

## Expected vs actual
Expected: the failed-send notice stays until the user has had a chance to see it, and a failing account's error isn't replaced by another account's success.
Actual: status is nil after the next check; the failing account's error was gone in about half of the account pairs (depends on dictionary order).

Actual (test run):
```
􀢄  Test couldntSendNoticeSurvivesTheNextCheck() recorded an issue at Probe_E2ETests.swift:338:9: Expectation failed: s.status?.contains("Couldn't send") == true
􀄵  status after the next check: nil
􀄵  s.status?.contains("Couldn't send") == true → false
􀄵    s.status?.contains("Couldn't send") → nil
􀄵      some → true
􀢄  Test couldntSendNoticeSurvivesTheNextCheck() failed after 12.512 seconds with 1 issue.

􀢄  Test oneAccountsErrorIsNotClearedByTheOthersSuccess() recorded an issue at Probe_E2ETests.swift:355:9: Expectation failed: cleared == 0
􀄵  the failing account's error was gone after 18 of 32 checks
􀄵  cleared == 0 → false
􀄵    cleared → 18
􀢄  Test oneAccountsErrorIsNotClearedByTheOthersSuccess() failed after 12.566 seconds with 1 issue.
```

## Why expected
README: "If the server refuses a change, it is undone and the reason shows under the window title"; "A message that fails to send is … kept in Drafts on this Mac instead" – the notice is the only sign.

## Likely cause
`Sources/MailModel/MailStore.swift:1105`: `status = historyError` inside the per-account loop overwrites any status, including the one `failed()` set (`:782`) and the previous account's error (`:1108`).

## Also seen by
The EWS-flow hunt hit the same root cause (`probeFailedSendDuringRefreshStaysVisible`, `probeFailedSendNoticeSurvivesNextCheck`, `probeFailedSendNoticeSurvivesNextCheckStaticFile`, `probeOneAccountsErrorNotHiddenByAnother`, `probeRefusedChangeDuringRefreshStaysVisible` in `specs/bugs/probes/Probe_EWSFlowTests.swift`).
