import Foundation
import Testing
@testable import MailModel

/// Bug-hunt round 5, area A: list rows, conversations, selection, folder tree, smart mailboxes, drops.
@MainActor
struct Probe_R5A {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")

    func mail(_ acct: Account, _ subject: String, box: MailboxKind = .inbox, from: String = "Ann Lee", conv: String? = nil,
              read: Bool = false, minutesAgo: Double = 0, flag: FlagColor? = nil, rid: String? = nil, vip: Bool = false) -> Message {
        var m = Message(accountID: acct.id, mailbox: box,
                        from: Contact(name: from, email: "\(from.split(separator: " ").first.map(String.init)?.lowercased() ?? "x")@x.com"),
                        to: [Contact(name: "Me", email: acct.address)], subject: subject, body: "Body of \(subject)",
                        date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60), isRead: read, flag: flag,
                        isVIP: vip, remoteID: rid)
        m.conversationID = conv
        return m
    }

    func store(_ msgs: [Message], grouped: Bool = true) -> MailStore {
        let s = MailStore(accounts: [work, home], messages: msgs)
        s.groupsConversations = grouped
        s.selectedMailbox = .smart(.allInboxes)
        return s
    }

    // R5A-01
    /// With only unread mail shown, Mark All as Read takes the selected (unopened) messages out of the list, but they
    /// stay selected: a following Delete moves mail the user can't see (README: a message that leaves the list never
    /// stays selected).
    @Test func markAllReadDoesNotKeepHiddenMessagesSelected() {
        let a = mail(work, "a", minutesAgo: 1), b = mail(work, "b", minutesAgo: 2), c = mail(work, "c", read: true, minutesAgo: 3)
        let s = store([a, b, c], grouped: false)
        s.selectedMailbox = .account(work.id, .inbox)
        s.filterUnread = true
        s.selection = [a.id, b.id]  // a multi-selection is not opened, so not marked read
        s.markAllRead(in: s.selectedMailbox)
        let visible = Set(s.visibleMessages.map(\.id))
        #expect(s.selection.isSubset(of: visible), "selection \(s.selection.count) hidden after Mark All as Read")
    }

    // R5A-02
    /// A reply arrived in the selected conversation: the row stands for the reply, the selection still holds the
    /// older message. Deleting the row by swipe or context menu should select the next row, as Delete does.
    @Test func swipeDeleteOfRowWhoseOlderMessageIsSelectedSelectsNextRow() {
        let s = store([])
        s.merge([mail(work, "Plan", conv: "P", read: true, minutesAgo: 30, rid: "R1"),
                 mail(work, "Other", from: "Bob Ray", minutesAgo: 60, rid: "R3")], account: work.id, mailbox: .inbox)
        let q = s.messages.first { $0.remoteID == "R1" }!.id, other = s.messages.first { $0.remoteID == "R3" }!.id
        s.selection = [q]
        s.merge([mail(work, "Re: Plan", from: "Bob Ray", conv: "P", minutesAgo: 1, rid: "R2")], account: work.id, mailbox: .inbox)
        let row = s.visibleMessages[0].id
        #expect(s.listSelection == [row])
        s.delete(s.withConversations([row]))  // swipe ▸ Trash on the selected row
        #expect(s.selection == [other])
    }

    // R5A-02 (main symptom)
    /// Same state: flagging (or marking unread) the open conversation, which stays in the list, clears the selection,
    /// so the message pane goes blank.
    @Test func flaggingTheOpenConversationAfterAReplyArrivedKeepsItSelected() {
        let s = store([])
        s.merge([mail(work, "Plan", conv: "P", read: true, minutesAgo: 30, rid: "R1")], account: work.id, mailbox: .inbox)
        s.selection = [s.messages[0].id]
        s.merge([mail(work, "Re: Plan", from: "Bob Ray", conv: "P", minutesAgo: 1, rid: "R2")], account: work.id, mailbox: .inbox)
        let row = s.visibleMessages[0].id
        s.setFlag(.red, for: s.withConversations(s.selection))  // Message ▸ Flag ▸ Red
        #expect(s.visibleMessages.map(\.id).contains(row))
        #expect(s.listSelection == [row])
    }

    // R5A-03
    /// A sender whose display name is only a comma (", " as "Last, First" with both empty) crashes the list row.
    @Test func conversationSendersWithCommaOnlyNameDoNotCrash() async {
        await #expect(processExitsWith: .success) {
            _ = ConversationRow.senders([Contact(name: ", ", email: "a@x.com"), Contact(name: "Bob Ray", email: "b@x.com")])
        }
    }

    // R5A-04
    /// Two different people who share a first name are shown as one sender's full name, as for a single-sender row.
    @Test func twoSendersWithTheSameFirstNameAreNotShownAsOne() {
        let names = [Contact(name: "Jan Jikeli", email: "jan.j@x.com"), Contact(name: "Jan Müller", email: "jan.m@x.com")]
        #expect(ConversationRow.senders(names) != "Jan Jikeli")
    }

    // R5A-05
    /// Mail in a folder inside Trash is deleted mail (DECISIONS d-bug-025); Delete there should erase it, as in Trash,
    /// not move it to Trash for a second Delete.
    @Test func deleteInAFolderInsideTrashErases() {
        let old = MailboxKind.folder("old")
        let m = mail(work, "a", box: old)
        let s = store([m], grouped: false)
        s.setFolders([Folder(box: old, name: "Old Project", parent: .trash)], account: work.id)
        s.selectedMailbox = .account(work.id, old)
        s.selection = [m.id]
        s.deleteSelection()
        #expect(s.message(m.id)?.mailbox.rawValue == nil)
    }

    // R5A-06
    /// The selection holds an older invite whose conversation row now stands for a newer message (it arrived later).
    /// Answering the invite on screen takes only the invite out; the conversation row stays in the list, yet the
    /// selection jumps to another conversation (which is then opened and marked read).
    @Test func answeringTheShownInviteKeepsItsConversationRowSelected() {
        let s = store([])
        var inv = mail(work, "Planning", from: "Org Person", conv: "M", read: true, minutesAgo: 30, rid: "I1")
        inv.invite = Invite(start: Date(timeIntervalSince1970: 2_000_000), end: Date(timeIntervalSince1970: 2_003_600))
        s.merge([inv, mail(work, "Other", from: "Bob Ray", minutesAgo: 60, rid: "O1")], account: work.id, mailbox: .inbox)
        let invID = s.messages.first { $0.remoteID == "I1" }!.id
        s.selection = [invID]
        s.merge([mail(work, "Re: Planning", from: "Cy Doe", conv: "M", read: true, minutesAgo: 1, rid: "R2")], account: work.id, mailbox: .inbox)
        let row = s.visibleMessages[0].id
        #expect(s.listSelection == [row])
        // Control: the same row selected by clicking it (selection == [row]) keeps it selected after the same answer.
        let c = store([])
        c.merge([inv, mail(work, "Other", from: "Bob Ray", minutesAgo: 60, rid: "O1"),
                 mail(work, "Re: Planning", from: "Cy Doe", conv: "M", read: true, minutesAgo: 1, rid: "R2")],
                account: work.id, mailbox: .inbox)
        let cRow = c.visibleMessages[0].id
        c.selection = [cRow]
        c.respond(.accept, to: c.messages.first { $0.remoteID == "I1" }!.id)
        #expect(c.listSelection == [cRow])
        s.respond(.accept, to: invID)
        #expect(s.visibleMessages.map(\.id).contains(row))
        #expect(s.listSelection == [row], "selection moved to \(s.selection.compactMap { s.message($0)?.subject })")
    }

    // R5A-07
    /// The row shows senders' first names. Corporate display names "Last, First (Org)" and names with a no-break
    /// space (which `Contact.initials` already handles) don't give the first name.
    @Test func conversationSendersAreFirstNamesForCorporateAndNoBreakSpaceNames() {
        let corp = [Contact(name: "Jikeli, Jan (mgm-tp)", email: "j@x.com"), Contact(name: "Lerena, Sergio Luis", email: "s@x.com")]
        #expect(ConversationRow.senders(corp) == "Jan & Sergio")
        let nbsp = [Contact(name: "Jan\u{00A0}Jikeli", email: "j@x.com"), Contact(name: "Bob Ray", email: "b@x.com")]
        #expect(ConversationRow.senders(nbsp) == "Jan & Bob")
    }
}
