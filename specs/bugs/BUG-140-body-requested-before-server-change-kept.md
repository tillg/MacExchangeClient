---
title: 'A body requested before the server changed the message is stored as the body of the new version and never fetched again'
priority: P3
area: MailStore
status: open
found: 2026-11-13
---
## Summary
Opening a message sends GetItem; if a sync brings a new version of the same item (e.g. a draft edited in OWA/Outlook, which Exchange keeps under its ItemId; ⚠️ update shape from the protocol, as in BUG-103, not a live capture) before the answer arrives, the old answer is written into the new version: new subject, old text, old sender/recipients and attachments, marked loaded. `needsBody` is false, so it is never fetched again (also after relaunch).

## Repro
Run: `swift test --package-path <COPY> --scratch-path <COPY>/.build/tests --skip-build --filter Probe_Race4` (file `specs/bugs/probes/Probe_Race4Tests.swift` of the copy `copies/r4race`). Tests: `probeBodyRequestedBeforeServerChangeIsNotKept`.
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

    // MARK: B. A body requested before the server changed the message is stored after the change

    /// The body request goes out; a sync then brings a new version of the message (edited draft, updated meeting);
    /// then the answer to the old request arrives. It is stored as the body of the new version and marked loaded,
    /// so the new text is never fetched.
    // file:// fixture
    @Test func probeBodyRequestedBeforeServerChangeIsNotKept() async throws {
        let server = RaceServer([], hold: true)
        defer { server.stop() }
        let s = store(server)
        s.merge([summary("R1", box: .drafts, subject: "Plan v1", preview: "old text")], account: acct.id, mailbox: .drafts)
        let id = s.messages[0].id
        let t = Task { await s.loadBody(id) }
        try await Task.sleep(for: .milliseconds(300))  // GetItem is out; Exchange has the old version
        // Meanwhile the quick check brings the edited draft (same ItemId, as Exchange keeps it on an edit).
        s.apply(SyncResult(upserts: [summary("R1", box: .drafts, subject: "Plan v2", preview: "new text")], deletedRemoteIDs: [],
                           token: "T1", more: false), account: acct.id, mailbox: .drafts)
        #expect(s.message(id)?.subject == "Plan v2")
        server.push(RX.getItem(RX.textMessage("R1", subject: "Plan v1", body: "old text")))
        await t.value
        try #require(s.status == nil, "the body request failed: \(s.status ?? "")")
        let m = try #require(s.message(id))
        // Either the new text, or the body still to be fetched: never the old text under the new subject.
        #expect(m.body != "old text" || m.needsBody, "subject \(m.subject), body \(m.body), needsBody \(m.needsBody)")
    }
}
```

## Expected vs actual
```
􀢄  Test probeBodyRequestedBeforeServerChangeIsNotKept() recorded an issue at Probe_Race4Tests.swift:219:9: Expectation failed: m.body != "old text" || m.needsBody
􀄵  m.body != "old text" || m.needsBody → false
􀄵    m.body != "old text" → false
􀄵    m.needsBody → false
􀢄  Test probeBodyRequestedBeforeServerChangeIsNotKept() failed after 0.374 seconds with 1 issue.
```

## Why expected
The list shows the server's current subject and preview ("new text"), the message view the old text: what you read isn't what is on the server. A message is fetched "the first time it is shown" (MailStore.swift `loadBody` doc) precisely so the view shows the server's content. This is not BUG-103: there the merge copies an already *loaded* body into the update; here nothing is loaded when the update is merged (the merge correctly leaves it unloaded), and `setBody` then stamps the stale answer onto the new version. A fix for BUG-103 (e.g. dropping the loaded body on a changed ChangeKey) doesn't cover it.

## Likely cause
`Sources/MailModel/MailStore.swift:1143-1149` (`loadBody`) captures the message and its `remoteID`, awaits `backend.body`, then calls `setBody(_, for: id)` (`:946-959`), which finds the message by local ID and sets `body`, `attachments`, `from/to/cc`, `html` and `bodyLoaded = true` without checking that the message is still the version the body was requested for (e.g. unchanged since the request: same `changeCount`-style stamp, ChangeKey, or still `!bodyLoaded` with the same summary).
