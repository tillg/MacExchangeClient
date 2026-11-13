---
title: "A web video counts as remote content, but Load Remote Content never loads it (no media-src in the policy)"
priority: P4
area: rendering
status: open
found: 2026-11-13
---
Draft id: R5D-07 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
`<video src="https://…">` matches `src=` so the banner shows. The CSP used once remote content is allowed is `default-src 'none'; style-src *; img-src * data:; font-src * data:` — no `media-src`, so it falls back to `'none'` and the video (and `<audio>`) stays blocked after the user clicked Load Remote Content.

## Expected
rendering.md: "When it is allowed, the less strict CSP is used" — the banner promises loading what it detected. ⚠️ Mail plays HTML5 video in mail once remote content is loaded (recalled).

## Repro
Probe `Probe_R5D_Render/videoLoadsOnceRemoteContentIsAllowed` in `Tests/MailModelTests/Probe_R5DTests.swift`:

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5D_Render/videoLoadsOnceRemoteContentIsAllowed
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: !r.detected || r.loaded  (r → (loaded: false, detected: true))
counted as remote content (banner), but still blocked after Load Remote Content
```

## Fix idea
Add `media-src * data:` to the allowRemote CSP in `HTMLPage.document` (or stop counting video/audio `src` in `hasRemoteContent`).
