import Foundation
import Testing
@testable import EWS
@testable import MailModel

/// Bug hunt round 5, hunter L: folders and moving mail. Every test here fails now and passes once its bug is fixed.
enum R5L {
    /// GetFolder for inbox, drafts, sentitems, junkemail, deleteditems, outbox.
    static func standardFolders(_ ids: [String] = ["INBOX", "DRAFTS", "SENT", "JUNK", "DEL", "OUTBOX"]) -> String {
        EWSReply.resp("GetFolder", ids.map {
            EWSReply.ok("GetFolder", "<m:Folders><t:Folder><t:FolderId Id=\"\($0)\" ChangeKey=\"CK\"/><t:TotalCount>0</t:TotalCount></t:Folder></m:Folders>")
        }.joined())
    }

    static func folder(_ tag: String = "Folder", id: String, parent: String = "ROOT", name: String, cls: String? = "IPF.Note",
                       hidden: Bool = false) -> String {
        "<t:\(tag)><t:FolderId Id=\"\(id)\" ChangeKey=\"CK\"/><t:ParentFolderId Id=\"\(parent)\" ChangeKey=\"CK\"/>"
            + (cls.map { "<t:FolderClass>\($0)</t:FolderClass>" } ?? "")
            + "<t:DisplayName>\(name)</t:DisplayName><t:TotalCount>0</t:TotalCount>"
            + (hidden ? "<t:ExtendedProperty><t:ExtendedFieldURI PropertyTag=\"0x10f4\" PropertyType=\"Boolean\"/><t:Value>true</t:Value></t:ExtendedProperty>" : "")
            + "</t:\(tag)>"
    }

    /// The standard folders as the store keeps them (FindFolder lists them too, as plain `Folder`s under the root).
    static let standardInFind = folder(id: "INBOX", name: "Posteingang") + folder(id: "DRAFTS", name: "Entwürfe")
        + folder(id: "SENT", name: "Gesendete Elemente") + folder(id: "JUNK", name: "Junk-E-Mail")
        + folder(id: "DEL", name: "Gelöschte Elemente") + folder(id: "OUTBOX", name: "Postausgang")

    static func moved(_ pairs: [(String, String?)]) -> String {
        EWSReply.resp("MoveItem", pairs.map { _, new in
            if let new { return EWSReply.ok("MoveItem", "<m:Items><t:Message><t:ItemId Id=\"\(new)\" ChangeKey=\"CK\"/></t:Message></m:Items>") }
            return EWSReply.err("MoveItem", "ErrorItemNotFound", "The specified object was not found in the store.")
        }.joined())
    }
}

@MainActor
@Suite(.serialized)
struct Probe_R5LTests {
    let acct = Account(name: "Exchange", address: "me@work.com", isServer: true)

    func backend(_ server: ScriptedServer) -> EWSBackend {
        EWSBackend(client: EWSClient(url: server.url, username: "u", password: "p"))
    }

    func msg(_ rid: String?, _ box: MailboxKind = .inbox, subject: String = "Hello", account: UUID? = nil,
             flag: FlagColor? = nil, read: Bool = false, conv: String? = nil) -> Message {
        var m = Message(accountID: account ?? acct.id, mailbox: box, from: Contact(name: "Ann", email: "ann@x.com"), to: [],
                        subject: subject, body: "", date: .now, remoteID: rid, bodyLoaded: false)
        m.flag = flag; m.isRead = read; m.conversationID = conv
        return m
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

    /// Session one, offline (no backend): the server list had folder FX; `body` changes mail, which is queued.
    /// Returns what the app saves at quit.
    func firstSession(_ msgs: [Message], folders: [RemoteFolder], _ body: (MailStore) -> Void) -> StoreChanges {
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: nil)
        s.setRemoteFolders(folders, account: acct.id)
        // Each mailbox fully synced, as after a few launches: later checks only ask for changes.
        for box in Set(msgs.map(\.mailbox)).union([.inbox]) {
            s.apply(SyncResult(upserts: msgs.filter { $0.mailbox == box }, deletedRemoteIDs: [], token: "T0", more: false),
                    account: acct.id, mailbox: box)
        }
        body(s)
        return s.storedState()
    }

