---
title: A folder returned twice by FindFolder paging appears twice in the sidebar
priority: P4
area: EWS
status: open
found: 2026-11-12
---
## Summary
`folders()` concatenates all FindFolder pages; if pages overlap (offset paging while a folder is created/deleted between calls) the same `Folder` appears twice. `folderTree` dedups only its lookup dictionary, not its output, so it returns two `RemoteFolder`s with the same id.

## Repro
Tests: probeFolderTreeDeduplicatesRepeatedFolders in specs/bugs/probes/Probe_EWSTests.swift

```swift
import Foundation
import Testing
@testable import EWS
@testable import MailModel

struct Probe_EWSTests {
    func doc(_ body: String) throws -> XMLDocument {
        try XMLDocument(xmlString: """
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
            xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
            xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><s:Body>\(body)</s:Body></s:Envelope>
            """)
    }
    func request(_ body: String) throws -> XMLDocument { try XMLDocument(xmlString: EWSClient.envelope(body)) }

    /// Folder pages that overlap (a folder created between two FindFolder pages shifts the offsets) list a folder twice.
    @Test func probeFolderTreeDeduplicatesRepeatedFolders() throws {
        let f = "<t:Folder><t:FolderId Id=\"P\"/><t:ParentFolderId Id=\"R\"/><t:DisplayName>Projects</t:DisplayName></t:Folder>"
        let d = try doc("<m:Folders>" + f + f + "</m:Folders>")
        #expect(EWSBackend.folderTree(d.all("Folder"), known: [], skip: []).count == 1)
    }
}
```

## Expected vs actual
```
EWSBackend.folderTree(d.all("Folder"), known: [], skip: []).count → 2   (expected 1)
```

## Why expected
Folder ids are unique; the code already guards paging against loops (`nextFolderOffset` … "never the same page twice") but not against overlapping pages.

## Likely cause
Sources/EWS/EWSBackend.swift:453 dedups `byID`, but :464 maps over `all` (with duplicates).
