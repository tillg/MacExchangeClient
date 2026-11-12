---
title: 'One item gone on the server makes a whole batch (read, flag, move, delete) fail: the other items changed on Exchange but are undone here, moved ones lose their new IDs'
priority: P3
area: EWS
status: open
found: 2026-11-12
---
## Summary
Batch writes (`setRead`, `setFlagged`, `move`, `delete`, up to `MailStore.batchSize` = 100 IDs) use `EWSClient.call` in strict mode. If one item was deleted or moved elsewhere in the meantime, Exchange applies the change to all the others and returns `ErrorItemNotFound` for that one; `call` throws, and the store undoes the change for all of them. Here: marking 3 as read leaves all 3 unread although Exchange marked 2; erasing 3 from Trash brings all 3 back although 2 are gone; a move throws away the new IDs of the moved items (`parseMove` was written for exactly this partial case but is never reached).

## Repro
Tests: probeMoveKeepsNewIDsWhenOneItemFails, probeReadBatchWithOneMissingItemKeepsTheOthers, probeDeleteBatchWithOneMissingItemKeepsTheOthersErased in `specs/bugs/probes/Probe_EWS2Tests.swift` (suites `Probe_EWS2Tests` / `Probe_EWS2StoreTests`).
No network: `EWSClient` is pointed at a `file://` URL holding one canned Exchange response, so the real `URLSession`, `EWSClient.call`, `EWSBackend` and `MailStore` run unchanged (no mock, no fake backend). Every call of that client gets the same response.

```swift
import Foundation
import Testing
@testable import EWS
@testable import MailModel

struct Probe_EWS2Tests {
    func doc(_ body: String) throws -> XMLDocument {
        try XMLDocument(xmlString: """
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
            xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
            xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><s:Body>\(body)</s:Body></s:Envelope>
            """)
    }
    /// A file standing in for one server response: EWSClient.call reads it through URLSession (file://).
    func responseFile(_ xml: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ews-\(UUID().uuidString).xml")
        try Data(xml.utf8).write(to: url)
        return url
    }
    func envelope(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><s:Body>\(body)</s:Body></s:Envelope>
        """
    }
    func backend(_ xml: String) throws -> EWSBackend {
        EWSBackend(client: EWSClient(url: try responseFile(xml), username: "u", password: "p"))
    }
    func ok(_ op: String, _ inner: String = "") -> String {
        "<m:\(op)ResponseMessage ResponseClass=\"Success\"><m:ResponseCode>NoError</m:ResponseCode>\(inner)</m:\(op)ResponseMessage>"
    }
    func err(_ op: String, _ code: String) -> String {
        "<m:\(op)ResponseMessage ResponseClass=\"Error\"><m:MessageText>\(code) text</m:MessageText><m:ResponseCode>\(code)</m:ResponseCode><m:DescriptiveLinkKey>0</m:DescriptiveLinkKey></m:\(op)ResponseMessage>"
    }
    func response(_ op: String, _ messages: String) -> String {
        envelope("<m:\(op)Response><m:ResponseMessages>\(messages)</m:ResponseMessages></m:\(op)Response>")
    }

    @Test func probeMoveKeepsNewIDsWhenOneItemFails() async throws {
        let moved = { (id: String) in self.ok("MoveItem", "<m:Items><t:Message><t:ItemId Id=\"\(id)\" ChangeKey=\"CK\"/></t:Message></m:Items>") }
        let xml = response("MoveItem", moved("N1") + err("MoveItem", "ErrorItemNotFound") + moved("N3"))
        let b = try backend(xml)
        var map: [String: String]?
        do { map = try await b.move(["A", "B", "C"], to: RemoteFolder(role: .archive, id: "ARCH")) } catch {
            Issue.record("move threw \(error); the new IDs of A and C (moved on the server) are lost")
        }
        #expect(map == ["A": "N1", "C": "N3"])
    }
}

/// MailStore driven by the real EWSBackend, whose server is a canned response file (no network, no mock).
@MainActor
struct Probe_EWS2StoreTests {
    let acct = Account(name: "Exchange", address: "me@work.com")
    let helper = Probe_EWS2Tests()

    func serverMessage(_ rid: String, read: Bool = false, box: MailboxKind = .inbox) -> Message {
        Message(accountID: acct.id, mailbox: box, from: Contact(name: "Ann", email: "ann@x.com"), to: [],
                subject: "S \(rid)", body: "", date: Date(timeIntervalSince1970: 1_000_000), isRead: read,
                remoteID: rid, bodyLoaded: false)
    }
    func store(_ xml: String, _ msgs: [Message]) throws -> (MailStore, URL) {
        let url = try helper.responseFile(xml)
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: url, username: "u", password: "p")))
        s.merge(msgs, account: acct.id, mailbox: .inbox)
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX"), RemoteFolder(role: .trash, id: "DEL"),
                            RemoteFolder(role: .archive, id: "ARCH")], account: acct.id)
        return (s, url)
    }
    func waitForOutbox(_ s: MailStore) async throws {
        for _ in 0..<250 where !s.outbox.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// Mark three as read; the server marks A and C and reports B as gone. A and C must stay read here.
    @Test func probeReadBatchWithOneMissingItemKeepsTheOthers() async throws {
        let xml = helper.response("UpdateItem", helper.ok("UpdateItem", "<m:Items><t:Message><t:ItemId Id=\"A\" ChangeKey=\"K\"/></t:Message></m:Items>")
            + helper.err("UpdateItem", "ErrorItemNotFound")
            + helper.ok("UpdateItem", "<m:Items><t:Message><t:ItemId Id=\"C\" ChangeKey=\"K\"/></t:Message></m:Items>"))
        let (s, _) = try store(xml, ["A", "B", "C"].map { serverMessage($0) })
        s.toggleRead(Set(s.messages.map(\.id)))
        try await waitForOutbox(s)
        let read = Dictionary(uniqueKeysWithValues: s.messages.map { ($0.remoteID!, $0.isRead) })
        #expect(read["A"] == true && read["C"] == true, "local read state: \(read), status: \(s.status ?? "")")
    }

    /// Erase three from Trash; the server reports one as already gone. The other two are erased on the server and
    /// must not come back here.
    @Test func probeDeleteBatchWithOneMissingItemKeepsTheOthersErased() async throws {
        let xml = helper.response("DeleteItem", helper.ok("DeleteItem") + helper.err("DeleteItem", "ErrorItemNotFound") + helper.ok("DeleteItem"))
        let (s, _) = try store(xml, [])
        s.merge(["A", "B", "C"].map { serverMessage($0, box: .trash) }, account: acct.id, mailbox: .trash)
        s.delete(Set(s.messages.map(\.id)))
        try await waitForOutbox(s)
        #expect(s.messages.compactMap(\.remoteID).sorted() == [], "status: \(s.status ?? "")")
    }
}
```

