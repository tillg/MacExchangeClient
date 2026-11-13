---
title: "With remote content blocked, <picture> with a web <source> and <input type=image> show WebKit's broken-image box"
priority: P4
area: rendering
status: open
found: 2026-11-13
---
Draft id: R5D-13 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
The blocked style hides only `img` whose `src` isn't `data:` (and shows `<picture>` only when a source is `data:`). A `<picture>` whose `<source srcset>` is a web address and whose fallback `<img>` is an embedded picture is shown (`visibility: visible`), but WebKit picks the web source, which the CSP blocks: an outlined box with the alt text. `<input type=image src=https://…>` (newsletter buttons) isn't covered at all.

## Expected
HTMLPage.swift comment / rendering.md: "WebKit draws a blocked image as an outlined box with its alt text. Mail shows nothing but keeps the space."

## Repro
Probe `Probe_R5D_Render/blockedPicturesAreNotBrokenBoxes` in `Tests/MailModelTests/Probe_R5DTests.swift`:

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5D_Render/blockedPicturesAreNotBrokenBoxes
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: !r.contains("p:visible:0")
broken <picture> drawn: p:visible:0:https://t.example/a.png | i:visible:-:https://t.example/b.png
Expectation failed: !r.contains("i:visible")
```

## Fix idea
In the `blocked` CSS: hide `picture:has(source:not([srcset^="data:" i])) img` and `input[type=image]:not([src^="data:" i])`.
