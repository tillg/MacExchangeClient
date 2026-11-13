---
title: 'Do Not Send a Response / Remove from Calendar skip the move to Deleted Items before the folder list is read: the answered invite comes back to the Inbox'
priority: P3
area: Invite
status: open
found: 2026-11-13
---
## Summary
After Do Not Send a Response or Remove from Calendar, the store shows the invite in Trash. Because Exchange may leave the item in the Inbox, `perform` follows up with its own move to Deleted Items. That move is skipped without a word while the account's server folder list hasn't been read yet. Launch (`finishLoading`) and every first `refresh` write the waiting changes before they read the folder list, so this hits:
- a Remove from Calendar that waited while offline (on a network error it stays queued), sent at the next launch;
- an answer or removal written in the window before the first folder read, or queued behind other waiting changes;
- an answer or removal queued for an account without a working backend.

The invite stays in Exchange's Inbox. The next check that lists it there (the newest-N lookup of a not-yet-complete Inbox, or an Update) moves the answered invite from Trash back into the Inbox here. It keeps its answer, and nothing explains the change. A second trigger with the same code: the follow-up move is wrapped in `try?`, so any failure (e.g. `ErrorServerBusy`, BUG-061's theme) also drops it without a status or a retry.

## Repro
file:// fixture (FIFO, real EWSClient/EWSBackend/MailStore). The full file is `specs/bugs/probes/Probe_Invite4Tests.swift` (suite `Probe_Invite4FlowTests`). The control `controlDoNotSendMovesInviteWhenFoldersKnown` passes: with the folder list known, the same flow moves the invite (`rid == "M-T"`).

```swift
import Foundation
import Testing
@testable import EWS
@testable import MailModel

// MARK: - Harness (copied from specs/bugs/probes/Probe_EWSFlowTests.swift, renamed so all probes compile together)

/// file:// fixture (FIFO). A named pipe at a `file://` URL stands in for the EWS endpoint: each request the real
/// EWSClient makes reads the next hand-written response. No network, no fake class.
final class I4Server: @unchecked Sendable {
    let url: URL
    private let path: String
    private let lock = NSLock()
    private var script: [String]
    private var fallbackXML: String
    private var stopped = false
    private var _served = 0

    var served: Int { lock.withLock { _served } }

    init(_ script: [String], fallback: String? = nil) {
        path = FileManager.default.temporaryDirectory.appendingPathComponent("ews-i4-\(UUID().uuidString).xml").path
        mkfifo(path, 0o600)
        url = URL(fileURLWithPath: path)
        self.script = script
        fallbackXML = fallback ?? I4.fault("ErrorScriptExhausted", "No scripted response left")
        let t = Thread { [self] in loop() }
        t.start()
    }

    func stop() { lock.withLock { stopped = true } }

