---
title: 'A refused erase queued behind a move to Trash puts the message back with its old ItemId; the next Trash check then shows it twice'
priority: P3
area: MailStore
status: open
found: 2026-11-13
---
## Summary
Delete pressed twice on a server message before the first change reaches Exchange (Delete, then Delete again in Trash; or Delete in the Inbox and erase from Trash right after) queues a move to Trash and an erase. The move's answer renames the message (Exchange gives moved items a new ItemId) in memory and in the queued erase's IDs, but not in the copy the erase keeps for undoing. When Exchange refuses the erase, the message is put back from that copy, with the old ItemId: it can't be changed or erased any more (requests go to an ID that no longer exists), and the next Trash check, which lists the new ID, adds the same message a second time.

## Repro
Run: `swift test --package-path <COPY> --scratch-path <COPY>/.build/tests --skip-build --filter Probe_Race4` (file `specs/bugs/probes/Probe_Race4Tests.swift` of the copy `copies/r4race`). Tests: `probeRefusedEraseAfterRenameKeepsNewID`.
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

    // MARK: E. A refused erase, queued behind the move that renamed the message, brings it back under its old ID

    /// Delete twice on a server message before the first change is written: a move to Trash and an erase are queued.
    /// The move's answer renames R1 to T1 in the queued erase. Exchange refuses the erase; the message is put back,
    /// but from the copy taken when the erase was queued, with the old ID R1. The next Trash check lists T1, which
    /// is then added a second time.
    // file:// fixture
    @Test func probeRefusedEraseAfterRenameKeepsNewID() async throws {
        let server = RaceServer([RX.moved(["T1"]), RX.fault("ErrorAccessDenied", "Access is denied.")])
        defer { server.stop() }
        let s = store(server)
        s.merge([summary("R1")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        s.delete([id])  // to Trash (queued move)
        s.delete([id])  // erase from Trash (queued delete of R1)
        try await waitFor { s.outbox.isEmpty }
        try #require(s.outbox.isEmpty, "the changes never reached the server: \(s.status ?? "")")
        try #require(s.status?.hasPrefix("Exchange refused a change") == true, "status \(s.status ?? "nil")")
        #expect(s.message(id)?.remoteID == "T1", "the erase was refused, the message is back with ID \(s.message(id)?.remoteID ?? "none")")
        s.merge([summary("T1", box: .trash)], account: acct.id, mailbox: .trash)  // next Trash check
        #expect(s.count(.account(acct.id, .trash)) == 1, "trash \(s.messages.filter { $0.mailbox == .trash }.map { $0.remoteID ?? "" })")
    }

    /// Control: the same two deletes, both accepted.
    // file:// fixture
    @Test func controlMoveThenEraseBothAccepted() async throws {
        let server = RaceServer([RX.moved(["T1"]), RX.resp("DeleteItem", RX.ok("DeleteItem"))])
        defer { server.stop() }
        let s = store(server)
        s.merge([summary("R1")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        s.delete([id]); s.delete([id])
        try await waitFor { s.outbox.isEmpty }
        try #require(s.outbox.isEmpty)
        #expect(s.messages.isEmpty && s.status == nil, "status \(s.status ?? "nil")")
    }
}
```

## Expected vs actual
```
􀢄  Test probeRefusedEraseAfterRenameKeepsNewID() recorded an issue at Probe_Race4Tests.swift:345:9: Expectation failed: s.message(id)?.remoteID == "T1"
􀄵  s.message(id)?.remoteID == "T1" → false
􀄵    s.message(id)?.remoteID → "R1"
􀄵      some → "R1"
􀄵      some → "T1"
􀢄  Test probeRefusedEraseAfterRenameKeepsNewID() recorded an issue at Probe_Race4Tests.swift:347:9: Expectation failed: s.count(.account(acct.id, .trash)) == 1
􀄵  s.count(.account(acct.id, .trash)) == 1 → false
􀄵    s.count(.account(acct.id, .trash)) → 2
􀢄  Test probeRefusedEraseAfterRenameKeepsNewID() failed after 0.546 seconds with 2 issues.
```

## Why expected
After an erase is refused, the message should be back as it is on the server (README / BUG-023 fix: "Only a refused erase re-adds the message"), i.e. under the ID Exchange now has for it; the same message must not appear twice. The control `controlMoveThenEraseBothAccepted` shows the queued pair works when both are accepted. Not BUG-023 (fixed: which fields an undo restores) nor BUG-059 (one missing item fails a batch) nor BUG-061 (transient errors treated as refusals; this probe uses a real refusal, ErrorAccessDenied): the root here is the rename skipping `PendingChange.previous`.

## Likely cause
`Sources/MailModel/MailStore.swift:816-822` (`renameRemote`): renames `messages[i].remoteID` and `outbox[i].change` (`renamed(map)`), but leaves `outbox[i].previous` with the old `remoteID`. `failed` (`:842-848`) re-adds a refused erase with `messages.append(old)` from `p.previous`, so the restored message carries the pre-move ID; `merge` (`:657-671`) then doesn't recognise the server's new ID and appends a second copy.
