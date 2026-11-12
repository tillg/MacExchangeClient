---
title: 'Without a top-level Archive, any folder named "Archive" becomes the Archive mailbox, even one inside Deleted Items or deep in Inbox'
priority: P3
area: EWS
status: open
found: 2026-11-12
---
## Summary
`archiveFolder` prefers a top-level folder named Archive/Archiv but falls back to any folder with that name. With no top-level Archive, a deleted folder "Archive" (now a subfolder of Deleted Items) or "Inbox ▸ Project X ▸ Archive" gets the `.archive` role. The Archive button then moves mail into Trash (the deleted folder) or into an unrelated project folder, and that folder disappears from its place in the tree because known roles are left out of `folderTree`.

## Repro
Tests: probeArchiveInsideDeletedItemsIsNotTheArchive, probeArchiveNestedInInboxProjectIsNotTheArchive in `specs/bugs/probes/Probe_EWS2Tests.swift` (suites `Probe_EWS2Tests` / `Probe_EWS2StoreTests`).
No network: `EWSClient` is pointed at a `file://` URL holding one canned Exchange response, so the real `URLSession`, `EWSClient.call`, `EWSBackend` and `MailStore` run unchanged (no mock, no fake backend). Every call of that client gets the same response.

```swift
import Foundation
import Testing
@testable import EWS
@testable import MailModel

struct Probe_EWS2Tests {
    func doc(_ body: String) throws -> XMLDocument {
        try XMLDocument(xmlString: """
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
            xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
            xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><s:Body>\(body)</s:Body></s:Envelope>
            """)
    }
    /// A file standing in for one server response: EWSClient.call reads it through URLSession (file://).
    func responseFile(_ xml: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ews-\(UUID().uuidString).xml")
        try Data(xml.utf8).write(to: url)
        return url
    }
    func envelope(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><s:Body>\(body)</s:Body></s:Envelope>
        """
    }
    func backend(_ xml: String) throws -> EWSBackend {
        EWSBackend(client: EWSClient(url: try responseFile(xml), username: "u", password: "p"))
    }
    func ok(_ op: String, _ inner: String = "") -> String {
        "<m:\(op)ResponseMessage ResponseClass=\"Success\"><m:ResponseCode>NoError</m:ResponseCode>\(inner)</m:\(op)ResponseMessage>"
    }
    func err(_ op: String, _ code: String) -> String {
        "<m:\(op)ResponseMessage ResponseClass=\"Error\"><m:MessageText>\(code) text</m:MessageText><m:ResponseCode>\(code)</m:ResponseCode><m:DescriptiveLinkKey>0</m:DescriptiveLinkKey></m:\(op)ResponseMessage>"
    }
    func response(_ op: String, _ messages: String) -> String {
        envelope("<m:\(op)Response><m:ResponseMessages>\(messages)</m:ResponseMessages></m:\(op)Response>")
    }

    /// No top-level Archive; a deleted folder called "Archive" sits in Deleted Items. It must not become the
    /// account's Archive mailbox (Archive would then move mail into Trash).
    @Test func probeArchiveInsideDeletedItemsIsNotTheArchive() throws {
        let d = try doc("""
            <m:FindFolderResponse><m:RootFolder><t:Folders>
            <t:Folder><t:FolderId Id="INBOX"/><t:ParentFolderId Id="ROOT"/><t:DisplayName>Inbox</t:DisplayName><t:FolderClass>IPF.Note</t:FolderClass></t:Folder>
            <t:Folder><t:FolderId Id="DEL"/><t:ParentFolderId Id="ROOT"/><t:DisplayName>Deleted Items</t:DisplayName><t:FolderClass>IPF.Note</t:FolderClass></t:Folder>
            <t:Folder><t:FolderId Id="OLDARCH"/><t:ParentFolderId Id="DEL"/><t:DisplayName>Archive</t:DisplayName><t:FolderClass>IPF.Note</t:FolderClass></t:Folder>
            </t:Folders></m:RootFolder></m:FindFolderResponse>
            """)
        let a = EWSBackend.archiveFolder(d.all("Folder"))
        #expect(a == nil, "Archive role given to \(a?.id ?? "")")
    }

    @Test func probeArchiveNestedInInboxProjectIsNotTheArchive() throws {
        let d = try doc("""
            <m:FindFolderResponse><m:RootFolder><t:Folders>
            <t:Folder><t:FolderId Id="INBOX"/><t:ParentFolderId Id="ROOT"/><t:DisplayName>Inbox</t:DisplayName></t:Folder>
            <t:Folder><t:FolderId Id="P"/><t:ParentFolderId Id="INBOX"/><t:DisplayName>Project X</t:DisplayName></t:Folder>
            <t:Folder><t:FolderId Id="PA"/><t:ParentFolderId Id="P"/><t:DisplayName>Archive</t:DisplayName></t:Folder>
            </t:Folders></m:RootFolder></m:FindFolderResponse>
            """)
        let a = EWSBackend.archiveFolder(d.all("Folder"))
        #expect(a == nil, "Archive role given to \(a?.id ?? "")")
    }
}
```

## Expected vs actual
```
􀢄  Test probeArchiveInsideDeletedItemsIsNotTheArchive() recorded an issue at Probe_EWS2Tests.swift:103:9: Expectation failed: a == nil
􀄵  Archive role given to OLDARCH
􀄵  a == nil → false
􀄵    a → RemoteFolder(role: MailModel.MailboxKind(rawValue: "archive"), id: "OLDARCH", totalCount: 0, name: "", parent: nil)
􀄵      some → RemoteFolder(role: MailModel.MailboxKind(rawValue: "archive"), id: "OLDARCH", totalCount: 0, name: "", parent: nil)
􀄵        role → MailboxKind(rawValue: "archive")
􀄵          rawValue → "archive"
􀄵        id → "OLDARCH"
􀢄  Test probeArchiveInsideDeletedItemsIsNotTheArchive() failed after 0.004 seconds with 1 issue.
􀢄  Test probeArchiveNestedInInboxProjectIsNotTheArchive() recorded an issue at Probe_EWS2Tests.swift:115:9: Expectation failed: a == nil
􀄵  Archive role given to PA
􀄵  a == nil → false
􀄵    a → RemoteFolder(role: MailModel.MailboxKind(rawValue: "archive"), id: "PA", totalCount: 0, name: "", parent: nil)
􀄵      some → RemoteFolder(role: MailModel.MailboxKind(rawValue: "archive"), id: "PA", totalCount: 0, name: "", parent: nil)
􀄵        role → MailboxKind(rawValue: "archive")
􀄵          rawValue → "archive"
􀄵        id → "PA"
􀢄  Test probeArchiveNestedInInboxProjectIsNotTheArchive() failed after 0.003 seconds with 1 issue.
```

## Why expected
The function's own doc comment: "A top-level folder named Archive; Outlook creates it under the mailbox root, not in the Inbox." specs/system/ews.md: "Archive: the FindFolder result named archive or archiv (any case), a top-level one first". Outlook only uses its Archive folder at the root; a folder in Deleted Items is never the archive.

## Likely cause
Sources/EWS/EWSBackend.swift:431-438: `guard let f = topLevel ?? matches.first` — the `?? matches.first` fallback accepts nested folders, including those below Deleted Items.
