---
title: 'A send or Save Draft with files that fails after the message was created leaves a copy without its files in Exchange''s Drafts'
priority: P3
area: EWS
status: open
found: 2026-11-13
---
## Summary
With files, Send and Save Draft first create the message in Exchange's Drafts, then add the files, then send. If adding the files (or sending) fails, the clean-up `delete` is a `try?`: when it fails too, nothing remembers the item. Run here: two `ErrorServerBusy` faults in a row (CreateAttachment, then the DeleteItem); ⚠️ a dropped connection would presumably end the same way (not run: the pipe harness can't drop the connection reliably). The next Drafts sync shows that copy, without its files, next to the copy the app keeps "in Drafts on this Mac": two drafts, one of them missing the attachment, and the half one stays on the server for good.

## Repro
Harness (`FlowServer`, `FX`, `store(_:)`, `complete(_:_:)`, `serverMessage`, `waitFor`): top of `specs/bugs/probes/Probe_EWSFlowTests.swift` in the copy (`// file:// fixture (FIFO)`: a named pipe at a `file://` URL serves the scripted responses in order to the real EWSClient; no network, no fake class). The full harness is quoted in R3-EWSFlow-01.

```swift
    // file:// fixture (FIFO)
    /// Sending with files: the message is created in Exchange's Drafts, then adding the files fails (throttling,
    /// a dropped connection) and so does the clean-up delete. The copy without its files stays in Exchange's Drafts,
    /// and the next Drafts sync shows it next to the copy kept on this Mac. Nothing ever removes it.
    // file:// fixture
    @Test func probeFailedSendWithFilesLeavesNoHalfDraft() async throws {
        let busy = FX.fault("ErrorServerBusy", "The server cannot service this request right now. Try again later.")
        let server = FlowServer([FX.created("D1"), busy, busy,
                                     FX.sync("", token: "T1", last: true),   // Inbox
                                     FX.sync(FX.create(FX.summary("D1", subject: "Contract", read: true, preview: "Signed copy attached")), token: "T1", last: true)])
        defer { server.stop() }
        let s = store(server)
        complete(s, .inbox); complete(s, .drafts)
        var d = Draft(accountID: acct.id, to: "bob@x.com", subject: "Contract", body: "Signed copy attached")
        d.attachments = [DraftAttachment(name: "contract.pdf", contentType: "application/pdf", data: Data(repeating: 1, count: 500))]
        s.send(d)
        try await waitFor { s.outbox.isEmpty }
        let status = s.status
        s.selectedMailbox = .account(acct.id, .drafts)
        await s.refresh(history: false)
        let drafts = s.messages.filter { $0.mailbox == .drafts }
        #expect(drafts.count == 1, "Drafts: \(drafts.map { "\($0.subject) remote=\($0.remoteID ?? "-") files=\($0.attachments.count)" }); requests \(server.served); status after send: \(String(describing: status))")
    }

    // file:// fixture (FIFO)
    /// The same for Save Draft with files.
    // file:// fixture
    @Test func probeFailedSaveDraftWithFilesLeavesNoHalfDraft() async throws {
        let busy = FX.fault("ErrorServerBusy", "The server cannot service this request right now. Try again later.")
        let server = FlowServer([FX.created("D1"), busy, busy,
                                     FX.sync("", token: "T1", last: true),
                                     FX.sync(FX.create(FX.summary("D1", subject: "Contract", read: true)), token: "T1", last: true)])
        defer { server.stop() }
        let s = store(server)
        complete(s, .inbox); complete(s, .drafts)
        var d = Draft(accountID: acct.id, to: "bob@x.com", subject: "Contract", body: "Draft")
        d.attachments = [DraftAttachment(name: "contract.pdf", contentType: "application/pdf", data: Data(repeating: 1, count: 500))]
        s.saveDraft(d)
        try await waitFor { s.outbox.isEmpty }
        s.selectedMailbox = .account(acct.id, .drafts)
        await s.refresh(history: false)
        let drafts = s.messages.filter { $0.mailbox == .drafts }
        #expect(drafts.count == 1, "Drafts: \(drafts.map { "remote=\($0.remoteID ?? "-") files=\($0.attachments.count)" }); requests \(server.served)")
    }
```

## Expected vs actual
Expected: one draft (the local copy with its file); the half-created server item is removed once possible.
Actual:
```
probeFailedSendWithFilesLeavesNoHalfDraft: Expectation failed: drafts.count == 1
  Drafts: ["Contract remote=- files=1", "Contract remote=D1 files=0"]; requests 5; status after send: Optional("Couldn't send “Contract”: The server cannot service this request right now. Try again later. (ErrorServerBusy). It's in Drafts on this Mac.")
probeFailedSaveDraftWithFilesLeavesNoHalfDraft: Expectation failed: drafts.count == 1
  Drafts: ["remote=- files=1", "remote=D1 files=0"]; requests 5
```

## Why expected
The code's own intent (`EWSBackend.swift:263, 287`): "don't leave a second copy in Exchange's Drafts" / "no half message in Exchange's Drafts". README: a message that fails to send "is kept in Drafts on this Mac" — one copy, with its files.

## Likely cause
`Sources/EWS/EWSBackend.swift:265` and `:287`: `try? await delete([item.id])` — a failed clean-up is dropped silently; the created item's ID isn't returned to the store or queued for a later delete (`MailStore.failed`, `MailStore.swift:770-783`, only adds the local copy).
