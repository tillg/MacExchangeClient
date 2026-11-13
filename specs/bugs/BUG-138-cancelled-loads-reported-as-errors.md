---
title: 'Moving on from a message before it has loaded shows "Couldn’t load message: cancelled" (also images, calendar, attachment previews)'
priority: P3
area: MailStore
status: open
found: 2026-11-13
---
## Summary
The message view loads the body, its inline pictures and the invite's calendar day in `.task(id: message.id)`, and the attachment thumbnails in AttachmentsView's `.task(id: message.id)`. Selecting another message (arrowing down the list, or holding the arrow key) cancels these tasks; URLSession then throws `URLError.cancelled`, and the store reports it like a real failure: "Couldn't load message: cancelled", "Couldn't load images: cancelled", "Couldn't load the calendar: cancelled", "Couldn't open “photo.jpg”: cancelled" under the window title, until the next check clears it. Happens whether the request was already out or not yet sent.

## Repro
Run: `swift test --package-path <COPY> --scratch-path <COPY>/.build/tests --skip-build --filter Probe_Race4` (file `specs/bugs/probes/Probe_Race4Tests.swift` of the copy `copies/r4race`). Tests: `probeBodyLoadCancelledBeforeStartIsNotAnError`, `probeCancelledInlineImagesAreNotAnError`, `probeCancelledDayLoadIsNotAnError`, `probeCancelledThumbnailIsNotAnError`, `zzProbeCancelledInFlightBodyLoadIsNotAnError`.
The interleaving is driven deterministically: the real EWSClient/EWSBackend read hand-written Exchange responses from a
named pipe at a `file://` URL (`RaceServer`, `hold: true` keeps a request waiting until the test pushes the answer); the
other side of the race is played with the store's own calls in race order. No network, no fake classes.

```swift
import Foundation
import Testing
@testable import EWS
@testable import MailModel

// MARK: - Harness

/// file:// fixture (FIFO), as in Probe_EWSFlowTests: a named pipe at a `file://` URL stands in for the EWS endpoint.
/// The real EWSClient opens the pipe for every request and reads the next scripted response. With `hold`, a request
/// waits until a response is pushed, so the test decides when the server's answer arrives.
final class RaceServer: @unchecked Sendable {
    let url: URL
    private let path: String
    private let lock = NSLock()
    private var script: [String]
    private var stopped = false
    private let hold: Bool
    private var _served = 0
    var served: Int { lock.withLock { _served } }

    init(_ script: [String], hold: Bool = false) {
        self.hold = hold
        path = FileManager.default.temporaryDirectory.appendingPathComponent("race-fifo-\(UUID().uuidString).xml").path
        mkfifo(path, 0o600)
        url = URL(fileURLWithPath: path)
        self.script = script
        Thread { [self] in loop() }.start()
    }

    func push(_ xml: String) { lock.withLock { script.append(xml) } }
    func stop() { lock.withLock { stopped = true } }

    private func loop() {
        signal(SIGPIPE, SIG_IGN)
        while true {
            if lock.withLock({ stopped }) { return }
            if lock.withLock({ hold && script.isEmpty }) { usleep(500); continue }
            let fd = open(path, O_WRONLY | O_NONBLOCK)
            if fd < 0 { usleep(500); continue }
            _ = fcntl(fd, F_SETFL, 0)
            let xml = lock.withLock { script.isEmpty ? RX.fault("ErrorScriptExhausted", "No scripted response left") : script.removeFirst() }
            let bytes = Array(xml.utf8)
            var off = 0
            while off < bytes.count {
                let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                off += n
            }
            lock.withLock { _served += 1 }
            close(fd)
            usleep(300_000)
        }
    }
}

