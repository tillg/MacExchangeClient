---
title: 'Signing in again with the server or username written differently (capitals, :443, domain\me) adds a second copy of the account'
priority: P3
area: Accounts / AccountsSettings
status: open
found: 2026-11-13
---

## Summary
Settings ▸ Accounts ▸ Sign In is the way to re-enter a password, and it reuses a saved account only when the email (any case), the username (exactly) and `ewsURL` (exactly) match. `ewsURL` keeps the host as typed and an explicit default port, so `Mail.Example.com`, `MAIL.EXAMPLE.COM/EWS/Exchange.asmx` or `mail.example.com:443` for an account saved as `mail.example.com` give a different URL; so does `domain\me` for `DOMAIN\me` (Windows user names ignore case). The sign-in then saves a second account with a new ID: the same mailbox syncs twice, every message is listed twice in All Inboxes, and there is no way to remove an account (limitations.md).

## Expected
DECISIONS d-bug-056: "Signing in with the same email, username and server as a saved account reuses that account (its ID and mail) … instead of adding a second account" — the same server, per RFC 3986 §6.2.2.1/§6.2.3 (host is case-insensitive, the scheme's default port is the same as none). Windows account names are case-insensitive.

## Repro
Probe `Probe_R5MAccounts/sameServerWrittenDifferentlyIsTheSameAccount` in `Tests/MailModelTests/Probe_R5MTests.swift`.

```
swift build --package-path W --scratch-path W/.build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5MAccounts/sameServerWrittenDifferentlyIsTheSameAccount
```

## Failure output
```
Expectation failed: url("Mail.Example.com") == plain
host case: https://Mail.Example.com/EWS/Exchange.asmx
Expectation failed: url("mail.example.com:443") == plain
default port: https://mail.example.com:443/EWS/Exchange.asmx
Expectation failed: url("https://MAIL.EXAMPLE.COM/EWS/Exchange.asmx") == plain
pasted in capitals: https://MAIL.EXAMPLE.COM/EWS/Exchange.asmx
```

## Fix idea
Lowercase the host and drop `:443` in `ExchangeAccount.ewsURL`; in `AccountsSettings.signIn` compare usernames with `caseInsensitiveCompare` (and trimmed).