    private func loop() {
        signal(SIGPIPE, SIG_IGN)
        while true {
            if lock.withLock({ stopped }) { return }
            let fd = open(path, O_WRONLY | O_NONBLOCK)
            if fd < 0 { usleep(500); continue }
            _ = fcntl(fd, F_SETFL, 0)
            let xml = lock.withLock { script.isEmpty ? fallbackXML : script.removeFirst() }
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

/// Hand-written Exchange responses.
enum I4 {
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
        """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
        <s:Fault><faultcode xmlns:a="http://schemas.microsoft.com/exchange/services/2006/types">a:\(code)</faultcode>\
        <faultstring xml:lang="en-US">\(text)</faultstring><detail>\
        <e:ResponseCode xmlns:e="http://schemas.microsoft.com/exchange/services/2006/errors">\(code)</e:ResponseCode>\
        </detail></s:Fault></s:Body></s:Envelope>
        """
    }
    static let answered = resp("CreateItem", ok("CreateItem", "<m:Items/>"))
    static func moved(_ new: String) -> String {
        resp("MoveItem", ok("MoveItem", "<m:Items><t:MeetingRequest><t:ItemId Id=\"\(new)\" ChangeKey=\"CK\"/></t:MeetingRequest></m:Items>"))
    }
    static func folders(_ list: [(String, String)]) -> String {
        resp("GetFolder", list.map { id, name in
            ok("GetFolder", "<m:Folders><t:Folder><t:FolderId Id=\"\(id)\" ChangeKey=\"AQ\"/><t:DisplayName>\(name)</t:DisplayName>"
                + "<t:TotalCount>0</t:TotalCount></t:Folder></m:Folders>")
        }.joined())
    }
    static let standardFolders = folders([("INBOX", "Inbox"), ("DRAFTS", "Drafts"), ("SENT", "Sent Items"),
                                          ("JUNK", "Junk Email"), ("DEL", "Deleted Items"), ("OUTBOX", "Outbox")])
    static let noFolders = resp("FindFolder", ok("FindFolder", "<m:RootFolder IndexedPagingOffset=\"0\" TotalItemsInView=\"0\" "
        + "IncludesLastItemInRange=\"true\"><t:Folders/></m:RootFolder>"))
}

@MainActor
@Suite(.serialized)
struct Probe_Invite4FlowTests {
    let acct = Account(name: "Exchange", address: "me@work.com")

    func store(_ server: I4Server, folders: Bool) -> MailStore {
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: server.url, username: "u", password: "p")))  // file:// fixture
        if folders {
            s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX"), RemoteFolder(role: .drafts, id: "DRAFTS"),
                                RemoteFolder(role: .sent, id: "SENT"), RemoteFolder(role: .trash, id: "DEL")], account: acct.id)
        }
        return s
    }

    func invite(cancel: Bool = false) -> Invite {
        Invite(start: Date(timeIntervalSince1970: 1_795_428_000), end: Date(timeIntervalSince1970: 1_795_431_600),
               location: "Room 1", organizer: Contact(name: "Org", email: "org@work.com"), isCancellation: cancel)
    }

    func inviteMessage(_ rid: String, cancel: Bool = false) -> Message {
        var m = Message(accountID: acct.id, mailbox: .inbox, from: Contact(name: "Org", email: "org@work.com"),
                        to: [Contact(name: "Me", email: "me@work.com")], subject: cancel ? "Canceled: Sync" : "Sync",
                        body: "Let's meet", date: Date(timeIntervalSince1970: 1_000_000), remoteID: rid, bodyLoaded: true,
                        invite: invite(cancel: cancel))
        m.htmlChecked = true
        return m
    }

    func waitFor(_ timeout: Duration = .seconds(6), _ cond: () -> Bool) async throws {
        let end = ContinuousClock.now + timeout
        while !cond() && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Control: folder list known. Do Not Send answers (SaveOnly), then the store moves the invite to Deleted Items.
    // file:// fixture
    @Test func controlDoNotSendMovesInviteWhenFoldersKnown() async throws {
        let server = I4Server([I4.answered, I4.moved("M-T")])
        defer { server.stop() }
        let s = store(server, folders: true)
        s.merge([inviteMessage("M")], account: acct.id, mailbox: .inbox)
        s.respond(InviteReply(response: .accept, send: false), to: s.messages[0].id)
        try await waitFor { s.outbox.isEmpty }
        try await Task.sleep(for: .milliseconds(800))
        #expect(s.messages[0].remoteID == "M-T", "rid \(s.messages[0].remoteID ?? "") served \(server.served) status \(s.status ?? "")")
    }

    /// Do Not Send a Response before the store has read the folder list (the first check after launch reads it only
    /// after writing waiting changes). `.move` fetches the folder list in that case; the follow-up move of an unsent
    /// answer doesn't, so the invite stays in Exchange's Inbox while it shows in Trash here.
    // file:// fixture
    @Test func probeDoNotSendBeforeFolderListStillMovesInvite() async throws {
        let server = I4Server([I4.answered, I4.standardFolders, I4.noFolders, I4.moved("M-T")])
        defer { server.stop() }
        let s = store(server, folders: false)
        s.merge([inviteMessage("M")], account: acct.id, mailbox: .inbox)
        s.respond(InviteReply(response: .decline, send: false), to: s.messages[0].id)
        try await waitFor { s.outbox.isEmpty }
        try await Task.sleep(for: .milliseconds(1500))
        let m = s.messages[0]
        #expect(m.remoteID == "M-T",
                "local mailbox \(m.mailbox.rawValue), rid \(m.remoteID ?? "") (no move to Deleted Items), requests \(server.served), status \(s.status ?? "nil")")
    }

    /// The same for Remove from Calendar on a cancellation.
    // file:// fixture
    @Test func probeRemoveFromCalendarBeforeFolderListStillMovesCancellation() async throws {
        let server = I4Server([I4.answered, I4.standardFolders, I4.noFolders, I4.moved("C-T")])
        defer { server.stop() }
        let s = store(server, folders: false)
        s.merge([inviteMessage("C", cancel: true)], account: acct.id, mailbox: .inbox)
        s.removeFromCalendar(s.messages[0].id)
        try await waitFor { s.outbox.isEmpty }
        try await Task.sleep(for: .milliseconds(1500))
        let m = s.messages[0]
        #expect(m.remoteID == "C-T",
                "local mailbox \(m.mailbox.rawValue), rid \(m.remoteID ?? "") (no move to Deleted Items), requests \(server.served), status \(s.status ?? "nil")")
    }

    /// Realistic path: Remove from Calendar while offline (a network error keeps it queued), quit, relaunch. Launch
    /// writes the waiting changes as soon as stored mail is loaded (`finishLoading`), before any folder list is read.
    // file:// fixture
    @Test func probeOfflineRemoveFromCalendarAfterRelaunchMovesCancellation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ProbeI4-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("Mail.sqlite")
        // Session 1: the server can't be reached; the change stays queued (stands in: no backend yet).
        let s1 = MailStore(accounts: [acct], messages: [])
        s1.merge([inviteMessage("C", cancel: true)], account: acct.id, mailbox: .inbox)
        s1.removeFromCalendar(s1.messages[0].id)
        #expect(s1.outbox.count == 1)
        let db = try MailDatabase(url: dbURL)
        try db.write(s1.takeChanges().resolved())
        // Session 2: relaunch with the server back.
        let server = I4Server([I4.answered, I4.standardFolders, I4.noFolders, I4.moved("C-T")])
        defer { server.stop() }
        let db2 = try MailDatabase(url: dbURL)
        let s2 = MailStore(accounts: [], messages: [])
        s2.add(acct, backend: EWSBackend(client: EWSClient(url: server.url, username: "u", password: "p")))  // file:// fixture
        s2.restore(try db2.meta())
        s2.finishLoading(try db2.messages())
        try await waitFor { s2.outbox.isEmpty }
        try await Task.sleep(for: .milliseconds(1500))
        let m = try #require(s2.messages.first)
        #expect(m.remoteID == "C-T",
                "local mailbox \(m.mailbox.rawValue), rid \(m.remoteID ?? ""), requests \(server.served), status \(s2.status ?? "nil")")
    }

    /// What the user then sees: the next check lists the invite still in Exchange's Inbox (newest-N lookup of an
    /// Inbox not fully synced yet), and the answered invite jumps back from Trash into the Inbox.
    // file:// fixture
    @Test func probeDoNotSendBeforeFolderListInviteStaysInTrashAfterCheck() async throws {
        let listing = I4.resp("FindItem", I4.ok("FindItem", "<m:RootFolder IndexedPagingOffset=\"0\" TotalItemsInView=\"1\" "
            + "IncludesLastItemInRange=\"true\"><t:Items><t:MeetingRequest><t:ItemId Id=\"M\" ChangeKey=\"CK\"/><t:Subject>Sync</t:Subject>"
            + "<t:DateTimeReceived>2026-11-10T09:30:00Z</t:DateTimeReceived><t:HasAttachments>false</t:HasAttachments>"
            + "<t:IsRead>true</t:IsRead><t:From><t:Mailbox><t:Name>Org</t:Name></t:Mailbox></t:From></t:MeetingRequest>"
            + "</t:Items></m:RootFolder>"))
        let empty = I4.resp("FindItem", I4.ok("FindItem", "<m:RootFolder IndexedPagingOffset=\"0\" TotalItemsInView=\"0\" "
            + "IncludesLastItemInRange=\"true\"><t:Items/></m:RootFolder>"))
        let server = I4Server([I4.answered, I4.standardFolders, I4.noFolders, listing], fallback: empty)
        defer { server.stop() }
        let s = store(server, folders: false)
        s.merge([inviteMessage("M")], account: acct.id, mailbox: .inbox)
        let id = s.messages[0].id
        s.respond(InviteReply(response: .decline, send: false), to: id)
        try await waitFor { s.outbox.isEmpty }
        try await Task.sleep(for: .milliseconds(500))
        await s.refresh(history: false)
        let m = try #require(s.message(id))
        #expect(m.mailbox == .trash,
                "after the check: mailbox \(m.mailbox.rawValue), answer \(String(describing: m.invite?.response)), requests \(server.served), status \(s.status ?? "nil")")
    }

    /// The follow-up move after an unsent answer is `try?`: a throttled/busy move is dropped without a word and
    /// never retried; the invite stays in Exchange's Inbox, in Trash here.
    // file:// fixture
    @Test func probeDoNotSendMoveFailureIsNotSilentlyDropped() async throws {
        let server = I4Server([I4.answered, I4.fault("ErrorServerBusy", "The server cannot service this request right now. Try again later.")])
        defer { server.stop() }
        let s = store(server, folders: true)
        s.merge([inviteMessage("M")], account: acct.id, mailbox: .inbox)
        s.respond(InviteReply(response: .accept, send: false), to: s.messages[0].id)
        try await waitFor { s.outbox.isEmpty }
        try await Task.sleep(for: .milliseconds(800))
        let m = s.messages[0]
        #expect(m.remoteID != "M" || !s.outbox.isEmpty || s.status != nil,
                "mailbox \(m.mailbox.rawValue), rid \(m.remoteID ?? ""), outbox \(s.outbox.count), status \(s.status ?? "nil"), requests \(server.served)")
    }
}

