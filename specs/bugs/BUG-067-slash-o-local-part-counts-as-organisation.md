---
title: An outside sender whose address starts with "/o=" counts as "my organisation", so remote images load and tell the sender the mail was opened
priority: P3
area: HTMLPage
status: open
found: 2026-11-12
---
## Summary
`RemoteImages.organisation` accepts any sender address that starts with `/o=` as an internal Exchange X.500 address, without checking the domain. An internet address may legally have `/o=…` as its local part (`/`, `=` are atext characters in RFC 5322), for example `/o=work/cn=it@evil.example`. Mail from such an address loads its remote content automatically under the default setting, so tracking pixels reach the sender without the Load Remote Content banner.

## Repro
```swift
import Foundation
import Testing
@testable import MailModel

struct Probe_Model2Tests {
    let me = Account(name: "Work", address: "alex@work.com")

    @Test func externalSenderWhoseAddressStartsWithSlashOIsNotOrganisation() {
        // An internet address may legally start with "/o=" in its local part; it is not an X.500 address.
        let s = Contact(name: "IT Department", email: "/o=work/cn=it@evil.example")
        #expect(!RemoteImages.organisation.loadsAutomatically(from: s, account: me))
    }
}
```

## Expected vs actual
```
Test externalSenderWhoseAddressStartsWithSlashOIsNotOrganisation() recorded an issue at Probe_Model2Tests.swift:116:9:
Expectation failed: !RemoteImages.organisation.loadsAutomatically(from: s, account: me)
  s → Contact(name: "IT Department", email: "/o=work/cn=it@evil.example")
  me → Account(..., name: "Work", address: "alex@work.com")
```

## Why expected
README: by default remote content loads "for senders in your organisation (your account's mail domain and its subdomains)". "Other mail shows Load Remote Content first, so opening it doesn't tell the sender." The code comment describes the exception as "Exchange's internal X.500 addresses". Those have no `@domain`. An address with `@evil.example` is an SMTP address in another domain. `RemoteImages.defaultValue` is `.organisation`, so this applies out of the box.

## Likely cause
`Sources/MailModel/HTMLPage.swift:93`: `if email.hasPrefix("/o=") { return true }` runs before the domain check and doesn't require the address to have no `@`. Treating it as X.500 only when it contains no `@` would close the hole.
