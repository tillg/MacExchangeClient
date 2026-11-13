---
title: "A U+FFFC character in the original's text is taken for a file mark: the forwarded picture is sent inline there, Exclude Attachments deletes it from the quote"
priority: P3
area: compose
status: open
found: 2026-11-13
---
Draft id: R5D-03 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
`Draft` treats every U+FFFC in `body` as the mark of `attachments[k]`. `MailStore.draft` copies the original's text into the quote unchanged, so a U+FFFC in it (⚠️ the object replacement character; which senders/converters emit it in plain text is not verified) becomes mark 0. When a forward then adds the original's PNG, `placedPictures == [0]`: the picture is sent inline in an HTML body at the quoted spot instead of as an attachment. Exclude Attachments removes that character from the quote, and `estimatedSize`/`text` miscount too.

## Expected
domain-model/functional.md: "Files sit in the text at a U+FFFC mark" — marks are placed by the user's attaching, never by quoted text; the original's attachments of a forward are ordinary attachments added at the end. Plain correctness: quoted text must not change and files must not move by themselves.

## Repro
Probe `Probe_R5D_Compose/objectReplacementCharInQuoteIsNotAFileMark` in `Tests/MailModelTests/Probe_R5DTests.swift`:

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5D_Compose/objectReplacementCharInQuoteIsNotAFileMark
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: d.placedPictures == []
the original's picture is placed at the quoted U+FFFC: [0]
Expectation failed: d.body.contains("> Look \u{FFFC} here")
Exclude Attachments changed the quoted text: "...> Look  here"
```

## Fix idea
In `MailStore.draft`, replace U+FFFC in the quoted/forwarded text (e.g. by U+FFFD or drop it) before building the body.
