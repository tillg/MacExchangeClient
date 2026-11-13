---
title: "An entity-encoded web address (src=\"&#104;ttps://…\") is not seen as remote content: no banner"
priority: P3
area: rendering / privacy
status: open
found: 2026-11-13
---
Draft id: R5D-05 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
The detection regex runs on raw HTML; the browser decodes character references in attribute values first. `<img src="&#104;ttp://…">` (or `&#x68;`, `h&#116;tp`) loads from the web once allowed, but `hasRemoteContent` is false, so a blocked mail shows no banner and its pictures can't be loaded (short of setting Privacy to Always).

## Expected
rendering.md Remote content (banner when there is remote content); HTML spec: attribute values are decoded (character references) before URL parsing. Control in the probe: the picture loads from the listener when allowed.

## Repro
Probe `Probe_R5D_Render/entityEncodedAddressIsDetected` in `Tests/MailModelTests/Probe_R5DTests.swift`:

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5D_Render/entityEncodedAddressIsDetected
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: r.detected  (r → (loaded: true, detected: false))
not counted as remote content, so no banner
```

## Fix idea
Run `HTMLPage.decodingCharacterReferences` over the HTML (or each attribute value) before the regex in `Message.hasRemoteContent`.
