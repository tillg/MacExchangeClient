---
title: "An attachment content type with parameters (\"application/octet-stream; name=logo.png\") hides an inline logo and drops an unnamed file's extension"
priority: P4
area: ews / attachments
status: open
found: 2026-11-13
---

## Summary
`inlineAttachmentIDs`, `isPicture` and the unnamed-file fallback compare Exchange's `ContentType` as a whole string. With MIME parameters in it, `application/octet-stream; name=logo.png` isn't "generic", so a logo referenced by `cid:` isn't fetched (its place in the HTML stays empty) and the logo is listed below the message as a file instead; `UTType(mimeType: "application/pdf; name=\"scan.pdf\"")` is a dynamic type with no extension, so an unnamed PDF is listed as plain "Attachment" (no .pdf, can't be opened by type). The app's `Attachment.type` has the same issue. Whether Exchange passes parameters through is not confirmed on the live server.

## Expected
RFC 2045 §5.1: parameters follow the type/subtype after ";"; the media type is type/subtype only. The app already strips them in `HTMLPage.safeType` (d-bug-019).

## Repro
Probe `Probe_R5I_EWS/contentTypeParametersAreIgnored` in `Tests/MailModelTests/Probe_R5ITests.swift`:

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5I_EWS/contentTypeParametersAreIgnored
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: EWSBackend.inlineAttachmentIDs(item, wanted: ["logo@x"]) == ["A1"]   → []
Expectation failed: names == ["Attachment.pdf"]   names → ["logo.png", "Attachment"]
```

## Fix idea
Strip parameters (and lowercase) where `ContentType` is read in `EWSBackend` (`isGeneric`, `isPicture`, `inlineAttachmentIDs`, `listedAttachments`), e.g. with `HTMLPage.safeType`'s rule.
