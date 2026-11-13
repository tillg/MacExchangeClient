---
title: 'A mistyped server (ftp://, https:/, https//, ?x, #x, port 99999) becomes a URL to another host or path instead of "Invalid server"'
priority: P4
area: Accounts / ExchangeAccount
status: open
found: 2026-11-13
---

## Summary
`ewsURL` removes only `https://`/`http://` and glues the rest into `https://<rest>/EWS/Exchange.asmx` without checking what the URL parser made of it. `ftp://mail.example.com` and `https:/mail.example.com` or `https//mail.example.com` (a common typo) give the host `ftp` or `https`, so Sign In sends the user name and password exchange to whatever host of that name the network resolves (search domain). `mail.example.com?x` and `mail.example.com#frag` put the EWS path into the query or fragment (the request goes to `/`), and port 99999 is accepted. The user gets a connection error rather than "Invalid server".

## Expected
ews.md › Account and URL: the result is `https://<rest>/EWS/Exchange.asmx` and nil ("Invalid server") for input that isn't a server; plain correctness: the account must not talk to a host the user didn't type (RFC 3986 syntax: a port is at most 65535).

## Repro
Probe `Probe_R5MAccounts/malformedServerIsInvalidNotAnotherHost` in `Tests/MailModelTests/Probe_R5MTests.swift`.

```
swift build --package-path W --scratch-path W/.build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5MAccounts/malformedServerIsInvalidNotAnotherHost
```

## Failure output
```
ftp://mail.example.com -> https://ftp://mail.example.com/EWS/Exchange.asmx (host ftp, path //mail.example.com/EWS/Exchange.asmx)
https:/mail.example.com -> https://https:/mail.example.com/EWS/Exchange.asmx (host https, path /mail.example.com/EWS/Exchange.asmx)
https//mail.example.com -> https://https//mail.example.com/EWS/Exchange.asmx (host https, path //mail.example.com/EWS/Exchange.asmx)
mail.example.com?x -> https://mail.example.com?x/EWS/Exchange.asmx (host mail.example.com, path )
mail.example.com#frag -> https://mail.example.com#frag/EWS/Exchange.asmx (host mail.example.com, path )
mail.example.com:99999 -> https://mail.example.com:99999/EWS/Exchange.asmx (host mail.example.com, path /EWS/Exchange.asmx)
```

## Fix idea
Parse with `URLComponents` and return nil for any other scheme, a `:` or `/` in the host, a query or fragment, or a port outside 1–65535.
