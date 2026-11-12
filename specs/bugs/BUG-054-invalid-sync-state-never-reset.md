---
title: 'A SyncState Exchange rejects (ErrorInvalidSyncStateData) is kept: every later check of that folder fails the same way'
priority: P2
area: EWS
status: open
found: 2026-11-12
---
## Summary
When Exchange answers SyncFolderItems with `ErrorInvalidSyncStateData` (sync state expired or corrupt, e.g. after a mailbox move or restore), the store keeps the old token and the folder stays "complete". Every quick check sends the same token and fails again, so the folder never gets new mail. Not run: the token is saved with the other sync positions, so ⚠️ a relaunch presumably doesn't help either.

## Repro
Tests: probeInvalidSyncStateIsReset in `specs/bugs/probes/Probe_EWS2Tests.swift` (suites `Probe_EWS2Tests` / `Probe_EWS2StoreTests`).
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

    /// A stored SyncState Exchange no longer accepts (ErrorInvalidSyncStateData) must be dropped so the folder
    /// syncs again from scratch; otherwise every check fails forever.
    @Test func probeInvalidSyncStateIsReset() async throws {
        let xml = helper.response("SyncFolderItems", helper.err("SyncFolderItems", "ErrorInvalidSyncStateData"))
        let (s, _) = try store(xml, [serverMessage("A")])
        s.apply(SyncResult(upserts: [], deletedRemoteIDs: [], token: "OLD", more: false), account: acct.id, mailbox: .inbox)
        await s.refresh(history: false)
        await s.refresh(history: false)
        #expect(s.syncToken(acct.id, .inbox) != "OLD", "status: \(s.status ?? "")")
    }
}
```

## Expected vs actual
```
􀢄  Test probeInvalidSyncStateIsReset() recorded an issue at Probe_EWS2Tests.swift:279:9: Expectation failed: s.syncToken(acct.id, .inbox) != "OLD"
􀄵  status: Exchange: ErrorInvalidSyncStateData text (ErrorInvalidSyncStateData)
􀄵  s.syncToken(acct.id, .inbox) != "OLD" → false
􀄵    s.syncToken(acct.id, .inbox) → "OLD"
􀄵      some → "OLD"
􀄵      some → "OLD"
􀢄  Test probeInvalidSyncStateIsReset() failed after 0.019 seconds with 1 issue.
```

## Why expected
Microsoft documents `ErrorInvalidSyncStateData` (and `ErrorSyncFolderNotFound`) for SyncFolderItems; the client is expected to drop the sync state and sync again from scratch (⚠️ recalled from Microsoft's SyncFolderItems guidance, not checked here; the error response shape is hand-written). README "How mail is fetched": "A fully synced folder is asked only for changes" assumes the token is usable; nothing describes a folder that silently stops updating.

## Likely cause
`MailStore.refresh` (Sources/MailModel/MailStore.swift ~1048-1054) and `syncHistory` treat every sync error alike: `status` is set, `syncTokens`/`complete` stay as they were. Nothing (neither `EWSBackend.sync`, Sources/EWS/EWSBackend.swift:54-62, nor the store) recognises `ErrorInvalidSyncStateData` to clear the token and the `complete` mark. In history the folder lands in `historyFailed` for the session and is retried with the same bad token next launch.
