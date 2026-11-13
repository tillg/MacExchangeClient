---
title: "An inline picture referenced as url(&quot;cid:…&quot;) (Outlook's style attributes) never shows"
priority: P3
area: rendering / inline images
status: open
found: 2026-11-13
---
Draft id: R5D-14 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
The `cid:` reference regex stops only at a real quote, bracket or space, so in `style="background-image:url(&quot;cid:image001.png@01DA.5678&quot;)"` it takes `image001.png@01DA.5678&quot;` and, after decoding, looks for the ID `image001.png@01DA.5678"`. The picture is never fetched or replaced, so Outlook backgrounds/signatures written that way stay empty.

## Expected
rendering.md Inline images: references in CSS `url()` are found; `hasRemoteContent` already accepts `&quot;` as a quote inside `url(` because "Outlook writes inside style attributes". The same quoting must work for `cid:`.

## Repro
Probe `Probe_R5D_RemoteContent/cidInEntityQuotedCSSURL` in `Tests/MailModelTests/Probe_R5DTests.swift`:

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5D_RemoteContent/cidInEntityQuotedCSSURL
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: ids == ["image001.png@01DA.5678"]  → ["image001.png@01DA.5678\""]
Expectation failed: page.contains("data:image/png;base64,AQ==")
```

## Fix idea
`HTMLPage.cidReference`: also end the ID before `&quot;`/`&#34;`/`&#39;`/`&apos;` (or decode references in the HTML segment first), and replace the whole entity-quoted value.
