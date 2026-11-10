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

    @Test func markAllRead() {
        let s = store([msg(work), msg(work), msg(home)])
        s.markAllRead(in: .account(work.id, .inbox))
        #expect(s.unreadCount(.smart(.allInboxes)) == 1)
    }
}