```

## Expected vs actual
Actual (five probes fail, the control passes):
```
probeDoNotSendBeforeFolderListStillMovesInvite: Expectation failed: m.remoteID == "M-T"
  local mailbox trash, rid M (no move to Deleted Items), requests 1, status nil
probeRemoveFromCalendarBeforeFolderListStillMovesCancellation: Expectation failed: m.remoteID == "C-T"
  local mailbox trash, rid C (no move to Deleted Items), requests 1, status nil
probeOfflineRemoveFromCalendarAfterRelaunchMovesCancellation: Expectation failed: m.remoteID == "C-T"
  local mailbox trash, rid C, requests 1, status nil
probeDoNotSendBeforeFolderListInviteStaysInTrashAfterCheck: Expectation failed: m.mailbox == .trash
  after the check: mailbox inbox, answer Optional(MailModel.InviteResponse.decline), requests 4, status nil
probeDoNotSendMoveFailureIsNotSilentlyDropped: Expectation failed: m.remoteID != "M" || !s.outbox.isEmpty || s.status != nil
  mailbox trash, rid M, outbox 0, status nil, requests 2
```
Expected: the invite is moved to Deleted Items on the server, with the folder list fetched first as `.move` does, and it stays in Trash after the next check. If the move fails for a reason other than "already moved", it stays queued or the failure is reported.

## Why expected
- README: "an answered invite moves to Trash right away, as Exchange will do", and for a cancellation "the message moves to Trash".
- The store's own comment (MailStore.swift:930): "Without a sent answer Exchange may leave the invite in the Inbox; move it like the others." The `.move` case right above handles the same situation explicitly: "Changes are written before refresh reads the folder list (e.g. a drop right after launch)", and it fetches `folders()` first.
- ⚠️ That Exchange leaves the item in the Inbox after a SaveOnly answer or a RemoveItem is the code's own assumption. It wasn't checked live.

## Likely cause
`MailStore.perform` (`Sources/MailModel/MailStore.swift:928-942`): for `.reply` with `send == false` and for `.removeFromCalendar`, the follow-up move runs only `if let trash = remoteFolders[p.account]?...`, so it does nothing while `remoteFolders` is nil. `remoteFolders` isn't persisted. It is set only in `refresh` (:1166), after `scheduleFlush()`/`await flushTask` (:1162-1163), and `finishLoading` (:768-774) flushes at launch before any refresh. The move is also wrapped in `try?` (:933, :940). Queuing the follow-up as an ordinary `.move(…, to: .trash)` change would cover both triggers.
