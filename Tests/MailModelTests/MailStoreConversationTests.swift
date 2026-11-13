import Foundation
import Testing
@testable import MailModel

/// The list shows a conversation as one row, as Mail does with View ▸ Organize by Conversation: its newest message
/// stands for it, a badge counts its messages, and what is done to the row is done to all of them.
@MainActor
struct MailStoreConversationTests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")

    func mail(_ acct: Account, _ subject: String, box: MailboxKind = .inbox, from: String = "Ann Lee", conv: String? = nil,
             read: Bool = false, minutesAgo: Double = 0, flag: FlagColor? = nil, rid: String? = nil) -> Message {
        var m = Message(accountID: acct.id, mailbox: box, from: Contact(name: from, email: "\(from.split(separator: " ")[0].lowercased())@x.com"),
                        to: [Contact(name: "Me", email: acct.address)], subject: subject, body: "Body of \(subject)",
                        date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60), isRead: read, flag: flag, remoteID: rid)
        m.conversationID = conv
        return m
    }

    func store(_ msgs: [Message], grouped: Bool = true) -> MailStore {
        let s = MailStore(accounts: [work, home], messages: msgs)
        s.groupsConversations = grouped
        s.selectedMailbox = .smart(.allInboxes)
        return s
    }

    /// Jan's answer to Sergio's mail, a mail of its own, and the same conversation ID in another account.
    var thread: (question: Message, answer: Message, other: Message, elsewhere: Message) {
        let question = mail(work, "Hilfe! ESACA", from: "Sergio Lerena", conv: "C", read: true, minutesAgo: 30)
        let answer = mail(work, "AW: Hilfe! ESACA", from: "Jan Jikeli", conv: "C", minutesAgo: 10)
        let other = mail(work, "Lunch?", from: "Bob Ray", minutesAgo: 20)
        let elsewhere = mail(home, "Other account", from: "Cy Doe", conv: "C", minutesAgo: 40)
        return (question, answer, other, elsewhere)
    }

    @Test func aConversationIsOneRowStoodForByItsNewestMessage() {
        let t = thread
        let s = store([t.question, t.answer, t.other, t.elsewhere])
        #expect(s.visibleMessages.map(\.subject) == ["AW: Hilfe! ESACA", "Lunch?", "Other account"])
        let row = s.conversationRow(t.answer.id)
        #expect(row?.count == 2)
        #expect(row?.senders == "Jan & Sergio")
        #expect(row?.subject == "Hilfe! ESACA")  // the conversation's first message names it, as in Mail
        #expect(row?.isRead == false)
        #expect(s.conversationRow(t.other.id) == nil)  // a single message has no badge
        #expect(s.withConversations([t.answer.id]) == [t.answer.id, t.question.id])
        #expect(s.withConversations([t.other.id]) == [t.other.id])
    }

    @Test func turnedOffAndWhileSearchingEveryMessageIsARow() {
        let t = thread
        let off = store([t.question, t.answer, t.other], grouped: false)
        #expect(off.visibleMessages.count == 3)
        #expect(off.withConversations([t.answer.id]) == [t.answer.id])
        let s = store([t.question, t.answer, t.other])
        s.searchText = "esaca"
        #expect(s.visibleMessages.count == 2)
    }

    @Test func deletingTheSelectedRowMovesTheWholeConversationAndSelectsTheNextRow() {
        let t = thread
        let s = store([t.question, t.answer, t.other])
        s.selection = [t.answer.id]
        s.deleteSelection()
        #expect(s.message(t.question.id)?.mailbox == .trash)
        #expect(s.message(t.answer.id)?.mailbox == .trash)
        #expect(s.selection == [t.other.id])
    }

    @Test func droppingTheSelectedRowMovesTheWholeConversation() {
        let t = thread
        let s = store([t.question, t.answer, t.other])
        s.selection = [t.answer.id]
        #expect(s.drop(s.withConversations(s.selection), on: .account(work.id, .archive)))
        #expect(s.message(t.question.id)?.mailbox == .archive)
        #expect(s.message(t.answer.id)?.mailbox == .archive)
        #expect(s.selection == [t.other.id])
    }

    /// On Flagged the messages stay in the Inbox list: as with a single message, the selection moves on.
    @Test func droppingTheSelectedRowOnFlaggedFlagsTheWholeConversation() {
        let t = thread
        let s = store([t.question, t.answer, t.other])
        s.selection = [t.answer.id]
        #expect(s.drop(s.withConversations(s.selection), on: .smart(.flagged)))
        #expect(s.message(t.question.id)?.flag == .red)
        #expect(s.message(t.answer.id)?.flag == .red)
        #expect(s.selection == [t.other.id])
    }

    /// Opening a conversation reads all of it, so its unread dot goes; with only unread mail shown, the row stays
    /// while it is selected, as a single message does.
    @Test func openingARowMarksTheWholeConversationRead() {
        var t = thread
        t.question.isRead = false
        let s = store([t.question, t.answer, t.other])
        s.filterUnread = true
        s.selection = [t.answer.id]
        s.markSelectionRead()
        #expect(s.message(t.question.id)?.isRead == true)
        #expect(s.message(t.answer.id)?.isRead == true)
        #expect(s.conversationRow(t.answer.id)?.isRead == true)
        #expect(s.visibleMessages.map(\.id).contains(t.answer.id))
        s.selection = [t.other.id]
        #expect(!s.visibleMessages.map(\.id).contains(t.answer.id))
    }

    /// A reply arriving in the selected conversation becomes the row: the row stays selected and its message shows.
    @Test func aReplyArrivingKeepsTheConversationSelected() {
        let q = mail(work, "Plan", from: "Ann Lee", conv: "P", read: true, minutesAgo: 30, rid: "R1")
        let s = store([])
        s.merge([q], account: work.id, mailbox: .inbox)
        let qid = s.messages[0].id
        s.selection = [qid]
        s.merge([mail(work, "Re: Plan", from: "Bob Ray", conv: "P", minutesAgo: 1, rid: "R2")], account: work.id, mailbox: .inbox)
        let row = s.visibleMessages[0]
        #expect(row.subject == "Re: Plan")
        #expect(s.listSelection == [row.id])
        #expect(s.selectedMessage?.id == qid)
        #expect(s.withConversations(s.selection) == [qid, row.id])
    }

    /// Delete in Trash erases: on a row it erases every message the row stands for (the badge shows how many).
    @Test func deletingARowInTrashErasesTheWholeConversation() {
        let a = mail(work, "A", box: .trash, conv: "T", minutesAgo: 2), b = mail(work, "Re: A", box: .trash, conv: "T", minutesAgo: 1)
        let s = store([a, b])
        s.selectedMailbox = .account(work.id, .trash)
        #expect(s.conversationRow(b.id)?.count == 2)
        s.selection = [b.id]
        s.deleteSelection()
        #expect(s.messages.isEmpty)
    }

    @Test func sendersAreFirstNamesNewestFirst() {
        let names = [Contact(name: "Jan Jikeli", email: "j@x"), Contact(name: "Sergio Lerena", email: "s@x"),
                     Contact(name: "Jan Jikeli", email: "j@x"), Contact(name: "Gartner, Till", email: "t@x"),
                     Contact(name: "", email: "bob@x.com")]
        #expect(ConversationRow.senders(names.prefix(1)) == "Jan Jikeli")  // one sender: the full name, as on a single message
        #expect(ConversationRow.senders([names[0], names[2]]) == "Jan Jikeli")
        #expect(ConversationRow.senders(names.prefix(3)) == "Jan & Sergio")
        #expect(ConversationRow.senders(names) == "Jan, Sergio, Till & bob@x.com")
    }

    /// BUG-156: a display name made only of commas ("Last, First" with both empty) crashed the row; it shows the address.
    @Test func commaOnlySenderNameShowsTheAddress() async {
        await #expect(processExitsWith: .success) {
            let names = [Contact(name: ", ", email: "a@x.com"), Contact(name: ",", email: "c@x.com"),
                         Contact(name: "Bob Ray", email: "b@x.com")]
            guard ConversationRow.senders(names) == "a@x.com, c@x.com & Bob" else { exit(1) }
        }
    }
}
