---
title: 'A password pasted inside the server URL (https://me:pw@host) is kept, saved in plain text in the preferences and shown in Settings'
priority: P3
area: Accounts / ExchangeAccount, AccountsSettings
status: open
found: 2026-11-13
---

## Summary
`ewsURL` keeps a user-info part, so `https://me:Secret123@mail.example.com` is accepted as is. `AccountsSettings` saves the server field as typed in UserDefaults (`exchangeAccounts`, a readable plist), and the Accounts list shows it (`LabeledContent(a.email, value: a.server)`), so the password sits in clear text outside the Keychain and on screen.

## Expected
README: the password lives in the Keychain (service MailReplica-EWS), not in the account (`ExchangeAccount` doc: "The password lives in the Keychain, not here"). Plain privacy: a credential must not be stored in clear text.

## Repro
Probe `Probe_R5MAccounts/credentialsInTheServerFieldAreNotKept` in `Tests/MailModelTests/Probe_R5MTests.swift`.

```
swift build --package-path W --scratch-path W/.build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5MAccounts/credentialsInTheServerFieldAreNotKept
```

## Failure output
```
Expectation failed: u == nil || (u?.user == nil && u?.password == nil)
https://me:Secret123@mail.example.com/EWS/Exchange.asmx
```

## Fix idea
In `ewsURL`, return nil when the URL has a user or password ("Invalid server"), and/or strip it before saving in `AccountsSettings.signIn`.
