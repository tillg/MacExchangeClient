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

    /// Messages with the same time keep one order whatever order they were loaded in (a relaunch loads Inboxes first).
    @Test func sameTimeMessagesHaveAFixedOrder() {
        let a = msg(work, .archive, subject: "a", flag: .red), b = msg(work, subject: "b", flag: .red)
        var orders: Set<[String]> = []
        for msgs in [[a, b], [b, a]] {
            let s = store(msgs)
            s.selectedMailbox = .smart(.flagged)
            orders.insert(s.visibleMessages.map(\.subject))
            s.searchText = "body"
            orders.insert(s.visibleMessages.map(\.subject))
        }
        #expect(orders.count == 1, "\(orders)")
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

    /// A selected message hidden by the unread filter is trashed but not kept selected, so a second Delete
    /// can't erase it from Trash unseen.
    @Test func deletingAHiddenSelectionTwiceDoesNotEraseIt() {
        let a = msg(work, subject: "a", read: true, minutesAgo: 1), b = msg(work, subject: "b", minutesAgo: 2)
        let s = store([a, b])
        s.selectedMailbox = .account(work.id, .inbox)
        s.selection = [a.id]
        s.filterUnread = true  // a is read: hidden now, still selected
        s.deleteSelection()
        #expect(s.message(a.id)?.mailbox == .trash)
        #expect(s.selection.isSubset(of: Set(s.visibleMessages.map(\.id))))
        s.deleteSelection()
        #expect(s.message(a.id)?.mailbox == .trash, "a second Delete erased a message never seen in Trash")
        #expect(s.message(b.id)?.mailbox == .inbox)
    }

    /// Swipe ▸ Trash or the context menu's Delete on the selected row, then ⌘⌫.
    @Test func deletingTheSelectedRowDirectlyThenDeleteKeyDoesNotEraseIt() {
        let a = msg(work, subject: "a", minutesAgo: 1), b = msg(work, subject: "b", minutesAgo: 2)
        let s = store([a, b])
        s.selectedMailbox = .account(work.id, .inbox)
        s.selection = [a.id]
        s.delete([a.id])
        #expect(s.selection == [b.id])
        s.deleteSelection()
        #expect(s.message(a.id)?.mailbox == .trash, "erased from Trash without ever being shown there")
    }

    @Test func searchHidingTheSelectionThenDeleteTwiceDoesNotEraseIt() {
        let a = msg(work, subject: "alpha", minutesAgo: 1), b = msg(work, subject: "beta", minutesAgo: 2)
        let s = store([a, b])
        s.selectedMailbox = .account(work.id, .inbox)
        s.selection = [a.id]
        s.searchText = "beta"
        s.deleteSelection()
        #expect(s.selection.isSubset(of: Set(s.visibleMessages.map(\.id))))
        s.deleteSelection()
        #expect(s.message(a.id)?.mailbox == .trash)
    }

    /// Moving the selected row from its context menu (Archive, Move to Junk) selects the next one too.
    @Test func movingTheSelectedRowDirectlyLeavesNoHiddenSelection() {
        let a = msg(work, subject: "a", minutesAgo: 1), b = msg(work, subject: "b", minutesAgo: 2),
            c = msg(work, subject: "c", minutesAgo: 3)
        let s = store([a, b, c])
        s.selectedMailbox = .account(work.id, .inbox)
        s.selection = [a.id]
        s.archive([a.id])
        #expect(s.selection == [b.id])
        s.toggleJunk([b.id])
        #expect(s.selection == [c.id])
        s.selection = [c.id]
        s.archive([b.id])  // not selected: the selection stays
        #expect(s.selection == [c.id])
    }

    /// Deleting one of several selected rows only takes that one out of the selection.
    @Test func deletingPartOfTheSelectionKeepsTheRest() {
        let a = msg(work, subject: "a", minutesAgo: 1), b = msg(work, subject: "b", minutesAgo: 2),
            c = msg(work, subject: "c", minutesAgo: 3)
        let s = store([a, b, c])
        s.selectedMailbox = .account(work.id, .inbox)
        s.selection = [a.id, b.id]
        s.delete([a.id])
        #expect(s.selection == [b.id])
    }

    /// Archive on a selection hidden by the unread filter: it isn't kept selected afterwards.
    @Test func archivingAHiddenSelectionDropsIt() {
        let a = msg(work, subject: "a", read: true, minutesAgo: 1), b = msg(work, subject: "b", minutesAgo: 2)
        let s = store([a, b])
        s.selectedMailbox = .account(work.id, .inbox)
        s.selection = [a.id]
        s.filterUnread = true
        s.archiveSelection()
        #expect(s.message(a.id)?.mailbox == .archive)
        #expect(s.selection.isEmpty)
    }

    /// Viewing Flagged, archiving the selected flagged row keeps it in the list, so it stays selected.
    @Test func movingASelectedRowThatStaysInTheListKeepsIt() {
        let a = msg(work, subject: "a", minutesAgo: 1, flag: .red), b = msg(work, subject: "b", minutesAgo: 2, flag: .red)
        let s = store([a, b])
        s.selectedMailbox = .smart(.flagged)
        s.selection = [a.id]
        s.archive([a.id])
        #expect(s.selection == [a.id])
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

    /// No category bar: the Inbox lists every message, whatever its category.
    @Test func inboxListsAllCategories() {
        let p = msg(work, subject: "p", minutesAgo: 1), promo = msg(work, subject: "promo", category: .promotions)
        let s = store([p, promo])
        s.selectedMailbox = .account(work.id, .inbox)
        #expect(s.visibleMessages.map(\.subject) == ["promo", "p"])
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

    /// As in Mail: the message you open stays in the unread-filtered list while it is selected, and leaves
    /// once the selection moves on.
    @Test func unreadFilterKeepsTheOpenedMessageUntilTheSelectionMovesOn() {
        let a = msg(work, subject: "a", minutesAgo: 1), b = msg(work, subject: "b", minutesAgo: 2)
        let s = store([a, b])
        s.selectedMailbox = .account(work.id, .inbox)
        s.filterUnread = true
        s.selection = [a.id]
        s.markSelectionRead()  // what MessageListView does on selection change
        #expect(s.message(a.id)?.isRead == true)
        #expect(s.visibleMessages.map(\.id) == [a.id, b.id])
        #expect(s.unreadCount(.account(work.id, .inbox)) == 1)
        s.selection = [b.id]
        s.markSelectionRead()
        #expect(s.visibleMessages.map(\.id) == [b.id])
        s.selection = []
        #expect(s.visibleMessages.isEmpty)
    }

    @Test func unreadMailboxKeepsTheOpenedMessageUntilTheSelectionMovesOn() {
        let a = msg(work, subject: "a", minutesAgo: 1), b = msg(work, subject: "b", minutesAgo: 2)
        let s = store([a, b])
        s.selectedMailbox = .smart(.unread)
        s.selection = [a.id]
        s.markSelectionRead()
        #expect(s.visibleMessages.map(\.id) == [a.id, b.id])
        #expect(s.unreadCount(.smart(.unread)) == 1)
        s.selection = [b.id]
        #expect(s.visibleMessages.map(\.id) == [b.id])
    }

    /// Turning the filter off and on, or going to another mailbox and back, lets the opened message go.
    @Test func theOpenedMessageLeavesWhenTheFilterOrMailboxChanges() {
        let a = msg(work, subject: "a", minutesAgo: 1), b = msg(work, subject: "b", minutesAgo: 2)
        let s = store([a, b])
        s.selectedMailbox = .account(work.id, .inbox)
        s.filterUnread = true
        s.selection = [a.id]
        s.markSelectionRead()
        s.filterUnread = false
        s.filterUnread = true
        #expect(s.visibleMessages.map(\.id) == [b.id])

        let s2 = store([a, b].map { var m = $0; m.isRead = false; return m })
        s2.selectedMailbox = .smart(.unread)
        s2.selection = [a.id]
        s2.markSelectionRead()
        s2.selectedMailbox = .smart(.allInboxes)
        s2.selectedMailbox = .smart(.unread)
        #expect(s2.visibleMessages.map(\.id) == [b.id])
    }

    /// Kept only as unread: deleting the opened message still takes it out of the list.
    @Test func theOpenedMessageStillLeavesWhenDeleted() {
        let a = msg(work, subject: "a", minutesAgo: 1), b = msg(work, subject: "b", minutesAgo: 2)
        let s = store([a, b])
        s.selectedMailbox = .smart(.unread)
        s.selection = [a.id]
        s.markSelectionRead()
        s.deleteSelection()
        #expect(s.visibleMessages.map(\.id) == [b.id])
        #expect(s.selection == [b.id])
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

    @Test func sendWithoutSubjectShowsNoSubjectInSent() {
        let s = store([])
        s.send(Draft(accountID: work.id, to: "a@x.com", subject: "", body: "B"))
        #expect(s.messages.first { $0.mailbox == .sent }?.subject == "(No Subject)")
    }

    @Test func replyAllSkipsRecipientsWithoutAddress() {
        var m = msg(work, from: "Ann")
        m.to = [Contact(name: "Me", email: work.address), Contact(name: "Undisclosed recipients", email: "")]
        m.cc = [Contact(name: "Group", email: "")]
        let s = store([m])
        let d = s.draft(.replyAll, to: m.id)
        #expect(d.to == "ann@x.com" && d.cc == "", "to: \(d.to.debugDescription), cc: \(d.cc.debugDescription)")
    }

    /// A failed Save Draft doesn't say the message couldn't be sent; a message without subject is named as its draft is.
    @Test func failedSaveOrSendStatusNamesWhatFailed() {
        let s = store([])
        s.merge([(.inbox, [])], account: work.id)
        let d = Draft(accountID: work.id, to: "bo@x.com", subject: "Plan", body: "draft text")
        s.failed(PendingChange(account: work.id, change: .saveDraft(d), previous: []), "busy")
        #expect(s.status?.contains("send") != true && s.status?.contains("“Plan”") == true, "status: \(s.status ?? "nil")")
        s.failed(PendingChange(account: work.id, change: .send(Draft(accountID: work.id, to: "a@x.com", body: "b")), previous: []), "busy")
        #expect(s.status?.hasPrefix("Couldn't send “(No Subject)”") == true, "status: \(s.status ?? "nil")")
    }

    /// The draft kept after a failed send shows a picture placed in the text where it was placed.
    @Test func failedSendKeepsPlacedPictureInItsPlace() async {
        let s = store([])
        s.merge([(.inbox, [])], account: work.id)
        var d = Draft(accountID: work.id, to: "a@x.com", subject: "S", body: "Look:\n\u{FFFC}\nnice")
        d.attachments = [DraftAttachment(name: "p.png", contentType: "image/png", data: Data([1, 2]))]
        s.failed(PendingChange(account: work.id, change: .send(d), previous: []), "busy")
        let kept = s.messages.first { $0.mailbox == .drafts }
        let html = kept?.html ?? ""
        #expect(kept?.body == "Look:\n\nnice")
        let cid = try? #require(HTMLPage.contentIDs(in: html).first, "html: \(html)")
        #expect(html.range(of: "Look:</div>\n<div><img src=\"cid:") != nil, "html: \(html)")
        await s.loadInlineImages(for: kept!.id)
        #expect(s.inlineImages(for: kept!.id)[cid ?? ""] == InlineImage(contentType: "image/png", data: Data([1, 2])))
    }

    /// A sender without a display name (Exchange gives the address as the name) is written once, also with no name at all.
    @Test func replyAndForwardShowAnAddressWithoutNameOnce() {
        var m = msg(work), n = msg(work, subject: "N")
        m.from = Contact(name: "noreply@shop.com", email: "noreply@shop.com")
        n.from = Contact(name: "", email: "bot@shop.com")
        m.invite = Invite(start: Date(timeIntervalSince1970: 2_000_000), end: Date(timeIntervalSince1970: 2_003_600),
                          organizer: Contact(name: "org@x.com", email: "org@x.com"))
        let s = store([m, n])
        let f = s.draft(.forward, to: m.id).body, r = s.draft(.reply, to: m.id).body
        #expect(f.contains("From: noreply@shop.com\n") && !f.contains("<noreply@shop.com>"), "forward: \(f.debugDescription)")
        #expect(r.contains(", noreply@shop.com wrote:") && !r.contains("<noreply@shop.com>"), "reply: \(r.debugDescription)")
        #expect(s.draft(.forward, to: n.id).body.contains("From: bot@shop.com\n"))
        #expect(s.answerDraft(.accept, to: m.id).to == "org@x.com")
    }

    /// The forwarded-message block names who the original went to, and its time with the time zone.
    @Test func forwardHeaderHasTimeZoneAndRecipients() {
        var m = msg(work, from: "Ann")
        m.to = [Contact(name: "Bob", email: "bob@x.com")]
        m.cc = [Contact(name: "Cy", email: "cy@x.com")]
        let s = store([m])
        let body = s.draft(.forward, to: m.id).body
        let dateLine = body.split(separator: "\n").first { $0.hasPrefix("Date:") }.map(String.init) ?? ""
        let tz = TimeZone.current
        let zoneNames = [tz.abbreviation(for: m.date) ?? "~", "GMT", "UTC", tz.identifier,
                         tz.localizedName(for: .standard, locale: .current) ?? "~",
                         tz.localizedName(for: .daylightSaving, locale: .current) ?? "~"]
        #expect(zoneNames.contains { dateLine.contains($0) }, "Date line has no time zone: \(dateLine)")
        #expect(body.contains("\nTo: Bob <bob@x.com>\n"), "no To line: \(body.debugDescription)")
        #expect(body.contains("\nCc: Cy <cy@x.com>\n"), "no Cc line: \(body.debugDescription)")
        // No Cc line without Cc.
        m.cc = []
        #expect(!store([m]).draft(.forward, to: m.id).body.contains("Cc:"))
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

    /// Addresses are compared without case: Reply All never goes back to my own address.
    @Test func replyAllLeavesOutMyAddressWhateverItsCase() {
        var m = msg(work)
        m.to = [Contact(name: "Me", email: "Me@Work.COM"), Contact(name: "Bo", email: "bo@x.com")]
        m.cc = [Contact(name: "Me too", email: "ME@WORK.COM")]
        let s = store([m])
        let d = s.draft(.replyAll, to: m.id)
        let emails = Contact.parseList(d.to + "," + d.cc).map { $0.email.lowercased() }
        #expect(emails == ["ann@x.com", "bo@x.com"], "to: \(d.to) cc: \(d.cc)")
    }

    /// Exchange bodies use CRLF: every line is quoted whatever its line ending, and the quote uses "\n".
    @Test func replyQuotesEveryLineWhateverItsLineEnding() {
        let m = msg(work)
        let s = store([m])
        s.setBody(MessageBody(text: "first\r\nsecond\nthird\rfourth\r\n\r\nlast", attachments: []), for: m.id)
        let d = s.draft(.reply, to: m.id)
        #expect(d.body.hasSuffix("\n\n> first\n> second\n> third\n> fourth\n> \n> last"), "body: \(d.body.debugDescription)")
        #expect(!d.body.unicodeScalars.contains("\r"))
        #expect(s.draft(.forward, to: m.id).body.hasSuffix("> fourth\n> \n> last"))
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

    @Test func archivingInArchiveKeepsTheSelection() {
        // Nothing changed, so nothing left the list: the selection stays (and the next message isn't opened).
        let a = msg(work, .archive, subject: "a", minutesAgo: 1), b = msg(work, .archive, subject: "b", minutesAgo: 2)
        let s = store([a, b])
        s.selectedMailbox = .account(work.id, .archive)
        s.selection = [a.id]
        s.archiveSelection()
        #expect(s.message(a.id)?.mailbox == .archive)
        #expect(s.selection == [a.id])
    }

    @Test func dropOnFlaggedOfAnAlreadyFlaggedTrashMessageChangesNothing() {
        // Not listed in Flagged (it's in Trash), but it has a flag already: the drop changes nothing.
        let a = msg(work, .trash, flag: .blue)
        let s = store([a])
        let r = s.drop([a.id], on: .smart(.flagged))
        #expect(s.message(a.id)?.flag == .blue && s.message(a.id)?.mailbox == .trash)
        #expect(!r)
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

    /// After the one-time sync from the start, mail already on the Mac learns its conversation and keeps the rest.
    @Test func syncingAgainAddsTheConversationAndKeepsLocalState() {
        let s = store([])
        s.apply(SyncResult(upserts: [remote("A")], deletedRemoteIDs: [], token: "t1", more: false),
                account: work.id, mailbox: .inbox)
        let id = s.messages[0].id
        s.selection = [id]
        s.setBody(MessageBody(text: "Full text", attachments: ["a.pdf"]), for: id)
        s.setFlag(.purple, for: [id])
        _ = s.takeChanges()
        var again = remote("A"); again.flag = .red; again.conversationID = "C"
        s.apply(SyncResult(upserts: [again], deletedRemoteIDs: [], token: "t2", more: false), account: work.id, mailbox: .inbox)
        let m = s.messages[0]
        #expect(m.id == id && m.conversationID == "C")
        #expect(m.body == "Full text" && m.flag == .purple)
        #expect(s.selection == [id])
        #expect(s.takeChanges().resolved().upserts.map(\.conversationID) == ["C"])
    }

    @Test func htmlBodyIsStoredAndSurvivesASync() {
        let s = store([])
        s.apply(SyncResult(upserts: [remote("A")], deletedRemoteIDs: [], token: "t1", more: false),
                account: work.id, mailbox: .inbox)
        let id = s.messages[0].id
        s.setBody(MessageBody(text: "Hi", attachments: [], html: "<p>Hi</p>"), for: id)
        #expect(s.messages[0].html == "<p>Hi</p>")
        #expect(s.messages[0].body == "Hi")
        #expect(!s.messages[0].needsBody)
        s.apply(SyncResult(upserts: [remote("A", read: true)], deletedRemoteIDs: [], token: "t2", more: false),
                account: work.id, mailbox: .inbox)
        #expect(s.messages[0].html == "<p>Hi</p>")
        #expect(!s.messages[0].needsBody)
    }

    @Test func bodyLoadedBeforeHTMLSupportIsFetchedOnceMore() {
        var m = remote("A")
        #expect(m.needsBody)
        m.body = "Plain"; m.bodyLoaded = true  // as cached by an older version: no HTML check yet
        #expect(m.needsBody)
        let s = store([])
        s.apply(SyncResult(upserts: [m], deletedRemoteIDs: [], token: "t", more: false), account: work.id, mailbox: .inbox)
        s.setBody(MessageBody(text: "Plain", attachments: []), for: s.messages[0].id)
        #expect(!s.messages[0].needsBody)  // a plain-text message is not fetched again
        #expect(!msg(work).needsBody)      // sample data has no server
    }

    @Test func remoteContentIsDetected() {
        func html(_ h: String) -> Message { var m = msg(work); m.html = h; return m }
        #expect(html(#"<img src="https://t.example/p.gif">"#).hasRemoteContent)
        #expect(html("<td style=\"background:url( 'http://x.example/bg.png')\">").hasRemoteContent)
        #expect(html("<td background=http://x.example/bg.png>").hasRemoteContent)
        #expect(!html(#"<a href="https://x.example">link</a><img src="cid:image001.png">"#).hasRemoteContent)
        #expect(!msg(work).hasRemoteContent)
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

    @Test func failedSendKeepsItsAttachmentsInTheLocalDraft() async throws {
        let s = synced([])
        s.downloadsFolder = FileManager.default.temporaryDirectory.appendingPathComponent("FailedTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: s.downloadsFolder) }
        var d = Draft(accountID: work.id, to: "ann@x.com", subject: "S", body: "B")
        d.attachments = [DraftAttachment(name: "f.txt", contentType: "text/plain", data: Data("x".utf8))]
        s.send(d)
        s.failed(s.outbox[0], "Timeout")
        let draft = try #require(s.messages.first { $0.mailbox == .drafts })
        #expect(draft.attachments == [MailModel.Attachment(name: "f.txt", size: 1, contentType: "text/plain")])
        let file = try #require(await s.attachmentFile(0, of: draft.id))
        #expect(try Data(contentsOf: file) == Data("x".utf8))
    }

    /// While a forward's original files are still loading, it isn't sent or saved without them.
    @Test func forwardIsNotSentBeforeItsAttachmentsAreIn() {
        let s = synced([])
        var d = Draft(accountID: work.id, to: "ann@x.com", subject: "Fwd: S")
        d.loadingOriginal = UUID()
        s.send(d)
        s.saveDraft(d)
        #expect(s.outbox.isEmpty)
        #expect(s.status?.contains("still being loaded") == true)
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

    /// History pages are merged in one go (one pass over all messages); the result is as if applied one by one.
    @Test func severalPagesApplyLikeOneAfterTheOther() {
        let s = synced([])
        let pages = [
            SyncResult(upserts: [remote("A"), remote("B")], deletedRemoteIDs: [], token: "p1", more: true),
            SyncResult(upserts: [remote("C")], deletedRemoteIDs: ["A"], readChanges: ["B": true], token: "p2", more: true),
            SyncResult(upserts: [remote("A", subject: "Back")], deletedRemoteIDs: ["C"], token: "p3", more: false),
        ]
        s.apply(pages, account: work.id, mailbox: .sent)
        let sent = s.messages.filter { $0.mailbox == .sent }
        #expect(Set(sent.compactMap(\.remoteID)) == ["A", "B"])
        #expect(sent.first { $0.remoteID == "A" }?.subject == "Back")
        #expect(sent.first { $0.remoteID == "B" }?.isRead == true)
        #expect(s.syncToken(work.id, .sent) == "p3")
        #expect(s.isComplete(work.id, .sent))
    }

    /// The quick check mostly gets nothing new: that mustn't touch the messages, which redraws every view.
    @Test func anEmptySyncLeavesTheMessagesAlone() {
        let s = synced(["A"])
        let before = s.changeCount
        s.apply(SyncResult(upserts: [], deletedRemoteIDs: [], token: "t2", more: false), account: work.id, mailbox: .inbox)
        s.apply([SyncResult(upserts: [], deletedRemoteIDs: [], token: "t3", more: false)], account: work.id, mailbox: .inbox)
        s.merge([], account: work.id, mailbox: .sent)
        #expect(s.changeCount == before)
        #expect(s.syncToken(work.id, .inbox) == "t3")
    }

    /// The newest messages of several folders go in with one pass over all messages.
    @Test func newestOfSeveralFoldersMergeAtOnce() {
        let s = synced([])
        let before = s.changeCount
        s.merge([(.sent, [remote("S")]), (.drafts, [remote("D")]), (.archive, [])], account: work.id)
        #expect(s.changeCount == before + 1)
        #expect(s.messages.first { $0.remoteID == "S" }?.mailbox == .sent)
        #expect(s.messages.first { $0.remoteID == "D" }?.mailbox == .drafts)
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

    @Test func answeringAnInviteQueuesTheResponseAndUndoesOnFailure() {
        var m = remote("M")
        m.invite = Invite(start: .now, end: .now.addingTimeInterval(1800))
        let s = store([])
        s.apply(SyncResult(upserts: [m], deletedRemoteIDs: [], token: "t", more: false), account: work.id, mailbox: .inbox)
        let id = id(s, "M")
        s.respond(.tentative, to: id)
        #expect(s.message(id)?.invite?.response == .tentative)
        #expect(s.outbox.map(\.change) == [.respond("M", .tentative)])
        s.failed(s.outbox[0], "Denied")
        #expect(s.message(id)?.invite?.response == nil)
        #expect(s.status != nil)
        // Changing one's mind before the first answer went out: both go out, in order, as in Outlook.
        s.respond(.accept, to: id)
        s.respond(.decline, to: id)
        #expect(s.outbox.map(\.change) == [.respond("M", .accept), .respond("M", .decline)])
    }

    @Test func answeredInviteLeavesTheInboxAtOnceAndTheNextMessageIsSelected() {
        let (s, id) = inviteStore()
        s.apply(SyncResult(upserts: [remote("N", minutesAgo: 5)], deletedRemoteIDs: [], token: "t2", more: false),
                account: work.id, mailbox: .inbox)
        s.selectedMailbox = .account(work.id, .inbox)
        s.selection = [id]
        s.respond(.accept, to: id)
        #expect(s.message(id)?.mailbox == .trash)
        #expect(s.selection == [self.id(s, "N")])
        // Exchange moves it itself: no move request is queued.
        #expect(s.outbox.map(\.change) == [.respond("M", .accept)])
        // The inbox sync still lists it until the server has the answer; it stays out of the Inbox.
        var again = remote("M"); again.invite = s.message(id)?.invite
        s.apply(SyncResult(upserts: [again], deletedRemoteIDs: [], token: "t3", more: false), account: work.id, mailbox: .inbox)
        #expect(s.message(id)?.mailbox == .trash)
        // Refused: back in the Inbox.
        s.failed(s.outbox[0], "Denied")
        #expect(s.message(id)?.mailbox == .inbox)
    }

    @Test func removingACancelledMeetingFromTheCalendarTrashesTheMessageAndSelectsTheNext() {
        let (s, id) = inviteStore()
        s.apply(SyncResult(upserts: [remote("N", minutesAgo: 5)], deletedRemoteIDs: [], token: "t2", more: false),
                account: work.id, mailbox: .inbox)
        s.selectedMailbox = .account(work.id, .inbox)
        s.selection = [id]
        s.removeFromCalendar(id)
        #expect(s.message(id)?.mailbox == .trash)
        #expect(s.selection == [self.id(s, "N")])
        #expect(s.outbox.map(\.change) == [.removeFromCalendar("M")])
        s.failed(s.outbox[0], "Denied")
        #expect(s.message(id)?.mailbox == .inbox)
    }

    /// Invites cached before cancellations were told apart load their body once more, to learn which they are.
    @Test func cachedInviteWithoutCancellationStateIsReadAgain() {
        var m = remote("M")
        m.invite = Invite(start: .now, end: .now)
        m.bodyLoaded = true
        m.htmlChecked = true
        #expect(m.needsBody)
        m.invite?.isCancellation = false
        #expect(!m.needsBody)
    }

    func inviteStore() -> (MailStore, Message.ID) {
        var m = remote("M")
        m.invite = Invite(start: Date(timeIntervalSince1970: 3600), end: Date(timeIntervalSince1970: 5400))
        let s = store([])
        s.apply(SyncResult(upserts: [m], deletedRemoteIDs: [], token: "t", more: false), account: work.id, mailbox: .inbox)
        return (s, id(s, "M"))
    }

    @Test func answerWithCommentOrWithoutTellingTheOrganizer() {
        let (s, id) = inviteStore()
        let quiet = InviteReply(response: .accept, send: false)
        s.respond(quiet, to: id)
        #expect(s.message(id)?.invite?.response == .accept)
        #expect(s.message(id)?.invite?.reply == quiet)
        let note = InviteReply(response: .decline, comment: "On holiday")
        s.respond(note, to: id)
        #expect(s.outbox.map(\.change) == [.reply("M", quiet), .reply("M", note)])
        s.failed(s.outbox[1], "Denied")
        #expect(s.message(id)?.invite?.reply == quiet)
    }

    @Test func proposingANewTimeNeedsAnEndAfterTheStart() {
        let (s, id) = inviteStore()
        let start = Date(timeIntervalSince1970: 7200)
        s.respond(InviteReply(response: .tentative, proposedStart: start, proposedEnd: start), to: id)
        #expect(s.outbox.isEmpty)
        #expect(s.status != nil)
        #expect(s.message(id)?.invite?.response == nil)
        let ok = InviteReply(response: .decline, proposedStart: start, proposedEnd: start.addingTimeInterval(1800))
        s.respond(ok, to: id)
        #expect(s.outbox.map(\.change) == [.reply("M", ok)])
    }

    /// A proposal with only a start or only an end is refused: Exchange would get a plain answer without it.
    @Test func proposingANewTimeNeedsBothStartAndEnd() {
        let (s, id) = inviteStore()
        let time = Date(timeIntervalSince1970: 7200)
        s.respond(InviteReply(response: .tentative, proposedStart: time), to: id)
        #expect(s.outbox.isEmpty)
        #expect(s.status == "The proposed meeting needs both a start and an end.")
        s.status = nil
        s.respond(InviteReply(response: .decline, proposedEnd: time), to: id)
        #expect(s.outbox.isEmpty)
        #expect(s.status != nil)
        #expect(s.message(id)?.invite?.response == nil)
    }

    @Test func answerWithCommentsIsWrittenAsAMessageToTheOrganizer() {
        var m = remote("M", subject: "Q4 review")
        m.invite = Invite(start: .now, end: .now.addingTimeInterval(1800), organizer: Contact(name: "Priya Raman", email: "priya@x.com"))
        let s = store([])
        s.apply(SyncResult(upserts: [m], deletedRemoteIDs: [], token: "t", more: false), account: work.id, mailbox: .inbox)
        let id = id(s, "M")
        let d = s.answerDraft(.decline, to: id)
        #expect(d.to == "Priya Raman <priya@x.com>")
        #expect(d.subject == "Declined: Q4 review")
        #expect(d.body.isEmpty && d.accountID == work.id)
        #expect(d.inviteAnswer == InviteAnswer(messageID: id, response: .decline))
        #expect(s.answerDraft(.accept, to: id).subject == "Accepted: Q4 review")
        #expect(s.answerDraft(.tentative, to: id).subject == "Tentative: Q4 review")

        var written = d
        written.body = "  Da bin ich im Zug…\n"
        s.send(written)
        #expect(s.outbox.map(\.change) == [.reply("M", InviteReply(response: .decline, comment: "Da bin ich im Zug…"))])
        #expect(s.message(id)?.invite?.response == .decline)
    }

    @Test func proposingANewTimeIsWrittenAsAMessageToo() {
        let (s, id) = inviteStore()
        let d = s.answerDraft(.tentative, to: id, proposing: true)
        #expect(d.subject.hasPrefix("New Time Proposed: "))
        #expect(d.inviteAnswer?.proposedStart == Date(timeIntervalSince1970: 3600))  // starts at the meeting's time
        #expect(d.inviteAnswer?.proposedEnd == Date(timeIntervalSince1970: 5400))
        #expect(d.to == "")  // no organizer known: Exchange still sends it to the organizer
        var written = d
        written.inviteAnswer?.proposedStart = Date(timeIntervalSince1970: 7200)
        written.inviteAnswer?.proposedEnd = Date(timeIntervalSince1970: 9000)
        s.send(written)
        #expect(s.outbox.map(\.change) == [.reply("M", InviteReply(response: .tentative, proposedStart: Date(timeIntervalSince1970: 7200),
                                                                     proposedEnd: Date(timeIntervalSince1970: 9000)))])
    }

    /// Respond with Comments, then the invite is gone (a sync reports it deleted) before Send: the user is told,
    /// and the window stays open with the comment, instead of everything vanishing without a word (BUG-069).
    @Test func answerForAnInviteThatIsGoneIsNotSilentlyDropped() {
        var m = remote("INV", subject: "Q4 review")
        m.invite = Invite(start: .now, end: .now.addingTimeInterval(1800), organizer: Contact(name: "Org", email: "org@x.com"))
        let s = store([])
        s.apply(SyncResult(upserts: [m], deletedRemoteIDs: [], token: "t", more: false), account: work.id, mailbox: .inbox)
        var d = s.answerDraft(.decline, to: id(s, "INV"))
        d.body = "Sorry, I am out that week."
        s.merge([], deleted: ["INV"], account: work.id, mailbox: .inbox)  // removed elsewhere meanwhile
        #expect(!s.send(d), "the window stays open")
        #expect(s.outbox.isEmpty)
        #expect(s.status?.contains("Q4 review") == true, "status: \(s.status ?? "nil")")
    }

    /// A message written for a sample account that signing in has removed is not sent, or saved, from the
    /// Exchange account behind the user's back: the window stays open and says why (BUG-070).
    @Test func draftOfARemovedAccountIsNotSentFromAnother() {
        let s = store([msg(home, subject: "sample")])
        let d = Draft(accountID: home.id, to: "bo@x.com", subject: "Test", body: "written in sample mode")
        let exchange = Account(name: "Exchange", address: "me@corp.com")
        s.removeLocalAccounts()  // sign-in: sample accounts go
        s.accounts.append(exchange)
        s.merge([(.inbox, [])], account: exchange.id)  // the Exchange account (server mail)
        s.send(d)
        let saved = s.saveDraft(d)
        #expect(s.outbox.isEmpty, "queued: \(s.outbox.map { s.account($0.account)?.name ?? "?" })")
        #expect(!saved && !s.messages.contains { $0.subject == "Test" })
        #expect(s.status?.contains("no longer set up") == true, "status: \(s.status ?? "nil")")
    }

    /// An invite answered while it is one of several selected messages (Send in the comment window after selecting
    /// more in the main window) leaves the selection with its move to Trash, so Delete can't erase it unseen (BUG-099).
    @Test func inviteAnsweredInAMultiSelectionLeavesTheSelection() {
        var inv = remote("INV", minutesAgo: 2)
        inv.invite = Invite(start: .now, end: .now.addingTimeInterval(1800))
        let s = store([])
        s.apply(SyncResult(upserts: [inv, remote("X", minutesAgo: 1), remote("Y")], deletedRemoteIDs: [], token: "t", more: false),
                account: work.id, mailbox: .inbox)
        let invID = id(s, "INV"), x = id(s, "X")
        s.selectedMailbox = .account(work.id, .inbox)
        s.selection = [invID, x]
        s.respond(InviteReply(response: .accept, comment: "ok"), to: invID)
        #expect(s.message(invID)?.mailbox == .trash)
        #expect(s.selection == [x])
        s.deleteSelection()
        #expect(s.message(invID)?.mailbox == .trash, "Delete erased the answered invite from Trash")
    }

    /// Inline images can be megabytes: only the message on screen keeps them, in memory, never in the cache.
    @Test func inlineImagesAreKeptForTheShownMessageOnly() {
        let s = store([msg(work), msg(work)])
        let (a, b) = (s.messages[0].id, s.messages[1].id)
        let png = InlineImage(contentType: "image/png", data: Data([1]))
        s.setInlineImages(["x@y": png], for: a)
        #expect(s.inlineImages(for: a) == ["x@y": png])
        s.setInlineImages(["z@y": png], for: b)
        #expect(s.inlineImages(for: a).isEmpty)
        #expect(s.inlineImages(for: b) == ["z@y": png])
    }

    func thread(_ acct: Account, _ box: MailboxKind = .inbox, _ conversation: String?, minutesAgo: Double) -> Message {
        var m = msg(acct, box, subject: "Re: Plan", minutesAgo: minutesAgo)
        m.conversationID = conversation
        return m
    }

    /// A message shows with the rest of its conversation: same account, any mailbox but Trash, Junk and Drafts,
    /// newest first, as in Mail.
    @Test func conversationCollectsTheThreadAcrossMailboxes() {
        let received = thread(work, .inbox, "C", minutesAgo: 30), sent = thread(work, .sent, "C", minutesAgo: 10)
        let filed = thread(work, .folder("P"), "C", minutesAgo: 60)
        let others = [thread(work, .trash, "C", minutesAgo: 5), thread(work, .junk, "C", minutesAgo: 6),
                      thread(work, .drafts, "C", minutesAgo: 7), thread(home, .inbox, "C", minutesAgo: 8),
                      thread(work, .inbox, "D", minutesAgo: 9), thread(work, .inbox, nil, minutesAgo: 11)]
        let s = store([received, sent, filed] + others)
        #expect(s.conversation(of: received.id).map(\.id) == [sent.id, received.id, filed.id])
        #expect(s.conversation(of: filed.id).map(\.id) == [sent.id, received.id, filed.id])
    }

    /// Without a conversation, or alone in it, or in the Trash, a message is shown by itself.
    @Test func conversationOfASingleMessageIsTheMessage() {
        let lone = thread(work, .inbox, nil, minutesAgo: 1), only = thread(work, .inbox, "E", minutesAgo: 2)
        let binned = thread(work, .trash, "F", minutesAgo: 3), kept = thread(work, .inbox, "F", minutesAgo: 4)
        let s = store([lone, only, binned, kept])
        #expect(s.conversation(of: lone.id).map(\.id) == [lone.id])
        #expect(s.conversation(of: only.id).map(\.id) == [only.id])
        #expect(s.conversation(of: binned.id).map(\.id) == [binned.id, kept.id])
        #expect(s.conversation(of: UUID()).isEmpty)
    }

    /// Every message of the conversation on screen keeps its inline images; opening another conversation drops them.
    @Test func inlineImagesAreKeptForTheConversationOnScreen() {
        let a = thread(work, .inbox, "C", minutesAgo: 2), b = thread(work, .sent, "C", minutesAgo: 1)
        let c = thread(work, .inbox, "D", minutesAgo: 3)
        let s = store([a, b, c])
        let png = InlineImage(contentType: "image/png", data: Data([1]))
        s.selection = [a.id]
        s.addInlineImages(["a@y": png], for: a.id)
        s.addInlineImages(["b@y": png], for: b.id)
        #expect(s.inlineImages(for: a.id) == ["a@y": png])
        #expect(s.inlineImages(for: b.id) == ["b@y": png])
        s.selection = [c.id]
        s.addInlineImages(["c@y": png], for: c.id)
        #expect(s.inlineImages(for: a.id).isEmpty)
        #expect(s.inlineImages(for: b.id).isEmpty)
        #expect(s.inlineImages(for: c.id) == ["c@y": png])
    }

    func attachmentStore(_ names: [MailModel.Attachment], data: [Data]) -> (MailStore, Message.ID, URL) {
        var m = msg(work); m.attachments = names
        let s = store([m])
        s.setAttachmentData(data, for: m.id)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AttachmentTests-\(UUID())")
        s.downloadsFolder = dir.appendingPathComponent("Mail Downloads")
        return (s, m.id, dir)
    }

    /// Opening writes the file under its own name; two files with the same name stay apart; a sender's
    /// name can't reach outside the downloads folder.
    @Test func openedAttachmentsAreFilesInTheDownloadsFolder() async throws {
        let (s, id, dir) = attachmentStore(["a.pdf", "a.pdf", "../../evil.sh"], data: [Data([1]), Data([2]), Data([3])])
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try #require(await s.attachmentFile(0, of: id))
        let second = try #require(await s.attachmentFile(1, of: id))
        let evil = try #require(await s.attachmentFile(2, of: id))
        #expect(first.lastPathComponent == "a.pdf" && second.lastPathComponent == "a.pdf" && first != second)
        #expect(try Data(contentsOf: first) == Data([1]))
        #expect(try Data(contentsOf: second) == Data([2]))
        #expect(evil.lastPathComponent == "..:..:evil.sh")
        #expect(evil.standardizedFileURL.path.hasPrefix(s.downloadsFolder.standardizedFileURL.path + "/"))
        #expect(await s.attachmentFile(3, of: id) == nil)
    }

    /// The user opens a file and edits it in Mail Downloads (Preview fills in a form in place). A forward and Save
    /// Attachment still carry the attachment as it came in the mail; opening again shows the edited copy.
    @Test func editedOpenedCopyIsNotForwardedOrSaved() async throws {
        let original = Data("%PDF original form".utf8), edited = Data("%PDF filled in with my bank details".utf8)
        let (s, id, dir) = attachmentStore(["form.pdf"], data: [original])
        defer { try? FileManager.default.removeItem(at: dir) }
        let opened = try #require(await s.attachmentFile(0, of: id))
        try edited.write(to: opened)
        var d = s.draft(.forward, to: id)
        await s.includeOriginalAttachments(in: &d)
        #expect(d.attachments.first?.data == original)
        let saved = await s.saveAttachment(0, of: id, to: dir.appendingPathComponent("Saved"))
        #expect(saved.flatMap { try? Data(contentsOf: $0) } == original)
        #expect(try Data(contentsOf: try #require(await s.originalAttachmentFile(0, of: id))) == original)
        #expect(await s.attachmentFile(0, of: id) == opened)
        #expect(try Data(contentsOf: opened) == edited)
    }

    /// Picked or dropped files are read into the draft with their type; a missing file is left out.
    @Test func filesAreAttachedToADraft() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AttachTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pdf = dir.appendingPathComponent("Plan.pdf")
        try Data([1, 2]).write(to: pdf)
        let s = store([])
        var d = Draft(accountID: work.id)
        s.attach([pdf, dir.appendingPathComponent("Gone.txt")], to: &d)
        #expect(d.attachments == [DraftAttachment(name: "Plan.pdf", contentType: "application/pdf", data: Data([1, 2]))])
        #expect(s.status?.contains("Gone.txt") == true)
    }

    /// Mail forwards with the original's attachments; replies go without them.
    @Test func forwardTakesTheAttachmentsAlongRepliesDoNot() async throws {
        let (s, id, dir) = attachmentStore(["a.pdf"], data: [Data([7])])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(s.draft(.reply, to: id).loadingOriginal == nil)
        var d = s.draft(.forward, to: id)
        #expect(d.loadingOriginal == id)
        await s.includeOriginalAttachments(in: &d)
        #expect(d.attachments == [DraftAttachment(name: "a.pdf", contentType: "application/pdf", data: Data([7]), fromOriginal: true)])
        #expect(d.loadingOriginal == nil)
    }

    /// A forward whose original files can't be had (body not loaded, no connection) isn't released without them:
    /// it stays blocked and says so (BUG-071).
    @Test func forwardWhoseFilesCannotLoadStaysBlocked() async {
        var m = Message(accountID: work.id, from: Contact(name: "Ann Lee", email: ""), to: [], subject: "Contract", body: "",
                        date: Date(timeIntervalSince1970: 1_000_000), remoteID: "A", bodyLoaded: false)
        m.hasAttachments = true
        let s = store([])
        s.merge([m], account: work.id, mailbox: .inbox)
        var d = s.draft(.forward, to: s.messages[0].id)
        await s.includeOriginalAttachments(in: &d)
        #expect(d.loadingOriginal != nil && d.attachments.isEmpty)
        #expect(s.status?.contains("original") == true, "status: \(s.status ?? "nil")")
    }

    /// One of two files can't be loaded: none is added and the forward stays blocked; once they can be had,
    /// trying again adds both.
    @Test func forwardWithOneUnavailableFileStaysBlocked() async {
        let (s, id, dir) = attachmentStore(["a.pdf", "b.pdf"], data: [Data([1])])  // b.pdf's content can't be had
        defer { try? FileManager.default.removeItem(at: dir) }
        var d = s.draft(.forward, to: id)
        await s.includeOriginalAttachments(in: &d)
        #expect(d.loadingOriginal == id && d.attachments.isEmpty, "files: \(d.attachments.map(\.name))")
        #expect(s.status?.contains("b.pdf") == true, "status: \(s.status ?? "nil")")
        s.setAttachmentData([Data([1]), Data([2])], for: id)
        await s.includeOriginalAttachments(in: &d)
        #expect(d.loadingOriginal == nil && d.attachments.map(\.name) == ["a.pdf", "b.pdf"])
    }

    /// A folder is attached as a zip archive of it.
    @Test func foldersAreAttachedAsZip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ZipTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("a.txt"))
        let s = store([])
        var d = Draft(accountID: work.id)
        s.attach([folder], to: &d)
        let zip = try #require(d.attachments.first)
        #expect(zip.name == "Photos.zip" && zip.contentType == "application/zip")
        #expect(zip.data.prefix(2) == Data("PK".utf8))
        #expect(s.status == nil)
    }

    /// A symbolic link to a folder is attached as a zip of the folder, under the link's name.
    @Test func symlinkToFolderIsAttachedAsZip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ZipTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("Photos"), link = dir.appendingPathComponent("Photos alias")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let s = store([])
        let files = s.files([link])
        #expect(files.map(\.name) == ["Photos alias.zip"] && files.first?.contentType == "application/zip",
                "files: \(files.map(\.name)) status: \(s.status ?? "nil")")
        #expect(files.first?.data.prefix(2) == Data("PK".utf8))
    }

    /// A dropped or pasted Finder alias stands for its original: the file it points to is attached under the
    /// original's name, a folder as a zip, not the alias's bookmark bytes (BUG-134).
    @Test func finderAliasIsAttachedAsWhatItPointsTo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AliasTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("Photos"), report = dir.appendingPathComponent("Report.pdf")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try Data("%PDF-1.4 real report".utf8).write(to: report)
        func alias(_ target: URL) throws -> URL {
            let url = dir.appendingPathComponent(target.lastPathComponent + " alias")
            try URL.writeBookmarkData(try target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil,
                                                              relativeTo: nil), to: url)
            #expect(try url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile == true)  // a real alias
            return url
        }
        let s = store([])
        let files = s.files([try alias(report), try alias(folder)])
        #expect(files.map(\.name) == ["Report.pdf", "Photos.zip"], "files: \(files.map(\.name)) status: \(s.status ?? "nil")")
        #expect(files.first?.data == Data("%PDF-1.4 real report".utf8) && files.first?.contentType == "application/pdf")
        #expect(files.last?.contentType == "application/zip" && files.last?.data.prefix(2) == Data("PK".utf8))
    }

    /// Edit ▸ Include Attachments With Replies: Always adds them to a reply, Never and Ask don't by themselves.
    /// Forward always does. The draft remembers the original either way, for the Include Attachments button.
    @Test func repliesIncludeAttachmentsPerSetting() {
        var m = msg(work); m.attachments = ["a.pdf"]
        let s = store([m])
        #expect(s.draft(.reply, to: m.id, includeAttachments: .never).loadingOriginal == nil)
        #expect(s.draft(.reply, to: m.id, includeAttachments: .ask).loadingOriginal == nil)
        #expect(s.draft(.reply, to: m.id, includeAttachments: .never).original == m.id)
        #expect(s.draft(.reply, to: m.id, includeAttachments: .always).loadingOriginal == m.id)
        #expect(s.draft(.forward, to: m.id, includeAttachments: .never).loadingOriginal == m.id)
        #expect(s.draft(.reply, to: msg(work).id, includeAttachments: .always).original == nil)
    }

    /// When Adding Recipients: someone who wasn't on the original gets its attachments.
    @Test func addingANewRecipientIncludesTheAttachments() {
        var m = msg(work, from: "Ann"); m.attachments = ["a.pdf"]
        m.cc = [Contact(name: "Bob", email: "bob@x.com")]
        let s = store([m])
        var d = s.draft(.replyAll, to: m.id, includeAttachments: .whenAddingRecipients)
        #expect(!s.addsNewRecipient(d))
        d.cc = "b"  // still typing: not an address yet
        #expect(!s.addsNewRecipient(d))
        d.cc = "bob@x.com, Me <me@work.com>"
        #expect(!s.addsNewRecipient(d))
        d.to += ", Cy <cy@x.com>"
        #expect(s.addsNewRecipient(d))
    }

    /// Include/Exclude Attachments takes out only the original's files, and puts them back.
    @Test func excludeAndIncludeOriginalAttachments() async {
        let (s, id, dir) = attachmentStore(["a.pdf"], data: [Data([7])])
        defer { try? FileManager.default.removeItem(at: dir) }
        var d = s.draft(.forward, to: id, includeAttachments: .never)
        await s.includeOriginalAttachments(in: &d)
        let own = DraftAttachment(name: "mine.txt", contentType: "text/plain", data: Data([1]))
        d.attachments.append(own)
        #expect(d.hasOriginalAttachments)
        d.excludeOriginalAttachments()
        #expect(d.attachments == [own])
        #expect(!d.hasOriginalAttachments)
        d.loadingOriginal = d.original
        await s.includeOriginalAttachments(in: &d)
        #expect(d.attachments.map(\.name) == ["mine.txt", "a.pdf"])
    }

    /// The size Exchange counts: files in base64, plus the text. Over the account's maximum, Send asks first.
    @Test func messageSizeAndTheAccountsMaximum() {
        let s = store([])
        var d = Draft(accountID: work.id, body: "Hi")
        d.attachments = [DraftAttachment(name: "big.bin", contentType: nil, data: Data(count: 3_000_000))]
        #expect(d.estimatedSize > 4_000_000 && d.estimatedSize < 4_200_000)
        #expect(s.maximumSize(for: d) == nil)
        s.setMaxMessageSize(10_485_760, for: work.id)
        #expect(!s.isOverSizeLimit(d))
        d.attachments.append(DraftAttachment(name: "big2.bin", contentType: nil, data: Data(count: 6_000_000)))
        #expect(s.isOverSizeLimit(d))
    }

    /// Sent from a local account: the copy in Sent has the files, with their size, and they open.
    @Test func localSentMailKeepsItsAttachments() async throws {
        let s = store([])
        s.downloadsFolder = FileManager.default.temporaryDirectory.appendingPathComponent("SentTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: s.downloadsFolder) }
        var d = Draft(accountID: work.id, to: "ann@x.com", subject: "Files")
        d.attachments = [DraftAttachment(name: "n.txt", contentType: "text/plain", data: Data("hi".utf8))]
        s.send(d)
        let sent = try #require(s.messages.first { $0.mailbox == .sent })
        #expect(sent.attachments == [MailModel.Attachment(name: "n.txt", size: 2, contentType: "text/plain")])
        let file = try #require(await s.attachmentFile(0, of: sent.id))
        #expect(try String(contentsOf: file, encoding: .utf8) == "hi")
    }

    /// Files placed in the text: each sits at a U+FFFC in the body, which never goes out as text.
    @Test func closingAsksOnlyAfterTheUserChangedSomething() {
        let start = Draft(accountID: work.id, to: "ann@x.com", subject: "Fwd: Pics", body: "\n\nBegin forwarded message:")
        #expect(!start.hasChanges(since: start))
        // The original's files arriving by themselves, or being excluded again, are not the user's changes.
        var d = start
        d.attachments = [DraftAttachment(name: "o.pdf", contentType: nil, data: Data([1]), fromOriginal: true)]
        d.body += String(Draft.fileMark)
        #expect(!d.hasChanges(since: start))
        d.excludeOriginalAttachments()
        #expect(!d.hasChanges(since: start))
        // Anything typed, chosen or attached is.
        let changes: [(inout Draft) -> Void] = [
            { $0.body += "x" }, { $0.to += ", bob@x.com" }, { $0.cc = "c@x.com" }, { $0.subject = "Pics" },
            { $0.accountID = UUID() },
            { $0.attachments.append(DraftAttachment(name: "a.jpg", contentType: nil, data: Data([2]))) },
        ]
        for change in changes {
            var e = start
            change(&e)
            #expect(e.hasChanges(since: start))
        }
    }

    @Test func filesInTheTextLeaveNoMarkInTheSentText() throws {
        let s = store([])
        var d = Draft(accountID: work.id, to: "ann@x.com", subject: "Pics", body: "Look:\n\u{FFFC}\nand\u{FFFC}")
        d.attachments = [DraftAttachment(name: "a.jpg", contentType: "image/jpeg", data: Data([1])),
                         DraftAttachment(name: "b.pdf", contentType: "application/pdf", data: Data([2]))]
        #expect(d.text == "Look:\n\nand")
        #expect(d.estimatedSize == Draft(accountID: work.id, subject: "Pics", body: d.text).estimatedSize
                + d.attachments.reduce(0) { $0 + Draft.encodedSize($1) })
        s.send(d)
        let sent = try #require(s.messages.first { $0.mailbox == .sent })
        #expect(sent.body == "Look:\n\nand")
        #expect(sent.attachments.map(\.name) == ["a.jpg", "b.pdf"])
    }

    /// Exclude Attachments takes the original's files out of the text too; the rest keep their place.
    @Test func excludingTheOriginalsFilesRemovesTheirMarks() {
        var d = Draft(accountID: work.id, body: "a\u{FFFC}b\u{FFFC}c")
        let mine = DraftAttachment(name: "mine.txt", contentType: nil, data: Data([1]))
        d.attachments = [DraftAttachment(name: "orig.pdf", contentType: nil, data: Data([2]), fromOriginal: true), mine,
                         DraftAttachment(name: "late.pdf", contentType: nil, data: Data([3]), fromOriginal: true)]
        d.excludeOriginalAttachments()
        #expect(d.body == "ab\u{FFFC}c")
        #expect(d.attachments == [mine])
    }

    /// Drafts in the outbox from before attachments existed still load.
    @Test func draftsWithoutAttachmentsStillDecode() throws {
        let old = #"{"accountID":"\#(work.id.uuidString)","to":"a@x.com","cc":"","subject":"S","body":"B"}"#
        let d = try JSONDecoder().decode(Draft.self, from: Data(old.utf8))
        #expect(d.attachments.isEmpty && d.loadingOriginal == nil)
    }

    /// Bodies cached before attachments had sizes are fetched once more; sample mail isn't.
    @Test func bodiesCachedWithAttachmentNamesOnlyAreFetchedAgain() {
        var m = msg(work); m.remoteID = "R"; m.htmlChecked = true; m.attachments = ["a.pdf"]
        #expect(m.needsBody)
        m.attachments = [MailModel.Attachment(name: "a.pdf", size: 10)]
        #expect(!m.needsBody)
        var local = msg(work); local.attachments = ["a.pdf"]
        #expect(!local.needsBody)
    }

    /// Files from mail are quarantined, so Gatekeeper asks before an attached app or script runs.
    @Test func openedAndSavedAttachmentsAreQuarantined() async throws {
        let (s, id, dir) = attachmentStore(["run.command"], data: [Data("echo hi".utf8)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let opened = try #require(await s.attachmentFile(0, of: id))
        let saved = try #require(await s.saveAttachment(0, of: id, to: dir.appendingPathComponent("Saved")))
        for url in [opened, saved] {
            let q = try (url as NSURL).resourceValues(forKeys: [.quarantinePropertiesKey])[.quarantinePropertiesKey]
                as? [String: Any]
            #expect(q?[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeEmailAttachment as String)
        }
    }

    /// Saving never overwrites: a second copy gets " 2", as in the Finder.
    @Test func savedAttachmentsGetAFreeName() async throws {
        let (s, id, dir) = attachmentStore(["Report.pdf", "photo"], data: [Data([1]), Data([2])])
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("Downloads")
        let a = try #require(await s.saveAttachment(0, of: id, to: target))
        let b = try #require(await s.saveAttachment(0, of: id, to: target))
        #expect(a.lastPathComponent == "Report.pdf" && b.lastPathComponent == "Report 2.pdf")
        let all = await s.saveAllAttachments(of: id, to: target)
        #expect(all.map(\.lastPathComponent) == ["Report 3.pdf", "photo"])
        #expect(try Data(contentsOf: b) == Data([1]))
    }

    /// A broken symbolic link (or alias) with the attachment's name counts as taken, as in the Finder.
    @Test func savingNextToABrokenLinkGetsAFreeName() async throws {
        let (s, id, dir) = attachmentStore(["Report.pdf"], data: [Data([1])])
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: target.appendingPathComponent("Report.pdf").path,
                                                   withDestinationPath: "/nonexistent/old-report.pdf")
        let saved = await s.saveAttachment(0, of: id, to: target)
        #expect(saved?.lastPathComponent == "Report 2.pdf", "status: \(s.status ?? "nil")")
    }

    /// A name longer than a file name may be (255 bytes) is shortened, keeping its extension, so the attachment
    /// still opens and saves, also a second time.
    @Test func attachmentsWithVeryLongNamesOpenAndSave() async throws {
        let name = String(repeating: "Überweisungsbestätigung ", count: 12) + ".pdf"  // ~330 bytes
        let (s, id, dir) = attachmentStore([MailModel.Attachment(name: name)], data: [Data([1])])
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try #require(await s.attachmentFile(0, of: id), "status: \(String(describing: s.status))")
        // A file URL spells names decomposed; the file system gets (and counts) them as given, here composed.
        let bytes = { (u: URL) in u.lastPathComponent.precomposedStringWithCanonicalMapping.utf8.count }
        #expect(bytes(file) <= 255 && file.lastPathComponent.hasSuffix(".pdf"))
        #expect(try Data(contentsOf: file) == Data([1]))
        let target = dir.appendingPathComponent("Downloads")
        let a = try #require(await s.saveAttachment(0, of: id, to: target))
        let b = try #require(await s.saveAttachment(0, of: id, to: target))
        #expect(a != b && bytes(b) <= 255 && b.lastPathComponent.hasSuffix(" 2.pdf"))
    }

    /// Quick Look shows every attachment of the message, starting at the chosen one.
    @Test func quickLookOpensAllAttachmentsAtTheChosenOne() async throws {
        let (s, id, dir) = attachmentStore(["a.txt", "b.txt"], data: [Data([1]), Data([2])])
        defer { try? FileManager.default.removeItem(at: dir) }
        await s.quickLookAttachments(of: id, at: 1)
        #expect(s.previewItems.map(\.lastPathComponent) == ["a.txt", "b.txt"])
        #expect(s.previewItem == s.previewItems[1])
    }

    /// Quick Look on a file that can't be had opens no other file in its place; without a chosen one (Quick Look
    /// N Attachments) it starts at the first that loaded.
    @Test func quickLookOnAnUnavailableFileShowsNoOther() async throws {
        let (s, id, dir) = attachmentStore(["a.pdf", "b.pdf"], data: [Data([1])])
        defer { try? FileManager.default.removeItem(at: dir) }
        await s.quickLookAttachments(of: id, at: 1)
        #expect(s.previewItem == nil, "front \(s.previewItem?.lastPathComponent ?? "nil")")
        #expect(s.status?.contains("b.pdf") == true)
        await s.quickLookAttachments(of: id)
        #expect(s.previewItem?.lastPathComponent == "a.pdf")
    }

    /// A message without its content (no server, nothing stored) says so instead of opening an empty file.
    @Test func missingContentShowsAStatus() async {
        let (s, id, dir) = attachmentStore(["a.pdf"], data: [])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await s.attachmentFile(0, of: id) == nil)
        #expect(s.status?.contains("a.pdf") == true)
    }

    @Test func markAllRead() {
        let s = store([msg(work), msg(work), msg(home)])
        s.markAllRead(in: .account(work.id, .inbox))
        #expect(s.unreadCount(.smart(.allInboxes)) == 1)
    }

    // MARK: Search through the database index

    /// A real database holding `msgs`, searchable; the store's searcher runs against it.
    func searchDB(_ msgs: [Message]) throws -> (MailDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MailStoreSearch-\(UUID())/Mail.sqlite")
        let db = try MailDatabase(url: url)
        try db.write(StoreChanges(upserts: msgs))
        try db.prepareSearch()
        return (db, url)
    }

    /// Holds the searches for some queries until released, and says when one has started.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var held: [String: CheckedContinuation<Void, Never>] = [:]
        private let slow: Set<String>
        let entered: AsyncStream<String>
        private let enter: AsyncStream<String>.Continuation
        init(slow: Set<String>) { self.slow = slow; (entered, enter) = AsyncStream.makeStream() }
        func pass(_ q: String) async {
            guard slow.contains(q) else { return }
            await withCheckedContinuation { c in lock.withLock { held[q] = c }; enter.yield(q) }
        }
        func release(_ q: String) { lock.withLock { held.removeValue(forKey: q) }?.resume() }
    }

    func searching(_ s: MailStore, _ db: MailDatabase, gate: Gate? = nil) {
        s.searchDebounce = .zero
        s.searcher = { q, accounts in
            await gate?.pass(q)
            return try db.search(q, accounts: accounts)
        }
    }

    /// Hits are checked against memory: Trash, another account's mail and messages gone from memory don't show.
    @Test func searchHitsFollowWhatIsInMemory() async throws {
        let one = msg(work, subject: "Report one", minutesAgo: 3), two = msg(work, subject: "Report two", minutesAgo: 1),
            trashed = msg(work, .trash, subject: "Report trashed"), other = msg(home, subject: "Report home"),
            gone = msg(work, subject: "Report gone"), fragment = msg(work, subject: "Misreported")
        let (db, url) = try searchDB([one, two, trashed, other, gone, fragment])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // "Misreported" matches only the old substring search: the list must come from the index.
        let s = store([one, two, trashed, other, fragment])
        searching(s, db)
        s.searchText = "report"
        await s.searchTask?.value
        #expect(s.visibleMessages.map(\.subject) == ["Report home", "Report two", "Report one"])
        // An account mailbox narrows the search to that account.
        s.selectedMailbox = .account(work.id, .inbox)
        await s.searchTask?.value
        #expect(s.visibleMessages.map(\.subject) == ["Report two", "Report one"])
        // Deleted a moment ago: gone from the results at once, though the database still has it in the Inbox.
        s.delete([two.id])
        #expect(s.visibleMessages.map(\.subject) == ["Report one"])
        s.searchText = ""
        #expect(s.searchHits == nil)
        #expect(s.visibleMessages.map(\.subject) == ["Misreported", "Report one"])
    }

    /// A slow reply for an earlier query never replaces the results of the current one.
    @Test func aStaleSearchReplyIsIgnored() async throws {
        let abacus = msg(work, subject: "Abacus"), apple = msg(work, subject: "Apple")
        let (db, url) = try searchDB([abacus, apple])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = store([abacus, apple])
        let gate = Gate(slow: ["a"])
        searching(s, db, gate: gate)
        var started = gate.entered.makeAsyncIterator()
        s.searchText = "a"
        _ = await started.next()  // the search for "a" is under way
        let slow = s.searchTask
        s.searchText = "ab"
        await s.searchTask?.value
        #expect(s.visibleMessages.map(\.subject) == ["Abacus"])
        gate.release("a")
        await slow?.value
        #expect(s.searchHits?.query == "ab")
        #expect(s.visibleMessages.map(\.subject) == ["Abacus"])
    }

    /// While the next query's hits are on their way, the list keeps the previous results.
    @Test func previousResultsStayWhileTheNextArePending() async throws {
        let one = msg(work, subject: "Report one", minutesAgo: 2), two = msg(work, subject: "Report two", minutesAgo: 1)
        let (db, url) = try searchDB([one, two])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = store([one, two])
        let gate = Gate(slow: ["report one"])
        searching(s, db, gate: gate)
        s.searchText = "report"
        await s.searchTask?.value
        var started = gate.entered.makeAsyncIterator()
        s.searchText = "report one"
        _ = await started.next()
        #expect(s.visibleMessages.map(\.subject) == ["Report two", "Report one"])
        gate.release("report one")
        await s.searchTask?.value
        #expect(s.visibleMessages.map(\.subject) == ["Report one"])
    }

    /// Results that came from memory (before the index was ready) also stay while the index's answer is on its way.
    @Test func memoryResultsStayWhileTheIndexAnswerIsPending() async throws {
        let hit = msg(work, subject: "Report Q3", minutesAgo: 5), other = msg(work, subject: "Lunch", minutesAgo: 1)
        let (db, url) = try searchDB([hit, other])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = store([hit, other])
        s.selectedMailbox = .account(work.id, .inbox)
        s.searchText = "report"
        #expect(s.visibleMessages.map(\.subject) == ["Report Q3"])  // memory
        let gate = Gate(slow: ["report", "report q"])
        var started = gate.entered.makeAsyncIterator()
        searching(s, db, gate: gate)
        _ = await started.next()
        #expect(s.visibleMessages.map(\.subject) == ["Report Q3"])
        s.searchText = "report q"
        _ = await started.next()
        #expect(s.visibleMessages.map(\.subject) == ["Report Q3"])
        #expect(!s.awaitingSearchResults)
        gate.release("report"); gate.release("report q")
        await s.searchTask?.value
    }

    /// After a query the index couldn't answer (memory answered it), the next pending query keeps those results.
    @Test func memoryResultsOfAFailedQueryStayWhileTheNextIsPending() async throws {
        let hit = msg(work, subject: "Report Q3", minutesAgo: 5), other = msg(work, subject: "Lunch", minutesAgo: 1)
        let s = store([hit, other])
        s.selectedMailbox = .account(work.id, .inbox)
        let gate = Gate(slow: ["report q"])
        final class Flag: @unchecked Sendable { var fail = true }
        let flag = Flag()
        s.searchDebounce = .zero
        s.searcher = { q, _ in
            if flag.fail { throw DatabaseError(errorDescription: "busy") }
            await gate.pass(q)
            return [hit.id]
        }
        s.searchText = "report"
        await s.searchTask?.value
        #expect(s.visibleMessages.map(\.subject) == ["Report Q3"])  // memory fallback
        flag.fail = false
        var started = gate.entered.makeAsyncIterator()
        s.searchText = "report q"
        _ = await started.next()
        #expect(s.visibleMessages.map(\.subject) == ["Report Q3"])
        gate.release("report q")
        await s.searchTask?.value
    }

    /// Before the first answer of a search there are no results to keep: the store says so, so the list doesn't
    /// claim "No Results" meanwhile.
    @Test func theFirstPendingAnswerIsNotNoResults() async throws {
        let archived = msg(work, .archive, subject: "Report archived")
        let (db, url) = try searchDB([archived])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = store([archived])
        let gate = Gate(slow: ["report"])
        searching(s, db, gate: gate)
        s.selectedMailbox = .account(work.id, .inbox)  // empty
        var started = gate.entered.makeAsyncIterator()
        s.searchText = "report"
        _ = await started.next()
        #expect(s.awaitingSearchResults)
        gate.release("report")
        await s.searchTask?.value
        #expect(!s.awaitingSearchResults && s.visibleMessages.map(\.subject) == ["Report archived"])
    }

    /// Mail that changes while a search runs is shown as it is now, not as it was when the search began.
    @Test func changesDuringASearchShowInItsResults() async throws {
        let one = msg(work, subject: "Report one", minutesAgo: 2), two = msg(work, subject: "Report two", minutesAgo: 1)
        let (db, url) = try searchDB([one, two])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = store([one, two])
        let gate = Gate(slow: ["report"])
        searching(s, db, gate: gate)
        var started = gate.entered.makeAsyncIterator()
        s.searchText = "report"
        _ = await started.next()
        s.delete([two.id])
        gate.release("report")
        await s.searchTask?.value
        #expect(s.visibleMessages.map(\.subject) == ["Report one"])
    }

    /// Switching from one account's mailbox to another's during a search keeps the previous results on screen until
    /// the answer for the new account arrives: no empty list ("No Results") meanwhile (BUG-080).
    @Test func switchingAccountScopeDoesNotFlashEmptyResults() async throws {
        let w = msg(work, subject: "Report work"), h = msg(home, subject: "Report home")
        let (db, url) = try searchDB([w, h])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = store([w, h])
        searching(s, db)
        s.selectedMailbox = .account(work.id, .inbox)
        s.searchText = "report"
        await s.searchTask?.value
        #expect(s.visibleMessages.map(\.subject) == ["Report work"])
        s.searchDebounce = .milliseconds(150)
        s.selectedMailbox = .account(home.id, .inbox)
        let meanwhile = s.visibleMessages.map(\.subject)
        await s.searchTask?.value
        #expect(s.visibleMessages.map(\.subject) == ["Report home"])
        #expect(!meanwhile.isEmpty, "the list is empty (No Results) until the new answer arrives")
    }

    /// Typed while the index wasn't ready yet: memory answers, then the index takes over by itself.
    @Test func searchTypedBeforeTheIndexIsReady() async throws {
        let m = msg(work, subject: "Misreported")
        let (db, url) = try searchDB([m])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = store([m])
        s.searchText = "report"
        #expect(s.visibleMessages.map(\.subject) == ["Misreported"])  // substring, from memory
        searching(s, db)
        #expect(s.visibleMessages.map(\.subject) == ["Misreported"])  // still memory until the index answers
        await s.searchTask?.value
        #expect(s.searchHits?.query == "report")
        #expect(s.visibleMessages.isEmpty)  // word prefix, from the index
    }

    /// At the limit the status says only the newest are shown; clearing the search removes the notice.
    @Test func searchLimitIsAnnouncedAndCleared() async throws {
        let msgs = (0..<MailDatabase.searchLimit).map { msg(work, subject: "Note \($0)", minutesAgo: Double($0)) }
        let (db, url) = try searchDB(msgs)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = store(msgs)
        searching(s, db)
        s.searchText = "note"
        await s.searchTask?.value
        #expect(s.status == "Showing the newest 2,000 results")
        #expect(s.visibleMessages.count == 2000)
        s.searchText = ""
        #expect(s.status == nil)
    }

    /// A failing index search falls back to searching memory, and says so.
    @Test func aFailedIndexSearchFallsBackToMemory() async {
        let s = store([msg(work, subject: "Lunch")])
        s.searchDebounce = .zero
        s.searcher = { _, _ in throw DatabaseError(errorDescription: "broken") }
        s.searchText = "lun"
        await s.searchTask?.value
        #expect(s.visibleMessages.map(\.subject) == ["Lunch"])
        #expect(s.status?.contains("broken") == true)
    }

    /// BUG-183: favourites are All Inboxes, VIPs, Flagged and each account's Inbox; only the first nine get ⌘1–⌘9.
    /// The tenth asked for the key "10", which crashed the app with 7 or more accounts.
    @Test func favoriteMailboxShortcutsStopAtNine() {
        let accounts = (1...7).map { Account(name: "A\($0)", address: "a\($0)@x.com") }
        let s = MailStore(accounts: accounts, messages: [])
        #expect(s.favoriteMailboxes.count == 10)
        #expect(s.favoriteMailboxes.prefix(3) == [.smart(.allInboxes), .smart(.vip), .smart(.flagged)])
        #expect(s.favoriteMailboxes.last == .account(accounts[6].id, .inbox))
        #expect(MailStore.favoriteKey(at: 0) == "1")
        #expect(MailStore.favoriteKey(at: 8) == "9")
        #expect(MailStore.favoriteKey(at: 9) == nil)
    }

    /// BUG-186: Reply goes to the Reply-To addresses when the message has them (RFC 5322 §3.6.2); Reply All to them
    /// plus the other recipients.
    @Test func replyGoesToReplyTo() {
        var m = msg(work, from: "Shop")
        m.replyTo = [Contact(name: "Support", email: "support@shop.example")]
        m.cc = [Contact(name: "Bob", email: "bob@x.com")]
        let s = store([m])
        #expect(s.draft(.reply, to: m.id).to == "support@shop.example")
        let all = s.draft(.replyAll, to: m.id)
        #expect(all.to == "support@shop.example")
        #expect(all.cc == "bob@x.com")
        // A Reply-To with names only (no address) counts as none: Reply All keeps the sender (review of BUG-186).
        var n = msg(work, from: "Shop")
        n.replyTo = [Contact(name: "Support", email: "")]
        let t = store([n])
        #expect(t.draft(.replyAll, to: n.id).to == "shop@x.com")
        #expect(t.draft(.reply, to: n.id).to == "shop@x.com")
    }

    /// BUG-239: Include Attachments With Replies ▸ When Adding Recipients. A reply to a message with Reply-To (a
    /// mailing list, a ticket system) goes to the Reply-To address, which `addsNewRecipient` doesn't count as "on the
    /// original": leaving To unchanged pulls in the original's files.
    @Test func replyToAddressIsNotANewRecipient() {
        var m = Message(accountID: work.id, mailbox: .inbox, from: Contact(name: "Ann", email: "ann@x.com"),
                        to: [Contact(name: "Team", email: "team@lists.x.com")], subject: "Specs", body: "See attached",
                        date: Date(timeIntervalSince1970: 1_000_000), attachments: [Attachment(name: "spec.pdf", size: 10)])
        m.replyTo = [Contact(name: "Team", email: "team@lists.x.com"), Contact(name: "Tickets", email: "tickets@x.com")]
        let s = MailStore(accounts: [work], messages: [m])
        let d = s.draft(.reply, to: m.id, includeAttachments: .whenAddingRecipients)
        #expect(d.to.contains("tickets@x.com"))
        #expect(!s.addsNewRecipient(d), "the untouched reply counts as adding a recipient: To = \(d.to)")
    }

    /// BUG-221: Toggle Flag clears the flags if any selected message is flagged, else flags them red.
    @Test func toggleFlagClearsIfAnyIsFlaggedElseFlagsRed() {
        let a = msg(work, subject: "a"), b = msg(work, subject: "b", flag: .blue)
        let s = store([a, b])
        s.toggleFlag([a.id, b.id])
        #expect(s.message(a.id)?.flag == nil && s.message(b.id)?.flag == nil)
        s.toggleFlag([a.id, b.id])
        #expect(s.message(a.id)?.flag == .red && s.message(b.id)?.flag == .red)
    }

    /// BUG-188: U+FFFC in the original's text is the attachment mark in a draft; quoted, it becomes U+FFFD, so a
    /// forward doesn't place the original's picture there, and Exclude Attachments leaves the quote alone.
    @Test func objectReplacementCharacterInTheOriginalIsNotAFileMark() async {
        var m = msg(work, subject: "Pic")
        m.body = "Look \u{FFFC} here"
        m.attachments = [Attachment(name: "a.png", size: 4, contentType: "image/png")]
        m.hasAttachments = true
        let s = store([m])
        s.downloadsFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        s.setAttachmentData([Data([1, 2, 3, 4])], for: m.id)
        var d = s.draft(.forward, to: m.id)
        await s.includeOriginalAttachments(in: &d)
        #expect(d.attachments.count == 1)
        #expect(d.placedPictures == [])
        d.excludeOriginalAttachments()
        #expect(d.body.contains("Look \u{FFFD} here"))
    }

    /// BUG-172: memory search splits the query where the index does (punctuation, symbols): "Q3 - report" and
    /// "report, q3" find "Q3 report"; a query of only invisible characters finds nothing, not everything.
    @Test func memorySearchSplitsWordsLikeTheIndex() {
        let q3 = msg(work, subject: "Q3 report"), other = msg(work, subject: "Lunch")
        let s = store([q3, other])
        for q in ["Q3 - report", "report, q3", "q3/report"] {
            s.searchText = q
            #expect(s.visibleMessages.map(\.id) == [q3.id], "\(q)")
        }
        for q in ["\u{2028}", "-", "–, /"] {
            s.searchText = q
            #expect(s.visibleMessages.isEmpty, "\(q.debugDescription)")
        }
        // A zero-width space counts as a blank (Foundation's whitespace): no search, the mailbox as without one.
        s.searchText = "\u{200B}"
        #expect(Set(s.visibleMessages.map(\.id)) == [q3.id, other.id])
    }

    /// BUG-238: the original of a forward goes away (deleted elsewhere) while its files load: the forward keeps
    /// waiting for them, with a notice, so it isn't sent without them by accident (Try Again / Continue Without Them).
    @Test func forwardOfVanishedOriginalKeepsWaitingForItsFiles() async {
        var m = msg(work, subject: "Contract")
        m.attachments = [Attachment(name: "contract.pdf", size: 500, contentType: "application/pdf")]
        m.hasAttachments = true
        let s = store([m])
        var d = s.draft(.forward, to: m.id)
        #expect(d.loadingOriginal == m.id)
        s.delete([m.id]); s.delete([m.id])  // to Trash, then erased
        #expect(s.message(m.id) == nil)
        await s.includeOriginalAttachments(in: &d)
        #expect(d.loadingOriginal == m.id)
        #expect(d.attachments.isEmpty)
        #expect(s.status?.contains("no longer available") == true)
    }
}
