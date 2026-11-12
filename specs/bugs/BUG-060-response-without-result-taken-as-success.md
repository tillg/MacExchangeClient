---
title: 'A response without any EWS result (empty SOAP body, a well-formed proxy/error page) counts as success: Send reports nothing, a sync "completes" with an empty token'
priority: P3
area: EWS
status: open
found: 2026-11-12
---
## Summary
`EWSClient.call` only fails on a parse error, a SOAP Fault, HTTP 401 or a `ResponseCode` other than `NoError`. A well-formed document without any `ResponseCode` (empty `soap:Body`, an XHTML maintenance page, a JSON-ish XML error from a reverse proxy) passes, and the HTTP status (500/502/503) is never checked. `send` then returns normally and the store removes the message from the outbox although nothing was sent; `sync` returns `token ""`, `more false`, which marks the folder complete with an empty sync state.

## Repro
Tests: probeSendWithResponseWithoutResultThrows, probeSyncWithResponseWithoutResultThrows, probeSendWithEmptyAnswerIsNotLost, probeHistoryWithEmptyAnswerDoesNotCompleteFolder in `specs/bugs/probes/Probe_EWS2Tests.swift` (suites `Probe_EWS2Tests` / `Probe_EWS2StoreTests`).
No network: `EWSClient` is pointed at a `file://` URL holding one canned Exchange response, so the real `URLSession`, `EWSClient.call`, `EWSBackend` and `MailStore` run unchanged (no mock, no fake backend). Every call of that client gets the same response. Note: a non-well-formed HTML page is rejected ("Unreadable EWS response"); only well-formed documents slip through.

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

    /// A proxy / load balancer page that happens to be well-formed XML, or an empty SOAP body, carries no
    /// ResponseCode. call() returns it as success, so Send "succeeds" without anything being sent.
    @Test func probeSendWithResponseWithoutResultThrows() async throws {
        let bodies = [
            envelope(""),
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>503 Service Unavailable</title></head><body><h1>Service Unavailable</h1></body></html>",
            "<?xml version=\"1.0\"?><error><code>503</code><message>Backend not available</message></error>",
        ]
        for b in bodies {
            let draft = Draft(accountID: UUID(), to: "a@x.com", subject: "S", body: "B")
            await #expect(throws: (any Error).self, "send returned normally for: \(b.prefix(40))") {
                try await self.backend(b).send(draft)
            }
        }
    }

    @Test func probeSyncWithResponseWithoutResultThrows() async throws {
        let b = try backend(envelope(""))
        await #expect(throws: (any Error).self) {
            let r = try await b.sync(RemoteFolder(role: .inbox, id: "INBOX"), token: "OLD")
            Issue.record("sync returned token=\(r.token.debugDescription) more=\(r.more) upserts=\(r.upserts.count)")
        }
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

    /// Send against an answer without any EWS result: the message must not just vanish (it is neither sent
    /// nor kept in Drafts).
    @Test func probeSendWithEmptyAnswerIsNotLost() async throws {
        let (s, _) = try store(helper.envelope(""), [])
        s.send(Draft(accountID: acct.id, to: "bob@x.com", subject: "Quarterly report", body: "Hi"))
        try await waitForOutbox(s)
        #expect(s.messages.contains { $0.subject == "Quarterly report" } || s.status != nil,
                "outbox \(s.outbox.count), messages \(s.messages.map(\.subject)), status \(String(describing: s.status))")
    }

    /// History sync against an answer without any EWS result must not mark the folder complete.
    @Test func probeHistoryWithEmptyAnswerDoesNotCompleteFolder() async throws {
        let (s, _) = try store(helper.envelope(""), [])
        await s.syncHistory()
        let complete = s.isComplete(acct.id, .inbox), token = s.syncToken(acct.id, .inbox)
        #expect(complete == false, "complete \(complete), token \(String(describing: token))")
    }
}
```

## Expected vs actual
```
􀢄  Test probeSendWithResponseWithoutResultThrows() recorded an issue at Probe_EWS2Tests.swift:63:19: Expectation failed: an error was expected but none was thrown
􀄵  send returned normally for: <?xml version="1.0" encoding="utf-8"?><s
􀄵  (any Error).self → <not evaluated>
􀢄  Test probeSendWithResponseWithoutResultThrows() recorded an issue at Probe_EWS2Tests.swift:63:19: Expectation failed: an error was expected but none was thrown
􀄵  send returned normally for: <html xmlns="http://www.w3.org/1999/xhtm
􀄵  (any Error).self → <not evaluated>
􀢄  Test probeSendWithResponseWithoutResultThrows() recorded an issue at Probe_EWS2Tests.swift:63:19: Expectation failed: an error was expected but none was thrown
􀄵  send returned normally for: <?xml version="1.0"?><error><code>503</c
􀄵  (any Error).self → <not evaluated>
􀢄  Test probeSendWithResponseWithoutResultThrows() failed after 0.019 seconds with 3 issues.
􀢄  Test probeSyncWithResponseWithoutResultThrows() recorded an issue at Probe_EWS2Tests.swift:71:15: Issue recorded
􀄵  sync returned token="" more=false upserts=0
􀢄  Test probeSyncWithResponseWithoutResultThrows() recorded an issue at Probe_EWS2Tests.swift:71:15: Expectation failed: an error was expected but none was thrown
􀄵  (any Error).self → <not evaluated>
􀢄  Test probeSyncWithResponseWithoutResultThrows() failed after 0.012 seconds with 2 issues.
􀢄  Test probeSendWithEmptyAnswerIsNotLost() recorded an issue at Probe_EWS2Tests.swift:315:9: Expectation failed: s.messages.contains { $0.subject == "Quarterly report" } || s.status != nil
􀄵  outbox 0, messages [], status nil
􀄵  s.messages.contains { $0.subject == "Quarterly report" } || s.status != nil → false
􀄵    s.messages.contains { $0.subject == "Quarterly report" } → false
􀄵    s.status != nil → false
􀢄  Test probeSendWithEmptyAnswerIsNotLost() failed after 0.079 seconds with 1 issue.
􀢄  Test probeHistoryWithEmptyAnswerDoesNotCompleteFolder() recorded an issue at Probe_EWS2Tests.swift:324:9: Expectation failed: complete == false
􀄵  complete true, token Optional("")
􀄵  complete == false → false
􀄵    complete → true
􀢄  Test probeHistoryWithEmptyAnswerDoesNotCompleteFolder() failed after 0.014 seconds with 1 issue.
```

## Why expected
Every EWS operation response carries a `ResponseMessages` element with a `ResponseCode` per item; a response without one isn't an EWS answer. README: "A message that fails to send is never resent automatically. It is kept in Drafts on this Mac instead" — here it is neither sent nor kept. (The file:// harness gives status 0; on a real server the same pages arrive with HTTP 5xx, which `call` ignores too.)

## Likely cause
Sources/EWS/EWSClient.swift:36-51: `status` is only compared with 401; after parsing, the absence of any `ResponseCode` is not checked. `parseSync` (EWSBackend.swift:470-485) then defaults the token to `""` and `more` to false.
