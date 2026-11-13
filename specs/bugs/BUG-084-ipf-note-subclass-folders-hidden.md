---
title: 'Mail folders whose class is a subclass of IPF.Note (e.g. IPF.Note.OutlookHomepage) are left out of the folder tree'
priority: P4
area: EWS
status: deferred
found: 2026-11-12
---
## Summary
`folderTree` keeps a folder only if its FolderClass is exactly `IPF.Note` (or missing). Folders with an `IPF.Note.*` class hold mail too, e.g. "RSS Feeds" (`IPF.Note.OutlookHomepage`) or folders that had a home page set in Outlook; they and all their subfolders vanish from the sidebar and their mail is never synced.

## Repro
Tests: probeMailFolderSubclassShown in `specs/bugs/probes/Probe_EWS2Tests.swift` (suites `Probe_EWS2Tests` / `Probe_EWS2StoreTests`).
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

    /// Outlook treats every IPF.Note.* class as a mail folder (e.g. RSS Feeds is IPF.Note.OutlookHomepage).
    @Test func probeMailFolderSubclassShown() throws {
        let d = try doc("""
            <m:Folders><t:Folder><t:FolderId Id="RSS"/><t:ParentFolderId Id="ROOT"/><t:DisplayName>RSS Feeds</t:DisplayName>
            <t:FolderClass>IPF.Note.OutlookHomepage</t:FolderClass></t:Folder></m:Folders>
            """)
        #expect(EWSBackend.folderTree(d.all("Folder"), known: [], skip: []).map(\.id) == ["RSS"])
    }
}
```

## Expected vs actual
```
􀢄  Test probeMailFolderSubclassShown() recorded an issue at Probe_EWS2Tests.swift:124:9: Expectation failed: EWSBackend.folderTree(d.all("Folder"), known: [], skip: []).map(\.id) == ["RSS"]
􀄵  EWSBackend.folderTree(d.all("Folder"), known: [], skip: []).map(\.id) == ["RSS"] → false
􀄵    EWSBackend.folderTree(d.all("Folder"), known: [], skip: []).map(\.id) → []
􀢄  Test probeMailFolderSubclassShown() failed after 0.003 seconds with 1 issue.
```

## Why expected
⚠️ (recalled) Exchange/Outlook treat a folder class of `IPF.Note` or one beginning with `IPF.Note.` as a mail folder. README: "From Exchange you get every mail folder below the mailbox root … without calendar, contacts, tasks, Outbox and hidden folders." ⚠️ Which folders carry such classes on the user's server is not verified.

## Likely cause
Sources/EWS/EWSBackend.swift:451: `mail: !hidden && (cls == nil || cls == "IPF.Note")` — exact comparison instead of a prefix test.

## Deferred
2026-11-13: the existing test `EWSParsingTests.folderTreeKeepsMailFoldersNestedUnderTheirParents` pins the opposite: its "RSS Feeds" folder with class `IPF.Note.OutlookHomepage` must be left out of the tree. Showing `IPF.Note.*` folders would mean changing that test, which an unattended run may not do, and which classes to show is a product decision (RSS Feeds is empty for most users, and Mail.app's view of such folders is unverified). See DECISIONS.md#d-bug-084.
