---
title: 'A server pasted as the EWS folder (https://host/EWS/ or host/ews) becomes https://host/EWS/EWS/Exchange.asmx'
priority: P3
area: Accounts / ExchangeAccount
status: open
found: 2026-11-13
---

## Summary
`ewsURL` drops only a trailing `/EWS/Exchange.asmx`. The EWS virtual directory without its file (`https://mail.example.com/EWS/`, `…/EWS`, `mail.example.com/ews/`) is taken as a proxy path prefix, and the standard path is added after it: `https://mail.example.com/EWS/EWS/Exchange.asmx`, which doesn't exist. Sign In fails with a server error instead of connecting.

## Expected
README "Connecting to Exchange": the server can be a host name or a full EWS URL, pasted "in all these forms" (d-bug-012). The EWS endpoint is `/EWS/Exchange.asmx` (Microsoft: EWS URL https://<server>/EWS/Exchange.asmx); `/EWS` is that endpoint's folder, never a prefix in front of another `/EWS`.

## Repro
Probe `Probe_R5MAccounts/ewsFolderPastedWithoutTheFileIsTheStandardURL` in `Tests/MailModelTests/Probe_R5MTests.swift`.

```
swift build --package-path W --scratch-path W/.build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5MAccounts/ewsFolderPastedWithoutTheFileIsTheStandardURL
```

## Failure output
```
Expectation failed: url(s)?.absoluteString == want
https://mail.example.com/EWS/ -> https://mail.example.com/EWS/EWS/Exchange.asmx
https://mail.example.com/EWS -> https://mail.example.com/EWS/EWS/Exchange.asmx
mail.example.com/ews/ -> https://mail.example.com/ews/EWS/Exchange.asmx
```

## Fix idea
In `ExchangeAccount.ewsURL`, after dropping `/EWS/Exchange.asmx`, also drop a trailing `/EWS` (any case) before appending the standard path.