    /// The next launch: stored state read back, the account connected to `server`.
    func relaunch(_ saved: StoreChanges, _ server: ScriptedServer) -> MailStore {
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: backend(server))
        s.restore(StoredMeta(folders: saved.folders ?? [:], sync: saved.sync ?? [], outbox: saved.outbox ?? []))
        s.restore(saved.upserts, boxes: [])
        s.finishLoading([])
        return s
    }

    static let withFX: [RemoteFolder] = [RemoteFolder(role: .inbox, id: "INBOX"), RemoteFolder(role: .drafts, id: "DRAFTS"),
                                         RemoteFolder(role: .sent, id: "SENT"), RemoteFolder(role: .junk, id: "JUNK"),
                                         RemoteFolder(role: .trash, id: "DEL"),
                                         RemoteFolder(role: .folder("FX"), id: "FX", name: "Projects")]

    // MARK: R5L-01

    /// Offline, a message is moved from the Inbox into "Projects". Before the next launch "Projects" is deleted on the
    /// server. The queued move can't go, and the message is still in the Inbox on the server: it must stay in the app
    /// (back in the Inbox), not vanish.
    @Test func r5l01_moveQueuedIntoFolderDeletedOnServerKeepsTheMessage() async throws {
        let a = msg("A1")
        let saved = firstSession([a], folders: Self.withFX) { s in s.move([a.id], to: .folder("FX")) }
        let server = ScriptedServer([R5L.standardFolders(), EWSReply.findFolder(R5L.standardInFind)])
        defer { server.stop() }
        let s = relaunch(saved, server)
        try await waitFor { s.outbox.isEmpty && server.served >= 2 }
        // The next check: nothing changed in the Inbox on the server.
        server.push(EWSReply.sync("", token: "T1"))
        await s.refresh(history: false)
        let kept = s.messages.first { $0.remoteID == "A1" }
        #expect(kept?.mailbox == .inbox, "message A1 after the refused move: \(kept.map { $0.mailbox.rawValue } ?? "gone from the app"); status: \(s.status ?? "-")")

        // The app's usual path: the launch check reads the folder list while the stored mail beyond the Inbox is
        // still loading; A1 (stored in "Projects") arrives afterwards.
        let server2 = ScriptedServer([R5L.standardFolders(), EWSReply.findFolder(R5L.standardInFind), EWSReply.sync("", token: "T1")],
                                     fallback: EWSReply.sync("", token: "T2"))
        defer { server2.stop() }
        let s2 = MailStore(accounts: [], messages: [])
        s2.add(acct, backend: backend(server2))
        s2.restore(StoredMeta(folders: saved.folders ?? [:], sync: saved.sync ?? [], outbox: saved.outbox ?? []))
        s2.restore([], boxes: [MailboxKey(account: acct.id, mailbox: .inbox)])
        await s2.refresh(history: false)
        s2.finishLoading(saved.upserts)
        try await waitFor { s2.outbox.isEmpty }
        let kept2 = s2.messages.first { $0.remoteID == "A1" }
        #expect(kept2?.mailbox == .inbox, "loading path: message A1 \(kept2.map { $0.mailbox.rawValue } ?? "gone from the app"); status: \(s2.status ?? "-")")
    }

    // MARK: R5L-02

    /// Offline, a flagged message is moved from "Projects" to the Inbox. Before the next launch "Projects" is deleted
    /// for good on the server (Shift-Delete in Outlook), with its mail. The folder list no longer has it, and Exchange
    /// answers the move with ErrorItemNotFound. The undo must not put the message back into a folder that no longer
    /// exists: there it is invisible in the sidebar, but still listed in Flagged and found by search, for good.
    @Test func r5l02_refusedMoveOutOfFolderDeletedOnServerLeavesNoGhost() async throws {
        let a = msg("A1", .folder("FX"), flag: .red)
        let saved = firstSession([a], folders: Self.withFX) { s in s.move([a.id], to: .inbox) }
        let server = ScriptedServer([R5L.standardFolders(), EWSReply.findFolder(R5L.standardInFind), R5L.moved([("A1", nil)])])
        defer { server.stop() }
        let s = relaunch(saved, server)
        try await waitFor { s.outbox.isEmpty && server.served >= 3 }
        let tree = Set((s.folders[acct.id] ?? []).map(\.box))
        let ghosts = s.messages.filter { !$0.mailbox.isStandard && !tree.contains($0.mailbox) }
        #expect(ghosts.isEmpty, "messages in a mailbox the account no longer has: \(ghosts.map { "\($0.remoteID ?? "-") in \($0.mailbox.rawValue)" }); Flagged count \(s.count(.smart(.flagged)))")
    }

    // MARK: R5L-03

    /// An Exchange account without a top-level Archive folder (ews.md: "the account has no Archive"). Archive on a
    /// message: it leaves the Inbox, then jumps back with "Exchange refused a change: There is no Archive folder on the
    /// server". Nothing was sent (the server got no request), so Exchange refused nothing; the app could know before
    /// moving it that the account has no Archive.
    @Test func r5l03_archiveWithoutArchiveFolderIsNotReportedAsRefusedByExchange() async throws {
        let server = ScriptedServer([])
        defer { server.stop() }
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: backend(server))
        s.setRemoteFolders(Array(Self.withFX.prefix(5)), account: acct.id)
        s.merge([msg("A1")], account: acct.id, mailbox: .inbox)
        s.selectedMailbox = .account(acct.id, .inbox)
        s.selection = [s.messages[0].id]
        s.archiveSelection()
        try await waitFor { s.outbox.isEmpty }
        #expect(s.messages[0].mailbox == .inbox)
        #expect(s.status?.contains("Exchange refused") != true, "status: \(s.status ?? "-"); requests sent: \(server.served)")
    }
}
