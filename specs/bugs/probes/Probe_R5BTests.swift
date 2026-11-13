import Foundation
import Testing
@testable import EWS
@testable import MailModel

/// Bug hunt round 5, hunter B: EWS over the loopback ScriptedServer harness, and EWS parsing.
/// Every test here fails now and passes once its bug is fixed.
enum R5B {
    /// Exchange's throttling fault, with the back-off it asks for (as EWS writes it in `MessageXml`).
    static func throttled(ms: Int = 60_000) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
        <s:Fault><faultcode xmlns:a="http://schemas.microsoft.com/exchange/services/2006/types">a:ErrorServerBusy</faultcode>\
        <faultstring xml:lang="en-US">The server cannot service this request right now. Try again later.</faultstring><detail>\
        <e:ResponseCode xmlns:e="http://schemas.microsoft.com/exchange/services/2006/errors">ErrorServerBusy</e:ResponseCode>\
        <e:Message xmlns:e="http://schemas.microsoft.com/exchange/services/2006/errors">The server cannot service this request right now. Try again later.</e:Message>\
        <t:MessageXml xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">\
        <t:Value Name="BackOffMilliseconds">\(ms)</t:Value></t:MessageXml></detail></s:Fault></s:Body></s:Envelope>
        """
    }

    /// GetFolder for inbox, drafts, sentitems, junkemail, deleteditems, outbox.
    static func standardFolders(_ ids: [String] = ["INBOX", "DRAFTS", "SENT", "JUNK", "DEL", "OUTBOX"]) -> String {
        EWSReply.resp("GetFolder", ids.map {
            EWSReply.ok("GetFolder", "<m:Folders><t:Folder><t:FolderId Id=\"\($0)\" ChangeKey=\"CK\"/><t:TotalCount>0</t:TotalCount></t:Folder></m:Folders>")
        }.joined())
    }

    static func folder(_ tag: String = "Folder", id: String, parent: String = "ROOT", name: String, cls: String? = "IPF.Note") -> String {
        "<t:\(tag)><t:FolderId Id=\"\(id)\" ChangeKey=\"CK\"/><t:ParentFolderId Id=\"\(parent)\" ChangeKey=\"CK\"/>"
            + (cls.map { "<t:FolderClass>\($0)</t:FolderClass>" } ?? "")
            + "<t:DisplayName>\(name)</t:DisplayName><t:TotalCount>0</t:TotalCount></t:\(tag)>"
    }
}



@MainActor
@Suite(.serialized)
struct Probe_R5BTests {
    let acct = Account(name: "Exchange", address: "me@work.com")

    func store(_ server: ScriptedServer, folders: [RemoteFolder]? = nil) -> MailStore {
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: server.url, username: "u", password: "p")))
        s.setRemoteFolders(folders ?? [RemoteFolder(role: .inbox, id: "INBOX"), RemoteFolder(role: .drafts, id: "DRAFTS"),
                                       RemoteFolder(role: .sent, id: "SENT"), RemoteFolder(role: .trash, id: "DEL")],
                           account: acct.id)
        return s
    }

    func complete(_ s: MailStore, _ box: MailboxKind, token: String = "T0") {
        s.apply(SyncResult(upserts: [], deletedRemoteIDs: [], token: token, more: false), account: acct.id, mailbox: box)
    }

    func waitFor(_ timeout: Duration = .seconds(5), _ cond: () -> Bool) async throws {
        var left = timeout
        while !cond() && left > .zero {
            let start = ContinuousClock.now
            try await Task.sleep(for: .milliseconds(10))
            left -= min(start.duration(to: .now), .milliseconds(100))
        }
        #expect(cond(), "timed out")
    }

    func backend(_ server: ScriptedServer) -> EWSBackend {
        EWSBackend(client: EWSClient(url: server.url, username: "u", password: "p"))
    }

    // MARK: R5B-01

    // MARK: R5B-02

    /// A mail folder inside Contacts (Outlook allows "Mail and Post Items" folders anywhere). Its parent is in the
    /// FindFolder answer, as a ContactsFolder: per ews.md it isn't kept (an ancestor isn't IPF.Note), and it is
    /// certainly not the account's Archive.
    @Test func r5b02_mailFolderInsideContactsIsNotShownOrTakenAsArchive() async throws {
        let found = R5B.folder("ContactsFolder", id: "CONTACTS", name: "Contacts", cls: "IPF.Contact")
            + R5B.folder(id: "F1", parent: "CONTACTS", name: "Archive")
            + R5B.folder(id: "F2", parent: "CONTACTS", name: "Customers")
        let server = ScriptedServer([R5B.standardFolders(), EWSReply.findFolder(found)])
        defer { server.stop() }
        let folders = try await backend(server).folders()
        #expect(!folders.contains { $0.id == "F1" || $0.id == "F2" },
                "\(folders.filter { ["F1", "F2"].contains($0.id) }.map { "\($0.id) as \($0.role.rawValue)" })")
    }

    // MARK: R5B-03

    /// A store whose Inbox holds server messages with these IDs.
    func inboxStore(_ server: ScriptedServer, _ rids: [String]) -> MailStore {
        let s = store(server, folders: [RemoteFolder(role: .inbox, id: "INBOX"), RemoteFolder(role: .drafts, id: "DRAFTS"),
                                        RemoteFolder(role: .sent, id: "SENT"), RemoteFolder(role: .trash, id: "DEL"),
                                        RemoteFolder(role: .archive, id: "ARCH"), RemoteFolder(role: .junk, id: "JUNK")])
        let ms = rids.map { Message(accountID: acct.id, mailbox: .inbox, from: Contact(name: "Ann", email: "ann@x.com"), to: [],
                                    subject: "S \($0)", body: "", date: .now, isRead: false, remoteID: $0, bodyLoaded: false) }
        s.apply(SyncResult(upserts: ms, deletedRemoteIDs: [], token: "T0", more: false), account: acct.id, mailbox: .inbox)
        return s
    }
    func mid(_ s: MailStore, _ rid: String) -> Message.ID { s.messages.first { $0.remoteID == rid }!.id }

    // MARK: R5B-04

    // MARK: R5B-05

    /// IIS/WCF answers an internal failure of the EWS service with a SOAP fault that holds no Exchange ResponseCode
    /// (`a:InternalServiceFault`). Exchange didn't act on the change, so it isn't a refusal (d-bug-061: a body that
    /// isn't an Exchange answer keeps changes queued); the mark as read was undone as "refused".
    @Test func r5b05_wcfFaultWithoutExchangeCodeKeepsTheChangeQueued() async throws {
        let wcf = """
            <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault>\
            <faultcode xmlns:a="http://schemas.microsoft.com/net/2005/12/windowscommunicationfoundation/dispatcher">a:InternalServiceFault</faultcode>\
            <faultstring xml:lang="en-US">The server was unable to process the request due to an internal error.</faultstring>\
            </s:Fault></s:Body></s:Envelope>
            """
        let server = ScriptedServer([wcf])
        defer { server.stop() }
        let s = inboxStore(server, ["A"])
        s.toggleRead([mid(s, "A")])
        try await waitFor { server.served == 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(s.message(mid(s, "A"))?.isRead == true, "status: \(s.status ?? "")")
        #expect(s.outbox.map(\.change) == [.setRead(["A"], true)])
    }

    // MARK: R5B-06

    // MARK: R5B-07

    // MARK: R5B-08

    /// The history's first step fetches the newest 200 of every folder not synced yet. Exchange refuses one folder
    /// (here the Inbox: access denied); the next folders must still get their newest messages ("A failing folder
    /// doesn't stop the others", `syncHistory`). The first step stopped at the refused folder, without a word.
    @Test func r5b08_oneRefusedFolderDoesNotStopTheNewestOfTheOthers() async throws {
        let refused = EWSReply.resp("FindItem", EWSReply.err("FindItem", "ErrorAccessDenied", "Access is denied."))
        let drafts = EWSReply.resp("FindItem", EWSReply.ok("FindItem", "<m:RootFolder TotalItemsInView=\"1\" IncludesLastItemInRange=\"true\">"
            + "<t:Items>\(EWSReply.summary("D1", subject: "Plan"))</t:Items></m:RootFolder>"))
        let server = ScriptedServer([refused, drafts], fallback: EWSReply.fault("ErrorAccessDenied", "Access is denied."))
        defer { server.stop() }
        let s = store(server, folders: [RemoteFolder(role: .inbox, id: "INBOX"), RemoteFolder(role: .drafts, id: "DRAFTS")])
        await s.syncHistory()
        #expect(s.messages.contains { $0.remoteID == "D1" && $0.mailbox == .drafts },
                "Drafts got nothing; \(server.served) requests, status: \(s.status ?? "")")
    }

    // MARK: R5B-09

}
