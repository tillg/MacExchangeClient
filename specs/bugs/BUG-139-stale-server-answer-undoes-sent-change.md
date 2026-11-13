---
title: 'A check answer taken before a local change, arriving after that change reached Exchange, undoes it: a moved message comes back as a ghost for good, a flag loses its colour, read turns unread'
priority: P3
area: MailStore
status: open
found: 2026-11-13
---
## Summary
`merge` protects a message from server data only while its local change is still in the outbox. A server answer requested before the user's action but applied after the change was already written to Exchange (and removed from the outbox) overwrites it. The quick check's newest-50 answer (`refresh`) and especially the history, which collects answers for up to 1.5 s before showing them (`historyBatch`), open this window. Results: (1) a message archived/moved/deleted meanwhile is added back to its old mailbox under its old ItemId. When the stale answer was a newest-N list (quick check of a folder not yet fully synced, or the history's first newest-200 pass), nothing ever reports that ID deleted: later newest-N answers only add, and a completing full sync that no longer lists it doesn't remove it, so the ghost stays (also stored and after relaunch); only an explicit deletion of the old ID removes it (control in the probe), which ⚠️ Exchange would send only if the stale answer had been a sync page of the same sync state. Opening the ghost asks Exchange for the old ID (⚠️ expected ErrorItemNotFound, not run); (2) a flag set meanwhile is removed, and when the next check brings it back it is red: the chosen colour is lost; (3) Mark as Read is undone until a later sync reports it again.

## Repro
Run: `swift test --package-path <COPY> --scratch-path <COPY>/.build/tests --skip-build --filter Probe_Race4` (file `specs/bugs/probes/Probe_Race4Tests.swift` of the copy `copies/r4race`). Tests: `probeMoveSentWhileCheckInFlightLeavesNoGhost`, `probeFlagSentWhileCheckInFlightKeepsItsColour`, `probeReadSentWhileHistoryBatchCollectedStaysRead`.
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

    // MARK: C. A server answer fetched before a local change is applied after that change was sent

    /// Inbox not fully synced yet: every check merges its newest messages. The user flags a message purple while a
    /// check's answer (taken before the flag) is on its way; the flag is written to Exchange first. The late answer
    /// then removes the flag, and the next answer brings it back red: the colour is lost.
    // file:// fixture
    @Test func probeFlagSentWhileCheckInFlightKeepsItsColour() async throws {
        let server = RaceServer([RX.updated(["R1"])])
        defer { server.stop() }
        let s = store(server)
        s.merge([summary("R1")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        let stale = [summary("R1")]  // the newest-50 answer, taken by Exchange before the flag
        s.setFlag(.purple, for: [id])
        try await waitFor { s.outbox.isEmpty }
        try #require(s.outbox.isEmpty, "the change never reached the server: \(s.status ?? "")")
        s.merge(stale, account: acct.id, mailbox: .inbox)  // refresh() applies its late answer
        #expect(s.message(id)?.flag == .purple, "after the late answer")
        s.merge([summary("R1", flagged: true)], account: acct.id, mailbox: .inbox)  // next check
        #expect(s.message(id)?.flag == .purple, "after the next check")
    }

    /// Same for Mark as Read: the message turns unread again although Exchange has it read.
    // file:// fixture
    @Test func probeReadSentWhileHistoryBatchCollectedStaysRead() async throws {
        let server = RaceServer([RX.updated(["R1"])])
        defer { server.stop() }
        let s = store(server)
        s.merge([summary("R1")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        // A history batch (collected for up to 1.5 s before it is shown) holds a page taken before the read.
        let page = SyncResult(upserts: [summary("R1")], deletedRemoteIDs: [], token: "T1", more: true)
        s.toggleRead([id])
        try await waitFor { s.outbox.isEmpty }
        try #require(s.outbox.isEmpty, "the change never reached the server: \(s.status ?? "")")
        s.apply([page], account: acct.id, mailbox: .inbox)
        #expect(s.message(id)?.isRead == true)
    }

    /// The user archives a message; the move reaches Exchange (new ItemId) before the Inbox check's answer, taken
    /// before the move, arrives. The old ID is added back to the Inbox as a new message. Nothing ever reports it deleted
    /// (later newest-N answers only add), so the Inbox keeps a ghost that can't be opened.
    // file:// fixture
    @Test func probeMoveSentWhileCheckInFlightLeavesNoGhost() async throws {
        let server = RaceServer([RX.moved(["N1"])])
        defer { server.stop() }
        let s = store(server)
        s.merge([summary("R1"), summary("R2")], account: acct.id, mailbox: .inbox)
        let id = try #require(s.messages.first { $0.remoteID == "R1" }).id
        let stale = [summary("R1"), summary("R2")]  // newest answer taken before the move
        s.archive([id])
        try await waitFor { s.outbox.isEmpty }
        try #require(s.outbox.isEmpty, "the change never reached the server: \(s.status ?? "")")
        #expect(s.message(id)?.remoteID == "N1")
        s.merge(stale, account: acct.id, mailbox: .inbox)
        s.merge([summary("R2")], account: acct.id, mailbox: .inbox)  // the next checks: R1 is gone on the server
        #expect(s.count(.account(acct.id, .inbox)) == 1, "inbox \(s.messages.filter { $0.mailbox == .inbox }.map { $0.remoteID ?? "" })")
        #expect(s.messages.filter { $0.subject == "S R1" }.count == 1)
        // The history then completes the Inbox with a full sync that lists only R2: the ghost is still there.
        s.apply(SyncResult(upserts: [summary("R2")], deletedRemoteIDs: [], token: "T9", more: false), account: acct.id, mailbox: .inbox)
        #expect(s.isComplete(acct.id, .inbox))
        #expect(s.count(.account(acct.id, .inbox)) == 1, "after the full sync: \(s.messages.filter { $0.mailbox == .inbox }.map { $0.remoteID ?? "" })")
        // Control: only an explicit deletion of R1 (as a sync page would report if the stale answer had been a sync
        // page listing R1) removes the ghost. The newest-N path never produces one.
        s.apply(SyncResult(upserts: [], deletedRemoteIDs: ["R1"], token: "T10", more: false), account: acct.id, mailbox: .inbox)
        #expect(s.count(.account(acct.id, .inbox)) == 1 && s.count(.account(acct.id, .archive)) == 1, "control")
    }
}
```

## Expected vs actual
```
􀢄  Test probeFlagSentWhileCheckInFlightKeepsItsColour() recorded an issue at Probe_Race4Tests.swift:239:9: Expectation failed: s.message(id)?.flag == .purple
􀄵  s.message(id)?.flag == .purple → false
􀄵    s.message(id)?.flag → nil
􀄵      some → .purple
􀢄  Test probeFlagSentWhileCheckInFlightKeepsItsColour() recorded an issue at Probe_Race4Tests.swift:241:9: Expectation failed: s.message(id)?.flag == .purple
􀄵  s.message(id)?.flag == .purple → false
􀄵    s.message(id)?.flag → .red
􀄵      some → .red
􀄵      some → .purple
􀢄  Test probeFlagSentWhileCheckInFlightKeepsItsColour() failed after 0.087 seconds with 2 issues.
􀢄  Test probeReadSentWhileHistoryBatchCollectedStaysRead() recorded an issue at Probe_Race4Tests.swift:258:9: Expectation failed: s.message(id)?.isRead == true
􀄵  s.message(id)?.isRead == true → false
􀄵    s.message(id)?.isRead → false
􀄵      some → false
􀄵      some → true
􀢄  Test probeReadSentWhileHistoryBatchCollectedStaysRead() failed after 0.088 seconds with 1 issue.
􀢄  Test probeMoveSentWhileCheckInFlightLeavesNoGhost() recorded an issue at Probe_Race4Tests.swift:278:9: Expectation failed: s.count(.account(acct.id, .inbox)) == 1
􀄵  s.count(.account(acct.id, .inbox)) == 1 → false
􀄵    s.count(.account(acct.id, .inbox)) → 2
􀢄  Test probeMoveSentWhileCheckInFlightLeavesNoGhost() recorded an issue at Probe_Race4Tests.swift:279:9: Expectation failed: s.messages.filter { $0.subject == "S R1" }.count == 1
􀄵  s.messages.filter { $0.subject == "S R1" }.count == 1 → false
􀄵    s.messages.filter { $0.subject == "S R1" }.count → 2
􀢄  Test probeMoveSentWhileCheckInFlightLeavesNoGhost() recorded an issue at Probe_Race4Tests.swift:283:9: Expectation failed: s.count(.account(acct.id, .inbox)) == 1
􀄵  s.count(.account(acct.id, .inbox)) == 1 → false
􀄵    s.count(.account(acct.id, .inbox)) → 2
􀢄  Test probeMoveSentWhileCheckInFlightLeavesNoGhost() failed after 0.089 seconds with 3 issues.
```

## Why expected
README: local changes are shown at once and written to Exchange; the server's state after the write equals the local one, so no later answer should undo it. The merge already keeps local state against server data while a change is queued ("Messages with a change still waiting for the server keep their local read state, flag and mailbox", MailStore.swift:615-616) — the same protection is needed until every answer requested before the write has been applied. Not a known bug: BUG-072/073/074/075/076 all need the change still queued (or the destination listing the new ID before the rename); here the outbox entry has already been removed, and the duplicate comes from the source folder's old ID after the rename.

## Likely cause
`Sources/MailModel/MailStore.swift:629` (`let pending = Set(mine.flatMap(\.change.remoteIDs))`) and `:666` only consult the current outbox; `:670` appends any unknown remote ID as a new message (the old ID was renamed away by `renameRemote` at `:816`). Await points that let the answer go stale (the change is written by the separate flush task meanwhile): `refresh` `:1177` (`merge(try await backend.newest(...))`), `syncHistory` `:1253` (newest-200 collected in `fetched`, merged up to 1.5 s later by `show()`) and `:1266` (`defer { apply(pages, ...) }` after a batch of pages). Neither answer carries the time it was requested, so `merge` can't tell it predates a change written since. Flag colour: `:663` keeps the colour only when both old and new are flagged. At every launch with changes queued offline, `finishLoading` (`:768-774`) calls `scheduleFlush()` and `startHistory()` back to back, so the history's first newest-200 answers race the queued moves being written.
