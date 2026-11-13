---
title: "After a message changed on the server, Open and Save still give the old version of a file with the same name"
priority: P4
area: attachments / Mail Downloads
status: open
found: 2026-11-13
---

## Summary
Opened files live at "Mail Downloads/<message>/<index>/<name>" and are reused whenever that path exists (and, for Save, while unchanged since written). When the message's body is fetched again because it changed on the server (a draft edited elsewhere: new text, contract.pdf replaced by a new version), the new list has the same name at the same position, so Open, Quick Look, the in-place picture/PDF, Save, drag-out and Forward all keep using the file fetched for the old version. Nothing ties the copy to the body it was fetched for.

## Expected
Plain correctness (wrong data shown and saved). README: saving, dragging and forwarding "use the file as it came in the mail"; the mail now carries the new file.

## Repro
Probe `Probe_R5K_Attachments/openedCopyIsNotReusedAfterTheMessageChanged` in `Tests/MailModelTests/Probe_R5KTests.swift` (loopback ScriptedServer):
```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5K_Attachments/openedCopyIsNotReusedAfterTheMessageChanged
```

## Failure output
```
Expectation failed: opened.flatMap { try? Data(contentsOf: $0) } == v2
  Open gives the old version   (→ "v1", 2 bytes)
Expectation failed: saved.flatMap { try? Data(contentsOf: $0) } == v2
  Save gives the old version
```

## Fix idea
In `MailStore.setBody`, when the attachment list is replaced, remove `downloadsFolder/<id>` (and its `writtenFiles` entries) — or include a body generation in the folder path.