## Expected vs actual
```
􀢄  Test probeMoveKeepsNewIDsWhenOneItemFails() recorded an issue at Probe_EWS2Tests.swift:85:25: Issue recorded
􀄵  move threw EWSError(code: "ErrorItemNotFound", message: "ErrorItemNotFound text"); the new IDs of A and C (moved on the server) are lost
􀢄  Test probeMoveKeepsNewIDsWhenOneItemFails() recorded an issue at Probe_EWS2Tests.swift:87:9: Expectation failed: map == ["A": "N1", "C": "N3"]
􀄵  map == ["A": "N1", "C": "N3"] → false
􀄵    map → nil
􀄵    ["A": "N1", "C": "N3"] → ["C": "N3", "A": "N1"]
􀄵      some → ["C": "N3", "A": "N1"]
􀢄  Test probeMoveKeepsNewIDsWhenOneItemFails() failed after 0.012 seconds with 2 issues.
􀢄  Test probeReadBatchWithOneMissingItemKeepsTheOthers() recorded an issue at Probe_EWS2Tests.swift:268:9: Expectation failed: read["A"] == true && read["C"] == true
􀄵  local read state: ["B": false, "C": false, "A": false], status: Exchange refused a change: ErrorItemNotFound text (ErrorItemNotFound)
􀄵  read["A"] == true && read["C"] == true → false
􀄵    read["A"] == true → false
􀄵    read["C"] == true → <not evaluated>
􀢄  Test probeReadBatchWithOneMissingItemKeepsTheOthers() failed after 0.081 seconds with 1 issue.
􀢄  Test probeDeleteBatchWithOneMissingItemKeepsTheOthersErased() recorded an issue at Probe_EWS2Tests.swift:335:9: Expectation failed: s.messages.compactMap(\.remoteID).sorted() == []
􀄵  status: Exchange refused a change: ErrorItemNotFound text (ErrorItemNotFound)
􀄵  s.messages.compactMap(\.remoteID).sorted() == [] → false
􀄵    s.messages.compactMap(\.remoteID).sorted() → ["A", "B", "C"]
􀢄  Test probeDeleteBatchWithOneMissingItemKeepsTheOthersErased() failed after 0.135 seconds with 1 issue.
```

## Why expected
⚠️ EWS returns one response message per item and (recalled, not checked live) processes each independently, with a ResponseClass per item. `EWSBackend.parseMove`'s own comment ("One response message per requested item, in request order") and its zip logic expect a mix of successes and errors. README: "If the server refuses a change, it is undone" — here the server refused one item, not the change for the other 99. Not a duplicate of BUG-023: that one is about *what* `failed()` restores (the whole old message, undoing later changes); this one is that a partly successful batch reaches `failed()` at all. Fixing BUG-023 leaves this one.

## Likely cause
`EWSBackend.setRead/setFlagged/move/delete` (Sources/EWS/EWSBackend.swift:245-257) call `client.call(...)` with the default `strict: true`; `EWSClient.call` (Sources/EWS/EWSClient.swift:47-50) throws on the first `ResponseCode` that isn't `NoError`. `MailStore.drain` then calls `failed(p, …)`, which restores every message in `p.previous`. The moved items keep their old IDs locally until the next sync of both folders.
