---
title: "Attachment file names keep bidi overrides and line breaks (\"invoice\u{202E}fdp.app\" is shown reversed, as a .pdf)"
priority: P3
area: attachments / security
status: open
found: 2026-11-13
---
Draft id: R5D-09 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
`Attachment.fileName` only maps `/` and drops NUL. A sender's name with U+202E RIGHT-TO-LEFT OVERRIDE (`invoice\u{202E}fdp.app`) is written to Mail Downloads and to the folder chosen in Save as is; the Finder and Open dialogs then show it reversed ("invoiceppa.pdf"), disguising an app as a PDF. Line breaks and other control characters are kept too.

## Expected
Unicode TR36 (Security Considerations) §2.1 / CVE-class "RLO extension spoofing"; file names written by the app must not let the sender disguise the type. Gatekeeper's quarantine still asks before an app runs, hence P3.

## Repro
Probe `Probe_R5D_Attachments/fileNameDropsBidiAndControlCharacters` in `Tests/MailModelTests/Probe_R5DTests.swift`:

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5D_Attachments/fileNameDropsBidiAndControlCharacters
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: !spoof.unicodeScalars.contains { (0x202A...0x202E)… || (0x2066...0x2069)… }
"invoice\u{202E}fdp.app"
(and "a\nb.pdf" keeps its line break)
```

## Fix idea
In `Attachment.fileName`, drop Cc/Cf bidi controls (U+202A–202E, U+2066–2069, U+200E/F) and replace other control characters with a space; consider the same for the displayed name.
