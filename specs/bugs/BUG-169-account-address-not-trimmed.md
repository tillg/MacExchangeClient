---
title: 'An email pasted with a blank keeps the blank in the account''s address: your own invitations become answerable, and MailTips asks for the wrong address'
priority: P3
area: EWS
status: open
found: 2026-11-13
---
Draft id: R5B-09 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
`ExchangeAccount.account` trims the email for the account's name (BUG-124) but passes it untrimmed as the address, and Settings saves the field as typed. With "me@work.com " (a trailing blank from pasting), comparisons with the address fail. `canAnswer` offers Accept/Decline on an invitation you sent yourself. `GetMailTips` is sent for "me@work.com ", so the size limit may not load. Reply All's own-address check is affected too (same root cause).

## Expected
functional.md › invites: "`MailStore.canAnswer` is false in Sent or when the sender is the account's address". The account's name is already trimmed (BUG-124, ews.md › Account). Plain correctness: an address with blanks around it isn't the address.

## Repro
Probe file: `Tests/MailModelTests/Probe_R5BTests.swift` (suite `Probe_R5BTests`), test(s) `r5b09_addressPastedWithABlankIsStillTheAccountsAddress`.

```sh
swift build --package-path . --scratch-path .build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path . --scratch-path .build/tests --skip-build --filter 'Probe_R5BTests/r5b09_addressPastedWithABlankIsStillTheAccountsAddress'
```

## Failure output
```
Expectation failed: !s.canAnswer(id)
own invitation answerable; account address is "me@work.com "
Expectation failed: EWSBackend.mailTipsRequest(from: ex.account.address).contains("<t:EmailAddress>me@work.com</t:EmailAddress>") → false
```

## Fix idea
In `ExchangeAccount.account`, use the trimmed `address` for `Account.address` too, and trim in `AccountsSettings` before saving.
