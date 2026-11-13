---
title: 'An IPv6 address typed without brackets (2001:db8::1) is "Invalid server"'
priority: P4
area: Accounts / ExchangeAccount
status: open
found: 2026-11-13
---

## Summary
`ewsURL` builds `https://2001:db8::1/EWS/Exchange.asmx`, which doesn't parse, so Sign In says "Invalid server". Bracketed (`[2001:db8::1]`) works. A host name or address field is commonly filled with a bare IPv6 address.

## Expected
README: the server can be a host name or a URL; for an address field, an IPv6 literal written as an address (RFC 4291 §2.2) names the server, and in a URL it is put in brackets (RFC 3986 §3.2.2). Plain correctness.

## Repro
Probe `Probe_R5MAccounts/bareIPv6AddressIsAServer` in `Tests/MailModelTests/Probe_R5MTests.swift`.

```
swift build --package-path W --scratch-path W/.build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5MAccounts/bareIPv6AddressIsAServer
```

## Failure output
```
Expectation failed: url("2001:db8::1")?.absoluteString == "https://[2001:db8::1]/EWS/Exchange.asmx"
url("2001:db8::1")?.absoluteString → nil
Expectation failed: url("fd00::25")?.absoluteString == "https://[fd00::25]/EWS/Exchange.asmx"
url("fd00::25")?.absoluteString → nil
```

## Fix idea
In `ewsURL`, when the rest (before any `/`) has two or more `:` and no brackets, wrap it in `[ ]`.
