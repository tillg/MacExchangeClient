import Foundation
import Testing
@testable import MailModel

/// Folders of the user's own, nested as in Mail's sidebar: subfolders of Inbox and other folders.
@MainActor
struct FolderTreeTests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")
    let projects = MailboxKind.folder("P"), launch = MailboxKind.folder("L"), clients = MailboxKind.folder("C"),
        acme = MailboxKind.folder("A")

    var tree: [Folder] {
        [Folder(box: launch, name: "Launch", parent: projects), Folder(box: projects, name: "Projects", parent: .inbox),
         Folder(box: clients, name: "clients"), Folder(box: acme, name: "Acme", parent: .inbox)]
    }

    func msg(_ box: MailboxKind, read: Bool = false, rid: String? = nil) -> Message {
        Message(accountID: work.id, mailbox: box, from: Contact(name: "Ann", email: "ann@x.com"), to: [], subject: "S",
                body: "", date: .now, isRead: read, remoteID: rid)
    }

    func store(_ msgs: [Message] = []) -> MailStore {
        let s = MailStore(accounts: [work, home], messages: msgs)
        s.setFolders(tree, account: work.id)
        return s
    }

    @Test func childrenAreNestedAndSortedByName() {
        let s = store()
        #expect(s.children(of: .inbox, account: work.id).map(\.name) == ["Acme", "Projects"])
        #expect(s.children(of: projects, account: work.id).map(\.name) == ["Launch"])
        #expect(s.children(of: nil, account: work.id).map(\.name) == ["clients"])
        #expect(s.children(of: .inbox, account: home.id).isEmpty)
    }

    @Test func folderHasItsNameAsTitle() {
        let s = store()
        #expect(s.name(of: launch, in: work.id) == "Launch")
        #expect(s.name(of: .sent, in: work.id) == "Sent")
        s.selectedMailbox = .account(work.id, launch)
        #expect(s.title == "Launch")
    }

    @Test func subfolderMailIsCountedOnItsOwnAndNotInAllInboxes() {
        let s = store([msg(.inbox), msg(launch), msg(launch, read: true)])
        #expect(s.count(.account(work.id, launch)) == 2)
        #expect(s.unreadCount(.account(work.id, launch)) == 1)
        #expect(s.unreadCount(.account(work.id, .inbox)) == 1)
        #expect(s.unreadCount(.smart(.allInboxes)) == 1)
        s.selectedMailbox = .account(work.id, launch)
        #expect(s.visibleMessages.count == 2)
    }

    @Test func droppingOnAFolderMovesThereAndQueuesTheMoveForTheServer() {
        let m = msg(.inbox, rid: "R")
        let s = store([m])
        #expect(s.drop([m.id], on: .account(work.id, clients)))
        #expect(s.message(m.id)?.mailbox == clients)
        #expect(s.outbox.map(\.change) == [.move(["R"], to: clients)])
    }

    @Test func serverFoldersBecomeTheTree() {
        let s = MailStore(accounts: [work], messages: [])
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "I"),
                            RemoteFolder(role: projects, id: "P", name: "Projects", parent: .inbox)], account: work.id)
        #expect(s.children(of: .inbox, account: work.id) == [Folder(box: projects, name: "Projects", parent: .inbox)])
    }

    @Test func historySyncsFoldersBeforeSentAndDeltaPassCoversThem() {
        let s = store()
        let roles = MailboxKind.allCases + [launch, clients]
        #expect(s.historyOrder(work.id, roles) == [.inbox, .drafts, .archive, .junk, .trash, launch, clients, .sent])
        s.selectedMailbox = .account(work.id, clients)
        #expect(s.historyOrder(work.id, roles).first == clients)
        s.selectedMailbox = .smart(.allInboxes)
        for box in [launch, .drafts] {
            s.apply(SyncResult(upserts: [], deletedRemoteIDs: [], token: "t", more: false), account: work.id, mailbox: box)
        }
        #expect(s.backgroundDeltaRoles(work.id, roles) == [.drafts, launch])
    }

    @Test func foldersTheirSyncPositionsAndMailSurviveARestart() throws {
        let s = store()
        s.apply(SyncResult(upserts: [msg(launch, rid: "R")], deletedRemoteIDs: [], token: "tok", more: false),
                account: work.id, mailbox: launch)
        let data = try JSONEncoder().encode(s.cache())
        let fresh = MailStore(accounts: [work], messages: [])
        fresh.restore(try JSONDecoder().decode(MailCache.self, from: data))
        #expect(fresh.syncToken(work.id, launch) == "tok")
        #expect(fresh.isComplete(work.id, launch))
        #expect(fresh.count(.account(work.id, launch)) == 1)
        #expect(fresh.children(of: projects, account: work.id).map(\.name) == ["Launch"])
    }
}
