---
title: '"My organisation" treats the same domain as foreign when it is spelled differently (bücher.de vs xn--bcher-kva.de, or work.com.)'
priority: P4
area: Privacy / RemoteImages
status: open
found: 2026-11-13
---

## Summary
`RemoteImages.loadsAutomatically` compares the sender's and the account's domains as lowercased text. An international domain typed in Unicode in Settings (`me@bücher.de`) never matches colleagues whose address comes in its ASCII form (`xn--bcher-kva.de`), and vice versa; a fully qualified domain with its root dot (`work.com.`) doesn't match either. Their pictures stay behind Load Remote Content although the setting says to load mail from the organisation. (Blocking is the safe side, so this is only an annoyance.)

## Expected
README › HTML mail: by default remote content loads "for senders in your organisation (your account's mail domain and its subdomains)". RFC 5890/5891: the U-label and A-label are the same domain name; RFC 1034 §3.1: a trailing dot is the same absolute name.

## Repro
Probe `Probe_R5MPrivacy/sameDomainInAnotherSpellingIsTheOrganisation` in `Tests/MailModelTests/Probe_R5MTests.swift`.

```
swift build --package-path W --scratch-path W/.build/tests --target MailModelTests -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5MPrivacy/sameDomainInAnotherSpellingIsTheOrganisation
```

## Failure output
```
Expectation failed: loads("kollege@xn--bcher-kva.de", own: "me@bücher.de") → false
Expectation failed: loads("kollege@bücher.de", own: "me@xn--bcher-kva.de") → false
Expectation failed: loads("kollege@work.com.", own: "me@work.com") → false
```

## Fix idea
In `RemoteImages.domain`, drop one trailing `.` and convert both domains to the same form (e.g. `URLComponents`' host IDNA encoding to A-labels) before comparing.
