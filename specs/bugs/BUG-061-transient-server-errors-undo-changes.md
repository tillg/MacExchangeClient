---
title: 'Throttling (ErrorServerBusy) or a 503 page undoes the user''s change as "Exchange refused a change" instead of keeping it queued'
priority: P3
area: MailStore
status: open
found: 2026-11-12
---
## Summary
When Exchange throttles (`ErrorServerBusy` SOAP fault with `BackOffMilliseconds`) or a load balancer answers with its 503 "Service Unavailable" page, the queued read/flag/move/delete is dropped and undone locally, with the status "Exchange refused a change: …". Only `URLError` keeps changes queued ("Offline – changes will be sent to Exchange later"). The change the user made is lost although the server never refused it.

## Repro
Tests: probeServerBusyDoesNotUndoChange, probeServiceUnavailablePageDoesNotUndoChange in `specs/bugs/probes/Probe_EWS2Tests.swift` (suites `Probe_EWS2Tests` / `Probe_EWS2StoreTests`).
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

    /// Exchange throttling (ErrorServerBusy, with BackOffMilliseconds) is transient. The user's change must not be
    /// undone as if Exchange had refused it.
    @Test func probeServerBusyDoesNotUndoChange() async throws {
        let fault = """
            <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
            <s:Fault><faultcode xmlns:a="http://schemas.microsoft.com/exchange/services/2006/types">a:ErrorServerBusy</faultcode>\
            <faultstring xml:lang="en-US">The server cannot service this request right now. Try again later.</faultstring>\
            <detail><e:ResponseCode xmlns:e="http://schemas.microsoft.com/exchange/services/2006/errors">ErrorServerBusy</e:ResponseCode>\
            <e:Message xmlns:e="http://schemas.microsoft.com/exchange/services/2006/errors">The server cannot service this request right now. Try again later.</e:Message>\
            <t:MessageXml xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><t:Value Name="BackOffMilliseconds">29774</t:Value></t:MessageXml>\
            </detail></s:Fault></s:Body></s:Envelope>
            """
        let (s, _) = try store(fault, [serverMessage("A")])
        s.toggleRead(Set(s.messages.map(\.id)))
        try await waitForOutbox(s)
        #expect(s.messages.first?.isRead == true, "status: \(s.status ?? "")")
    }

    /// The same for a load balancer's 503 page (HTTP.sys "Service Unavailable", not well-formed XML).
    @Test func probeServiceUnavailablePageDoesNotUndoChange() async throws {
        let page = "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01//EN\"\"http://www.w3.org/TR/html4/strict.dtd\">\r\n<HTML><HEAD><TITLE>Service Unavailable</TITLE>\r\n<META HTTP-EQUIV=\"Content-Type\" Content=\"text/html; charset=us-ascii\"></HEAD>\r\n<BODY><h2>Service Unavailable</h2>\r\n<hr><p>HTTP Error 503. The service is unavailable.</p>\r\n</BODY></HTML>\r\n"
        let (s, _) = try store(page, [serverMessage("A")])
        s.toggleRead(Set(s.messages.map(\.id)))
        try await waitForOutbox(s)
        #expect(s.messages.first?.isRead == true, "status: \(s.status ?? "")")
    }
}
```

## Expected vs actual
```
􀢄  Test probeServerBusyDoesNotUndoChange() recorded an issue at Probe_EWS2Tests.swift:297:9: Expectation failed: s.messages.first?.isRead == true
􀄵  status: Exchange refused a change: The server cannot service this request right now. Try again later. (ErrorServerBusy)
􀄵  s.messages.first?.isRead == true → false
􀄵    s.messages.first?.isRead → false
􀄵      some → false
􀄵      some → true
􀢄  Test probeServerBusyDoesNotUndoChange() failed after 0.138 seconds with 1 issue.
􀢄  Test probeServiceUnavailablePageDoesNotUndoChange() recorded an issue at Probe_EWS2Tests.swift:306:9: Expectation failed: s.messages.first?.isRead == true
􀄵  status: Exchange refused a change: Unreadable EWS response (326 bytes): Line 1: Space required after the Public Identifier
􀢄  Test probeServiceUnavailablePageDoesNotUndoChange() failed after 0.136 seconds with 1 issue.
```

## Why expected
README: "If the server refuses a change, it is undone" and "Offline, changes wait until the next refresh". ⚠️ Microsoft's EWS throttling guidance (recalled): on `ErrorServerBusy` wait `BackOffMilliseconds` and retry; a 503 is likewise temporary. specs/system/architecture.md describes the current code ("Any other error: failed"), not a requirement. The fault body is hand-written in the documented shape. Neither is a refusal of the change.

## Likely cause
`MailStore.drain` (Sources/MailModel/MailStore.swift:765-782): every error that isn't `AuthenticationError` or `URLError` goes to `failed(p, …)` (line ~725), which removes the change and restores `p.previous`. `EWSClient.call` turns the fault into a plain `EWSError(code: "ErrorServerBusy")` and the 503 page into `EWSError(code: "HTTP …")`, so they can't be told apart from real refusals.
