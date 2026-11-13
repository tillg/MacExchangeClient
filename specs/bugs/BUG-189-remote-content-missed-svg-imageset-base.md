---
title: "SVG <image href>, CSS image-set() and <base href> relative pictures are not seen as remote content: no banner, they can never be loaded"
priority: P3
area: rendering / privacy
status: open
found: 2026-11-13
---
Draft id: R5D-04 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
`Message.hasRemoteContent` only knows `src=`, `background=`, `poster=`, `srcset=`, `<link href>`, `url(` and `@import`. Pictures WebKit does load from the web in other forms are missed: SVG `<image href|xlink:href="https://…">`, CSS `image-set("https://…" 1x)` without `url()`, and relative `src` under `<base href="https://…/">`. With remote content blocked (default "My organisation" for outside senders) the CSP blocks them, but there is no banner, so the user can't choose Load Remote Content (`MessageDetailView` shows it only when `hasRemoteContent`): the pictures stay blank unless Privacy is set to Always.

## Expected
DECISIONS d-bug-018 ("a false negative hides content without telling"); rendering.md Remote content: if the message has remote content and it isn't allowed, the banner with Load Remote Content shows. The probe's control shows each form does load from the web once allowed (connection to the 127.0.0.1 listener), so each is remote content.

## Repro
Probe `Probe_R5D_Render/remotePictureFormsAreDetected (3 arguments)` in `Tests/MailModelTests/Probe_R5DTests.swift`:

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5D_Render/remotePictureFormsAreDetected
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: r.detected  (r → (loaded: true, detected: false))
<svg …><image href="BASE/svgimage.png" …/></svg>: not counted as remote content, so no banner
<div style="background-image: image-set('BASE/imageset.png' 1x)">: not counted …
<base href="BASE/"><img src="based.png">: not counted …
```

## Fix idea
`Message.hasRemoteContent`: add `(?:xlink:)?href` inside `<image`/`<feImage`, `image-set(` with a quoted web address, and any `<base href="http…">` (with any relative resource).