enum RX {
    static func env(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">\
        <s:Body xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">\(body)</s:Body></s:Envelope>
        """
    }
    static let ns = "xmlns:m=\"http://schemas.microsoft.com/exchange/services/2006/messages\" xmlns:t=\"http://schemas.microsoft.com/exchange/services/2006/types\""
    static func ok(_ op: String, _ inner: String = "") -> String {
        "<m:\(op)ResponseMessage ResponseClass=\"Success\"><m:ResponseCode>NoError</m:ResponseCode>\(inner)</m:\(op)ResponseMessage>"
    }
    static func resp(_ op: String, _ messages: String) -> String {
        env("<m:\(op)Response \(ns)><m:ResponseMessages>\(messages)</m:ResponseMessages></m:\(op)Response>")
    }
    static func fault(_ code: String, _ text: String) -> String {
        env("<s:Fault><faultcode>a:\(code)</faultcode><faultstring>\(text)</faultstring></s:Fault>")
    }
    static func getItem(_ item: String) -> String { resp("GetItem", ok("GetItem", "<m:Items>\(item)</m:Items>")) }
    static func moved(_ new: [String]) -> String {
        resp("MoveItem", new.map { ok("MoveItem", "<m:Items><t:Message><t:ItemId Id=\"\($0)\" ChangeKey=\"CK\"/></t:Message></m:Items>") }.joined())
    }
    static func updated(_ ids: [String]) -> String {
        resp("UpdateItem", ids.map { ok("UpdateItem", "<m:Items><t:Message><t:ItemId Id=\"\($0)\" ChangeKey=\"CK\"/></t:Message></m:Items>") }.joined())
    }
    static func textMessage(_ id: String, subject: String, body: String) -> String {
        "<t:Message><t:ItemId Id=\"\(id)\" ChangeKey=\"CK\"/><t:Subject>\(subject)</t:Subject>"
            + "<t:Body BodyType=\"Text\">\(body)</t:Body><t:Attachments/>"
            + "<t:From><t:Mailbox><t:Name>Ann</t:Name><t:EmailAddress>ann@x.com</t:EmailAddress></t:Mailbox></t:From>"
            + "<t:ToRecipients><t:Mailbox><t:Name>Me</t:Name><t:EmailAddress>me@work.com</t:EmailAddress></t:Mailbox></t:ToRecipients>"
            + "<t:TextBody BodyType=\"Text\">\(body)</t:TextBody></t:Message>"
    }
}

@MainActor
@Suite(.serialized)
struct Probe_Race4Tests {
    let acct = Account(name: "Exchange", address: "me@work.com")

    func store(_ server: RaceServer) -> MailStore {
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: server.url, username: "u", password: "p")))
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX"), RemoteFolder(role: .drafts, id: "DRAFTS"),
                            RemoteFolder(role: .sent, id: "SENT"), RemoteFolder(role: .trash, id: "DEL"),
                            RemoteFolder(role: .archive, id: "ARCH")], account: acct.id)
        s.downloadsFolder = FileManager.default.temporaryDirectory.appendingPathComponent("race-dl-\(UUID().uuidString)")
        return s
    }

    /// A message as a list summary from the server (body not loaded).
    func summary(_ rid: String, box: MailboxKind = .inbox, subject: String? = nil, preview: String = "Preview",
                 read: Bool = false, flagged: Bool = false) -> Message {
        Message(accountID: acct.id, mailbox: box, from: Contact(name: "Ann", email: ""),
                to: [Contact(name: "Me", email: "")], subject: subject ?? "S \(rid)", body: "",
                date: Date(timeIntervalSince1970: 1_700_000_000), isRead: read, flag: flagged ? .red : nil,
                remoteID: rid, serverPreview: preview, bodyLoaded: false)
    }

    /// Lets a cancelled file:// read finish on the pipe, so it doesn't hold up URLSession's file loader for later tests.
    func drained(_ server: RaceServer) async throws {
        try await waitFor(.seconds(2)) { server.served == 1 }
        try await Task.sleep(for: .milliseconds(400))
    }

    func waitFor(_ timeout: Duration = .seconds(5), _ cond: () -> Bool) async throws {
        let end = ContinuousClock.now + timeout
        while !cond() && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
    }

    // ...

    // MARK: A. A load cancelled because the user moved on is reported as an error

    /// The message view loads in `.task(id: message.id)` (body, inline pictures, calendar day); the attachment
    /// thumbnails in AttachmentsView's `.task(id: message.id)`. Selecting the next message cancels those tasks.
    /// A cancelled request must not be reported as a failure. Cancelled before the request goes out (arrow key held
    /// down); the in-flight case is `zzProbeCancelledInFlightBodyLoadIsNotAnError` at the end (each probe feeds the
    /// pipe after cancelling: a cancelled file:// read left waiting stalls URLSession's file loader for later tests).
    // file:// fixture
    @Test func probeBodyLoadCancelledBeforeStartIsNotAnError() async throws {
        let server = RaceServer([RX.fault("Unused", "for the cancelled read")])
        defer { server.stop() }
        let s = store(server)
        s.merge([summary("R1")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        let t = Task { await s.loadBody(id) }
        t.cancel()
        await t.value
        #expect(s.status == nil)
        try await drained(server)
    }

    // file:// fixture
    @Test func probeCancelledInlineImagesAreNotAnError() async throws {
        let server = RaceServer([RX.fault("Unused", "for the cancelled read")])
        defer { server.stop() }
        let s = store(server)
        var m = summary("R1")
        m.bodyLoaded = true; m.htmlChecked = true; m.html = "<p>Hi <img src=\"cid:logo@x\"></p>"
        s.merge([m], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        let t = Task { await s.loadInlineImages(for: id) }
        t.cancel()
        await t.value
        #expect(s.status == nil)
        try await drained(server)
    }

    // file:// fixture
    @Test func probeCancelledDayLoadIsNotAnError() async throws {
        let server = RaceServer([RX.fault("Unused", "for the cancelled read")])
        defer { server.stop() }
        let s = store(server)
        var m = summary("R1")
        m.bodyLoaded = true; m.htmlChecked = true
        m.invite = Invite(start: Date(timeIntervalSince1970: 1_700_000_000), end: Date(timeIntervalSince1970: 1_700_003_600),
                          isCancellation: false)
        s.merge([m], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        let t = Task { await s.loadDay(for: id) }
        t.cancel()
        await t.value
        #expect(s.status == nil)
        try await drained(server)
    }

    // file:// fixture
    @Test func probeCancelledThumbnailIsNotAnError() async throws {
        let server = RaceServer([RX.fault("Unused", "for the cancelled read")])
        defer { server.stop() }
        let s = store(server)
        var m = summary("R1")
        m.bodyLoaded = true; m.htmlChecked = true; m.attachments = [Attachment(name: "photo.jpg", size: 10, contentType: "image/jpeg")]
        m.hasAttachments = true
        s.merge([m], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        let t = Task { await s.attachmentFile(0, of: id) }
        t.cancel()
        _ = await t.value
        #expect(s.status == nil)
        try await drained(server)
    }

    // MARK: A (continued): the in-flight variant

    /// The body request is out and the server hasn't answered when the user selects the next message.
    // file:// fixture
    @Test func zzProbeCancelledInFlightBodyLoadIsNotAnError() async throws {
        let server = RaceServer([], hold: true)
        defer { server.stop() }
        let s = store(server)
        s.merge([summary("R1")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        let t = Task { await s.loadBody(id) }
        try await Task.sleep(for: .milliseconds(300))  // the request is out, the server hasn't answered
        t.cancel()  // the user selected the next message
        await t.value
        #expect(s.status == nil)
        server.push(RX.fault("Unused", "for the cancelled read"))
        try await drained(server)
    }
}
```

## Expected vs actual
```
􀢄  Test probeBodyLoadCancelledBeforeStartIsNotAnError() recorded an issue at Probe_Race4Tests.swift:141:9: Expectation failed: s.status == nil
􀄵  s.status == nil → false
􀄵    s.status → "Couldn't load message: cancelled"
􀄵      some → "Couldn't load message: cancelled"
􀢄  Test probeBodyLoadCancelledBeforeStartIsNotAnError() failed after 0.565 seconds with 1 issue.
􀢄  Test probeCancelledInlineImagesAreNotAnError() recorded an issue at Probe_Race4Tests.swift:157:9: Expectation failed: s.status == nil
􀄵  s.status == nil → false
􀄵    s.status → "Couldn't load images: cancelled"
􀄵      some → "Couldn't load images: cancelled"
􀢄  Test probeCancelledInlineImagesAreNotAnError() failed after 0.598 seconds with 1 issue.
􀢄  Test probeCancelledDayLoadIsNotAnError() recorded an issue at Probe_Race4Tests.swift:175:9: Expectation failed: s.status == nil
􀄵  s.status == nil → false
􀄵    s.status → "Couldn't load the calendar: cancelled"
􀄵      some → "Couldn't load the calendar: cancelled"
􀢄  Test probeCancelledDayLoadIsNotAnError() failed after 0.618 seconds with 1 issue.
􀢄  Test probeCancelledThumbnailIsNotAnError() recorded an issue at Probe_Race4Tests.swift:192:9: Expectation failed: s.status == nil
􀄵  s.status == nil → false
􀄵    s.status → "Couldn't open “photo.jpg”: cancelled"
􀄵      some → "Couldn't open “photo.jpg”: cancelled"
􀢄  Test probeCancelledThumbnailIsNotAnError() failed after 0.627 seconds with 1 issue.
􀢄  Test zzProbeCancelledInFlightBodyLoadIsNotAnError() recorded an issue at Probe_Race4Tests.swift:378:9: Expectation failed: s.status == nil
􀄵  s.status == nil → false
􀄵    s.status → "Couldn't load message: cancelled"
􀄵      some → "Couldn't load message: cancelled"
􀢄  Test zzProbeCancelledInFlightBodyLoadIsNotAnError() failed after 1.038 seconds with 1 issue.
```

## Why expected
Nothing failed: the user simply moved on, and the message loads normally when selected again (`needsBody` is still true). ⚠️ Mail.app (recalled, not checked) shows no error when you arrow through unloaded messages. The status line is for real problems (README: "Last sync problem or notice, shown under the window title"); a false "Couldn't load message" hides real ones and suggests the server is broken. `EWSClient.mapError` already singles out `.cancelled` for the sign-in case, so cancellation is known to arrive as an error here.

## Likely cause
`Sources/MailModel/MailStore.swift:1147` (`loadBody`), `:1043` (`loadInlineImages`), `:973` (`loadDay`), `:1088` (`attachmentFile`): each `catch` sets `status` for any error that isn't a sign-in failure, including `CancellationError` / `URLError(.cancelled)` thrown because the calling SwiftUI task was cancelled (`Sources/MailReplica/MessageDetailView.swift:103-108`, `AttachmentsView.swift:109-112`). A check for `Task.isCancelled` (or for `.cancelled`) before setting the status is missing. The same applies to `includeOriginalAttachments` when a compose window is closed while the original files load (ComposeView `.task(id: draft.loadingOriginal)`).
