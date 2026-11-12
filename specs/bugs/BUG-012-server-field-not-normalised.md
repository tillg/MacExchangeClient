---
title: 'Server field: `http://…`, `host/EWS/Exchange.asmx`, `host/`, trailing newline or blanks give a wrong EWS URL'
priority: P3
area: EWS
status: open
found: 2026-11-12
---
## Summary
`ewsURL` trims only spaces/tabs and treats anything not starting with `https://` as a bare host wrapped in `https://…/EWS/Exchange.asmx`. Results: `http://mail.example.com/EWS/Exchange.asmx` → host `http`; `mail.example.com/EWS/Exchange.asmx` → path doubled; `mail.example.com/` → `//EWS`; `mail.example.com\n` → nil ("Invalid server"); full URL + `\n` → path ends `%0A`; `"   "` → `https:///EWS/Exchange.asmx` (non-nil, so the "Invalid server" guard in AccountsSettings doesn't fire; the Sign In button only checks `server.isEmpty`).

## Repro
Tests: probeServerWithHTTPScheme, probeServerHostWithPathButNoScheme, probeServerWithTrailingSlash, probeServerWithTrailingNewline, probeServerFullURLWithTrailingNewline, probeServerWhitespaceOnly in specs/bugs/probes/Probe_EWSTests.swift

```swift
import Foundation
import Testing
@testable import EWS
@testable import MailModel

struct Probe_EWSTests {
    func doc(_ body: String) throws -> XMLDocument {
        try XMLDocument(xmlString: """
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
            xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
            xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><s:Body>\(body)</s:Body></s:Envelope>
            """)
    }
    func request(_ body: String) throws -> XMLDocument { try XMLDocument(xmlString: EWSClient.envelope(body)) }

    @Test func probeServerWithHTTPScheme() {
        let url = ExchangeAccount(email: "", username: "", server: "http://mail.example.com/EWS/Exchange.asmx").ewsURL
        #expect(url?.host == "mail.example.com")
        #expect(url?.path == "/EWS/Exchange.asmx")
    }

    @Test func probeServerHostWithPathButNoScheme() {
        let url = ExchangeAccount(email: "", username: "", server: "mail.example.com/EWS/Exchange.asmx").ewsURL
        #expect(url?.absoluteString == "https://mail.example.com/EWS/Exchange.asmx")
    }

    @Test func probeServerWithTrailingSlash() {
        let url = ExchangeAccount(email: "", username: "", server: "mail.example.com/").ewsURL
        #expect(url?.absoluteString == "https://mail.example.com/EWS/Exchange.asmx")
    }

    @Test func probeServerWithTrailingNewline() {
        let url = ExchangeAccount(email: "", username: "", server: "mail.example.com\n").ewsURL
        #expect(url?.absoluteString == "https://mail.example.com/EWS/Exchange.asmx")
    }

    @Test func probeServerFullURLWithTrailingNewline() {
        let url = ExchangeAccount(email: "", username: "", server: "https://mail.example.com/EWS/Exchange.asmx\n").ewsURL
        #expect(url?.absoluteString == "https://mail.example.com/EWS/Exchange.asmx")
    }

    @Test func probeServerWhitespaceOnly() {
        #expect(ExchangeAccount(email: "", username: "", server: "   ").ewsURL == nil)
    }
}
```

## Expected vs actual
```
probeServerWithHTTPScheme: url?.host → "http"; url?.path → "//mail.example.com/EWS/Exchange.asmx/EWS/Exchange.asmx"
probeServerHostWithPathButNoScheme: url?.absoluteString → "https://mail.example.com/EWS/Exchange.asmx/EWS/Exchange.asmx"
probeServerWithTrailingSlash: url?.absoluteString → "https://mail.example.com//EWS/Exchange.asmx"
probeServerWithTrailingNewline: url?.absoluteString → nil
probeServerFullURLWithTrailingNewline: url?.absoluteString → "https://mail.example.com/EWS/Exchange.asmx%0A"
probeServerWhitespaceOnly: ewsURL → https:///EWS/Exchange.asmx   (expected nil)
```

## Why expected
README: "The server can be a host name (`mail.example.com`, expanded to `https://mail.example.com/EWS/Exchange.asmx`) or a full EWS URL." The code already intends to ignore surrounding whitespace. (Not sent anywhere; only the built URL was checked.)

## Likely cause
Sources/EWS/ExchangeAccount.swift:18-22: `.whitespaces` instead of `.whitespacesAndNewlines`; only `hasPrefix("https://")` recognised as a URL; no check for other schemes, an existing path, a trailing slash or an empty host.
