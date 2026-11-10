import Foundation
import Testing
@testable import MailModel

@MainActor
struct MailStoreTests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")

    func msg(_ acct: Account, _ box: MailboxKind = .inbox, subject: String = "Hi", from: String = "Ann",
             read: Bool = false, minutesAgo: Double = 0, category: MailCategory = .primary,
             flag: FlagColor? = nil) -> Message {
        Message(accountID: acct.id, mailbox: box, from: Contact(name: from, email: "\(from.lowercased())@x.com"),
                to: [Contact(name: "Me", email: acct.address)], subject: subject, body: "Body of \(subject)",
                date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60), isRead: read, flag: flag,
                category: category)
    }

    func store(_ msgs: [Message]) -> MailStore { MailStore(accounts: [work, home], messages: msgs) }

    @Test func unreadCountsPerMailboxAndAllInboxes() {
        let s = store([msg(work), msg(work, read: true), msg(home), msg(work, .junk)])
        #expect(s.unreadCount(.account(work.id, .inbox)) == 1)
        #expect(s.unreadCount(.smart(.allInboxes)) == 2)
        #expect(s.unreadCount(.account(work.id, .junk)) == 1)
    }

    @Test func listIsNewestFirst() {
        let old = msg(work, subject: "old", minutesAgo: 60), new = msg(work, subject: "new", minutesAgo: 1)
        let s = store([old, new])
        s.selectedMailbox = .account(work.id, .inbox)
        #expect(s.visibleMessages.map(\.subject) == ["new", "old"])
    }

    @Test func deleteMovesToSameAccountTrashThenErasesFromTrash() {
        let m = msg(home)
        let s = store([m])
        s.delete([m.id])
        #expect(s.message(m.id)?.mailbox == .trash)
        #expect(s.message(m.id)?.accountID == home.id)
        s.delete([m.id])
        #expect(s.message(m.id) == nil)
    }

    @Test func deleteSelectsNextMessageLikeMail() {
        let a = msg(work, subject: "a", minutesAgo: 1), b = msg(work, subject: "b", minutesAgo: 2),
            c = msg(work, subject: "c", minutesAgo: 3)
        let s = store([a, b, c])
        s.selectedMailbox = .account(work.id, .inbox)
        s.selection = [b.id]
        s.deleteSelection()
        #expect(s.selection == [c.id])
    }

    @Test func archiveAndJunkToggle() {
        let m = msg(work)
        let s = store([m])
        s.archive([m.id])
        #expect(s.message(m.id)?.mailbox == .archive)
        s.toggleJunk([m.id])
        #expect(s.message(m.id)?.mailbox == .junk)
        s.toggleJunk([m.id])
        #expect(s.message(m.id)?.mailbox == .inbox)
    }

    @Test func flagsFeedFlaggedSmartMailbox() {
        let m = msg(work), n = msg(home)
        let s = store([m, n])
        s.setFlag(.orange, for: [m.id])
        s.selectedMailbox = .smart(.flagged)
        #expect(s.visibleMessages.map(\.id) == [m.id])
        s.setFlag(nil, for: [m.id])
        #expect(s.visibleMessages.isEmpty)
    }

    @Test func categoryOnlyFiltersInboxes() {
        let p = msg(work, subject: "p"), promo = msg(work, subject: "promo", category: .promotions)
        let sentPromo = msg(work, .sent, subject: "sent", category: .promotions)
        let s = store([p, promo, sentPromo])
        s.category = .promotions
        s.selectedMailbox = .account(work.id, .inbox)
        #expect(s.visibleMessages.map(\.subject) == ["promo"])
        s.selectedMailbox = .account(work.id, .sent)
        #expect(s.visibleMessages.map(\.subject) == ["sent"])
    }

    @Test func unreadFilterAndSearch() {
        let s = store([msg(work, subject: "Invoice March", from: "Bob"), msg(work, subject: "Lunch", read: true)])
        s.selectedMailbox = .account(work.id, .inbox)
        s.filterUnread = true
        #expect(s.visibleMessages.map(\.subject) == ["Invoice March"])
        s.filterUnread = false
        s.searchText = "lunch"
        #expect(s.visibleMessages.map(\.subject) == ["Lunch"])
        s.searchText = "bob"
        #expect(s.visibleMessages.map(\.subject) == ["Invoice March"])
    }

    @Test func searchSpansAllMailboxesOfScope() {
        let s = store([msg(work, .archive, subject: "Old receipt")])
        s.selectedMailbox = .account(work.id, .inbox)
        s.searchText = "receipt"
        #expect(s.visibleMessages.count == 1)
    }

    @Test func openingMarksRead() {
        let m = msg(work)
        let s = store([m])
        s.selection = [m.id]
        s.markSelectionRead()
        #expect(s.message(m.id)?.isRead == true)
        s.toggleRead([m.id])
        #expect(s.message(m.id)?.isRead == false)
    }

    @Test func sendPutsMessageInSentOfAccount() {
        let s = store([])
        s.send(Draft(accountID: home.id, to: "x@y.com, Z <z@y.com>", subject: "S", body: "B"))
        let sent = s.messages.filter { $0.mailbox == .sent }
        #expect(sent.count == 1)
        #expect(sent[0].accountID == home.id)
        #expect(sent[0].to.map(\.email) == ["x@y.com", "z@y.com"])
        #expect(sent[0].isRead)
    }

    @Test func replyDraftQuotesOriginal() {
        let m = msg(work, subject: "Plans", from: "Ann")
        let s = store([m])
        let d = s.draft(.reply, to: m.id)
        #expect(d.subject == "Re: Plans")
        #expect(d.to == "ann@x.com")
        #expect(d.body.contains("> Body of Plans"))
        #expect(s.draft(.forward, to: m.id).subject == "Fwd: Plans")
        #expect(s.draft(.reply, to: s.messages[0].id).subject == "Re: Plans")
    }

    @Test func replyToReDoesNotStackPrefix() {
        let m = msg(work, subject: "Re: Plans")
        let s = store([m])
        #expect(s.draft(.reply, to: m.id).subject == "Re: Plans")
    }

    // MARK: Drag & drop

    @Test func dropOnAccountMailboxMovesThere() {
        let m = msg(work), n = msg(work)
        let s = store([m, n])
        #expect(s.drop([m.id], on: .account(work.id, .archive)))
        #expect(s.message(m.id)?.mailbox == .archive)
        #expect(s.message(n.id)?.mailbox == .inbox)
    }

    @Test func dropOnOtherAccountMovesToThatAccount() {
        let m = msg(work)
        let s = store([m])
        #expect(s.drop([m.id], on: .account(home.id, .inbox)))
        #expect(s.message(m.id)?.accountID == home.id)
        #expect(s.message(m.id)?.mailbox == .inbox)
    }

    @Test func dropOnFlaggedFlagsAndKeepsExistingColour() {
        let m = msg(work), red = msg(work, flag: .red)
        let s = store([m, red])
        #expect(s.drop([m.id, red.id], on: .smart(.flagged)))
        #expect(s.message(m.id)?.flag == .red)
        #expect(s.message(red.id)?.flag == .red)
        #expect(s.message(m.id)?.mailbox == .inbox)
    }

    @Test func dropOnAllInboxesMovesEachToItsOwnInbox() {
        let w = msg(work, .archive), h = msg(home, .trash)
        let s = store([w, h])
        #expect(s.drop([w.id, h.id], on: .smart(.allInboxes)))
        #expect(s.message(w.id)?.mailbox == .inbox)
        #expect(s.message(w.id)?.accountID == work.id)
        #expect(s.message(h.id)?.mailbox == .inbox)
        #expect(s.message(h.id)?.accountID == home.id)
    }

    @Test func vipAndUnreadRejectDrops() {
        let m = msg(work, .archive)
        let s = store([m])
        #expect(!s.canDrop(on: .smart(.vip)))
        #expect(!s.canDrop(on: .smart(.unread)))
        #expect(!s.drop([m.id], on: .smart(.vip)))
        #expect(!s.drop([m.id], on: .smart(.unread)))
        #expect(s.message(m.id)?.mailbox == .archive)
    }

    @Test func droppingSelectionSelectsNextMessage() {
        let a = msg(work, subject: "a", minutesAgo: 1), b = msg(work, subject: "b", minutesAgo: 2),
            c = msg(work, subject: "c", minutesAgo: 3)
        let s = store([a, b, c])
        s.selectedMailbox = .account(work.id, .inbox)
        s.selection = [b.id]
        s.drop([b.id], on: .account(work.id, .archive))
        #expect(s.selection == [c.id])
    }

    @Test func droppingSelectionPartlyAlreadyThereStillSelectsNext() {
        // Viewing Flagged: x is in the Inbox, y already in Archive. Dropping both on Archive moves only x,
        // but the dragged selection must still advance.
        let x = msg(work, subject: "x", minutesAgo: 1, flag: .red),
            y = msg(work, .archive, subject: "y", minutesAgo: 2, flag: .red),
            z = msg(work, subject: "z", minutesAgo: 3, flag: .red)
        let s = store([x, y, z])
        s.selectedMailbox = .smart(.flagged)
        s.selection = [x.id, y.id]
        s.drop([x.id, y.id], on: .account(work.id, .archive))
        #expect(s.selection == [z.id])
    }

    @Test func dropOnCurrentMailboxChangesNothing() {
        let m = msg(work)
        let s = store([m])
        s.selectedMailbox = .account(work.id, .inbox)
        s.selection = [m.id]
        #expect(!s.drop([m.id], on: .account(work.id, .inbox)))
        #expect(s.selection == [m.id])
    }

    // MARK: Sync from a backend

    func remote(_ rid: String, subject: String = "Hi", read: Bool = false, minutesAgo: Double = 0) -> Message {
        // Like a server summary: no body yet.
        var m = msg(work, subject: subject, read: read, minutesAgo: minutesAgo)
        m.remoteID = rid
        m.body = ""
        m.bodyLoaded = false
        return m
    }

    @Test func applyInsertsAndStoresToken() {
        let s = store([])
        s.apply(SyncResult(upserts: [remote("A"), remote("B")], deletedRemoteIDs: [], token: "t1", more: false),
                account: work.id, mailbox: .inbox)
        #expect(s.count(.account(work.id, .inbox)) == 2)
        #expect(s.syncToken(work.id, .inbox) == "t1")
        #expect(s.syncToken(work.id, .sent) == nil)
    }

    @Test func applyUpdatePreservesLocalIDSelectionAndLoadedBody() {
        let s = store([])
        s.apply(SyncResult(upserts: [remote("A", subject: "old")], deletedRemoteIDs: [], token: "t1", more: false),
                account: work.id, mailbox: .inbox)
        let id = s.messages[0].id
        s.selection = [id]
        s.setBody(MessageBody(text: "Full text", attachments: ["a.pdf"]), for: id)
        s.apply(SyncResult(upserts: [remote("A", subject: "new", read: true)], deletedRemoteIDs: [], token: "t2", more: false),
                account: work.id, mailbox: .inbox)
        #expect(s.messages.count == 1)
        #expect(s.messages[0].id == id)
        #expect(s.messages[0].subject == "new")
        #expect(s.messages[0].isRead)
        #expect(s.messages[0].body == "Full text")
        #expect(s.messages[0].attachments == ["a.pdf"])
        #expect(s.selection == [id])
    }

    @Test func applyDeletesByRemoteIDAndDropsFromSelection() {
        let s = store([])
        s.apply(SyncResult(upserts: [remote("A"), remote("B")], deletedRemoteIDs: [], token: "t1", more: false),
                account: work.id, mailbox: .inbox)
        let a = s.messages.first { $0.remoteID == "A" }!.id
        s.selection = [a]
        s.apply(SyncResult(upserts: [], deletedRemoteIDs: ["A"], token: "t2", more: false),
                account: work.id, mailbox: .inbox)
        #expect(s.messages.map(\.remoteID) == ["B"])
        #expect(s.selection.isEmpty)
    }

    @Test func applyReadFlagChangesAndBodyRecipients() {
        let s = store([])
        s.apply(SyncResult(upserts: [remote("A")], deletedRemoteIDs: [], token: "t1", more: false),
                account: work.id, mailbox: .inbox)
        s.apply(SyncResult(upserts: [], deletedRemoteIDs: [], readChanges: ["A": true], token: "t2", more: false),
                account: work.id, mailbox: .inbox)
        #expect(s.messages[0].isRead)
        let to = [Contact(name: "Me", email: "me@work.com")]
        s.setBody(MessageBody(text: "x", attachments: [], from: Contact(name: "Ann", email: "ann@x.com"), to: to, cc: []),
                  for: s.messages[0].id)
        #expect(s.messages[0].to == to)
        #expect(s.messages[0].from.email == "ann@x.com")
    }

    @Test func removeLocalAccountsDropsSampleDataOnly() {
        let s = store([msg(work), msg(home)])
        s.apply(SyncResult(upserts: [remote("A")], deletedRemoteIDs: [], token: "t", more: false),
                account: work.id, mailbox: .inbox)
        s.selectedMailbox = .account(home.id, .inbox)
        s.removeLocalAccounts()
        #expect(s.accounts.isEmpty)
        #expect(s.messages.map(\.remoteID) == ["A"])
        #expect(s.selectedMailbox == .smart(.allInboxes))
    }

    @Test func serverMessageShowsServerPreviewUntilBodyLoaded() {
        var m = remote("A")
        m.body = ""; m.bodyLoaded = false; m.serverPreview = "From the server"
        #expect(m.preview == "From the server")
        let s = store([])
        s.apply(SyncResult(upserts: [m], deletedRemoteIDs: [], token: "t", more: false), account: work.id, mailbox: .inbox)
        s.setBody(MessageBody(text: "Real body", attachments: []), for: s.messages[0].id)
        #expect(s.messages[0].bodyLoaded)
        #expect(s.messages[0].preview == "Real body")
    }

    // MARK: Write-back

    func synced(_ rids: [String], in box: MailboxKind = .inbox) -> MailStore {
        let s = store([msg(work)])
        s.apply(SyncResult(upserts: rids.map { remote($0) }, deletedRemoteIDs: [], token: "t", more: false),
                account: work.id, mailbox: box)
        return s
    }

    func id(_ s: MailStore, _ rid: String) -> Message.ID { s.messages.first { $0.remoteID == rid }!.id }

    @Test func serverChangesApplyLocallyAndQueueForTheServer() {
        let s = synced(["A", "B"])
        let a = id(s, "A"), b = id(s, "B")
        s.toggleRead([a, b])
        s.setFlag(.orange, for: [a])
        s.archive([b])
        #expect(s.message(a)?.isRead == true)
        #expect(s.message(a)?.flag == .orange)
        #expect(s.message(b)?.mailbox == .archive)
        #expect(s.outbox.map(\.change) == [.setRead(["A", "B"], true), .setFlagged(["A"], true), .move(["B"], to: .archive)])
        #expect(s.outbox.allSatisfy { $0.account == work.id })
    }

    @Test func localMessagesDontQueueServerChanges() {
        let s = synced([])
        s.toggleRead([s.messages[0].id])
        #expect(s.messages[0].isRead)
        #expect(s.outbox.isEmpty)
    }

    @Test func flagColourChangeIsLocalOnlyAndSurvivesSync() {
        let s = synced(["A"])
        let a = id(s, "A")
        s.setFlag(.red, for: [a])
        s.setFlag(.blue, for: [a])
        #expect(s.outbox.map(\.change) == [.setFlagged(["A"], true)])
    }

    @Test func serverFlagKeepsTheLocalColourUntilTheServerUnflags() {
        // Flagged on the server, recoloured here: a colour change queues nothing.
        var flagged = remote("A"); flagged.flag = .red
        let s = store([])
        s.apply(SyncResult(upserts: [flagged], deletedRemoteIDs: [], token: "t1", more: false), account: work.id, mailbox: .inbox)
        let a = id(s, "A")
        s.setFlag(.blue, for: [a])
        #expect(s.outbox.isEmpty)
        s.apply(SyncResult(upserts: [flagged], deletedRemoteIDs: [], token: "t2", more: false), account: work.id, mailbox: .inbox)
        #expect(s.message(a)?.flag == .blue)
        s.apply(SyncResult(upserts: [remote("A")], deletedRemoteIDs: [], token: "t3", more: false), account: work.id, mailbox: .inbox)
        #expect(s.message(a)?.flag == nil)
    }

    @Test func deleteMovesToTrashThenErasesOnServer() {
        let s = synced(["A"])
        let a = id(s, "A")
        s.delete([a])
        s.delete([a])
        #expect(s.message(a) == nil)
        #expect(s.outbox.map(\.change) == [.move(["A"], to: .trash), .delete(["A"])])
    }

    @Test func junkToggleAndDropQueueMoves() {
        let s = synced(["A", "B"])
        s.toggleJunk([id(s, "A")])
        s.drop([id(s, "B")], on: .account(work.id, .sent))
        #expect(s.outbox.map(\.change) == [.move(["A"], to: .junk), .move(["B"], to: .sent)])
    }

    @Test func serverMessagesCantMoveToAnotherAccount() {
        let s = synced(["A"])
        let a = id(s, "A")
        #expect(!s.drop([a], on: .account(home.id, .inbox)))
        #expect(s.message(a)?.accountID == work.id)
        #expect(s.outbox.isEmpty)
        #expect(s.status != nil)
    }

    @Test func movedMessagesTakeTheirNewServerIDs() {
        let s = synced(["A", "B"])
        let a = id(s, "A")
        s.archive([a])
        s.setFlag(.red, for: [a])
        s.renameRemote(["A": "A2"], account: work.id)
        #expect(s.message(a)?.remoteID == "A2")
        #expect(s.outbox.map(\.change) == [.move(["A2"], to: .archive), .setFlagged(["A2"], true)])
        // The source folder's sync then reports the old ID as deleted; the moved message stays.
        s.apply(SyncResult(upserts: [], deletedRemoteIDs: ["A"], token: "t2", more: false), account: work.id, mailbox: .inbox)
        #expect(s.message(a)?.mailbox == .archive)
    }

    @Test func rejectedChangeIsUndoneLocally() {
        let s = synced(["A"])
        let a = id(s, "A")
        s.archive([a])
        s.failed(s.outbox[0], "No archive")
        #expect(s.message(a)?.mailbox == .inbox)
        #expect(s.outbox.isEmpty)
        #expect(s.status != nil)
        s.delete([a]); s.delete([a])
        s.failed(s.outbox[1], "Denied")
        #expect(s.message(a)?.mailbox == .trash)
    }

    @Test func failedSendKeepsTheTextAsALocalDraft() {
        let s = synced([])
        let d = Draft(accountID: work.id, to: "ann@x.com", subject: "S", body: "B")
        s.send(d)
        s.failed(s.outbox[0], "Timeout")
        #expect(s.outbox.isEmpty)
        let draft = s.messages.first { $0.mailbox == .drafts }
        #expect(draft?.body == "B")
        #expect(draft?.remoteID == nil)
    }

    @Test func sendFromServerAccountQueuesAndAddsNothingLocally() {
        let s = synced([])
        let d = Draft(accountID: work.id, to: "ann@x.com", subject: "S", body: "B")
        s.send(d)
        s.saveDraft(d)
        #expect(s.outbox.map(\.change) == [.send(d), .saveDraft(d)])
        #expect(s.messages.count == 1)
    }

    @Test func markAllReadQueuesInChunks() {
        let s = synced((0..<250).map { "R\($0)" })
        s.markAllRead(in: .account(work.id, .inbox))
        #expect(s.outbox.count == 3)
        #expect(s.outbox.flatMap { if case let .setRead(ids, true) = $0.change { ids } else { [] } }.count == 250)
    }

    @Test func noProgressWhenIdle() async {
        let s = synced([])
        await s.refresh()
        #expect(s.progress == nil)
    }

    // MARK: View-driven retrieval

    @Test func quickCheckCoversInboxAndTheSelectedMailbox() {
        let s = synced([])
        #expect(s.quickCheckRoles(work.id) == [.inbox])
        s.selectedMailbox = .account(work.id, .sent)
        #expect(s.quickCheckRoles(work.id) == [.inbox, .sent])
        #expect(s.quickCheckRoles(home.id) == [.inbox])
        s.selectedMailbox = .account(work.id, .inbox)
        #expect(s.quickCheckRoles(work.id) == [.inbox])
    }

    @Test func historyStartsWithWhatTheUserLooksAtAndLeavesSentForLast() {
        let s = synced([])
        let all = MailboxKind.allCases
        #expect(s.historyOrder(work.id, all) == [.inbox, .drafts, .archive, .junk, .trash, .sent])
        s.selectedMailbox = .account(work.id, .trash)
        #expect(s.historyOrder(work.id, all) == [.trash, .inbox, .drafts, .archive, .junk, .sent])
        s.selectedMailbox = .smart(.flagged)
        #expect(s.historyOrder(work.id, all).first == .inbox)
    }

    @Test func newestMergeLeavesTheSyncPositionAlone() {
        let s = synced([])
        s.merge([remote("A")], account: work.id, mailbox: .sent)
        #expect(s.count(.account(work.id, .sent)) == 1)
        #expect(s.syncToken(work.id, .sent) == nil)
        #expect(!s.isComplete(work.id, .sent))
    }

    @Test func folderIsCompleteOnceTheLastPageArrived() {
        let s = synced([])
        s.apply(SyncResult(upserts: [remote("A")], deletedRemoteIDs: [], token: "p1", more: true), account: work.id, mailbox: .sent)
        #expect(!s.isComplete(work.id, .sent))
        s.apply(SyncResult(upserts: [], deletedRemoteIDs: [], token: "p2", more: false), account: work.id, mailbox: .sent)
        #expect(s.isComplete(work.id, .sent))
    }

    @Test func pendingChangesSurviveASyncThatRacesThem() {
        let s = synced(["A", "B"])
        let a = id(s, "A"), b = id(s, "B")
        s.toggleRead([a])
        s.archive([b])
        // The server hasn't seen the changes yet and reports the old state.
        s.apply(SyncResult(upserts: [remote("A"), remote("B")], deletedRemoteIDs: [], token: "t2", more: false),
                account: work.id, mailbox: .inbox)
        #expect(s.message(a)?.isRead == true)
        #expect(s.message(b)?.mailbox == .archive)
        // The move went through and the inbox sync reports B gone before the new ID arrived.
        s.apply(SyncResult(upserts: [], deletedRemoteIDs: ["B"], token: "t3", more: false), account: work.id, mailbox: .inbox)
        #expect(s.message(b) != nil)
    }

    @Test func deletionElsewhereWinsOverAPendingReadChange() {
        let s = synced(["A"])
        let a = id(s, "A")
        s.toggleRead([a])
        s.apply(SyncResult(upserts: [], deletedRemoteIDs: ["A"], token: "t2", more: false), account: work.id, mailbox: .inbox)
        #expect(s.message(a) == nil)
    }

    @Test func historyProgressCountsMessagesAgainstServerTotals() {
        let s = synced(["A", "B"])
        let folders = [RemoteFolder(role: .inbox, id: "i", totalCount: 4), RemoteFolder(role: .sent, id: "s", totalCount: 6)]
        // The inbox is complete (counts in full: 4), Sent has 0 of 6.
        #expect(s.historyFraction(work.id, folders) == 0.4)
        #expect(s.historyFraction(work.id, []) == 0)
    }

    @Test func sidebarCountsMatchTheMailboxRules() {
        var msgs = [msg(work), msg(work, read: true), msg(work, .trash, flag: .red), msg(home, flag: .blue),
                    msg(home, .sent), msg(home, .archive, flag: .green)]
        msgs[0].isVIP = true
        let s = store(msgs)
        let refs: [MailboxRef] = SmartMailbox.allCases.map { .smart($0) }
            + [work, home].flatMap { a in MailboxKind.allCases.map { .account(a.id, $0) } }
        for r in refs {
            #expect(s.count(r) == s.messages.filter { s.contains(r, $0) }.count)
            #expect(s.unreadCount(r) == s.messages.filter { !$0.isRead && s.contains(r, $0) }.count)
        }
        s.toggleRead([s.messages[0].id])
        #expect(s.unreadCount(.smart(.vip)) == 0)
    }

    @Test func completeFoldersOffScreenGetADeltaPass() {
        let s = synced([])
        for box in [MailboxKind.sent, .drafts, .trash] {
            s.apply(SyncResult(upserts: [], deletedRemoteIDs: [], token: "t", more: box == .trash), account: work.id, mailbox: box)
        }
        s.selectedMailbox = .account(work.id, .sent)
        // Inbox and Sent are covered by the quick check; Trash is still in history.
        #expect(s.backgroundDeltaRoles(work.id, MailboxKind.allCases) == [.drafts])
    }

    @Test func failedSignInPausesTheAccountUntilRelaunch() {
        let s = synced(["A"])
        #expect(!s.pauseIfSignInFailed(MailError("Other"), account: work.id))
        #expect(!s.isPaused(work.id))
        #expect(s.pauseIfSignInFailed(AuthenticationError(), account: work.id))
        #expect(s.isPaused(work.id))
        #expect(s.status?.contains("password") == true)
        // Changes still apply locally and wait in the outbox.
        s.toggleRead([id(s, "A")])
        #expect(s.outbox.count == 1)
    }

    @Test func markAllRead() {
        let s = store([msg(work), msg(work), msg(home)])
        s.markAllRead(in: .account(work.id, .inbox))
        #expect(s.unreadCount(.smart(.allInboxes)) == 1)
    }
}
