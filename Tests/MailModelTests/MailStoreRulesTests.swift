import Foundation
import Testing
@testable import MailModel

/// Store rules for refused changes, multi-selection actions, Trash, replies, drafts and search.
@MainActor
struct MailStoreRulesTests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")

    func msg(_ acct: Account, _ box: MailboxKind = .inbox, subject: String = "Hi", from: String = "Ann",
             body: String? = nil, to: [Contact]? = nil, cc: [Contact] = [], read: Bool = false,
             minutesAgo: Double = 0, flag: FlagColor? = nil, rid: String? = nil, conv: String? = nil) -> Message {
        var m = Message(accountID: acct.id, mailbox: box, from: Contact(name: from, email: "\(from.lowercased())@x.com"),
                        to: to ?? [Contact(name: "Me", email: acct.address)], cc: cc, subject: subject,
                        body: body ?? "Body of \(subject)", date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60),
                        isRead: read, flag: flag, remoteID: rid)
        m.conversationID = conv
        return m
    }

    func store(_ msgs: [Message]) -> MailStore { MailStore(accounts: [work, home], messages: msgs) }

    // MARK: Refused changes

    /// A refused read change undoes only the read state: a later move still queued stays.
    @Test func refusedReadChangeDoesNotUndoALaterMove() {
        let m = msg(work, rid: "R")
        let s = store([m])
        s.toggleRead([m.id])
        s.move([m.id], to: .archive)
        #expect(s.outbox.count == 2)
        s.failed(s.outbox[0], "refused")
        #expect(s.message(m.id)?.isRead == false)
        #expect(s.message(m.id)?.mailbox == .archive, "the move is still queued for the server")
    }

    /// A refused move doesn't bring back a message erased afterwards.
    @Test func refusedMoveDoesNotResurrectAnErasedMessage() {
        let m = msg(work, rid: "R")
        let s = store([m])
        s.archive([m.id])
        s.delete([m.id])
        s.delete([m.id])
        #expect(s.message(m.id) == nil)
        s.failed(s.outbox[0], "refused")
        #expect(s.message(m.id) == nil, "erased message is back while its delete is still queued")
    }

    /// A refused flag change leaves a later read change alone, and a value changed again since isn't overwritten.
    @Test func refusedChangeRestoresOnlyItsOwnUnchangedProperty() {
        let m = msg(work, rid: "R")
        let s = store([m])
        s.setFlag(.red, for: [m.id])
        s.toggleRead([m.id])
        s.archive([m.id])
        s.move([m.id], to: .junk)
        s.failed(s.outbox[0], "refused")  // the flag
        #expect(s.message(m.id)?.flag == nil)
        #expect(s.message(m.id)?.isRead == true)
        s.failed(s.outbox[1], "refused")  // the move to Archive: since moved on to Junk
        #expect(s.message(m.id)?.mailbox == .junk)
    }

    // MARK: Multi-selection actions

    /// Move to Junk on a mixed selection moves all of it to Junk; only an all-Junk selection goes back to the Inbox.
    @Test func junkOnMixedSelectionMovesAllToJunk() {
        let a = msg(work, .junk, subject: "a", flag: .red), b = msg(work, subject: "b", flag: .red)
        let s = store([a, b])
        s.toggleJunk([a.id, b.id])
        #expect(s.message(a.id)?.mailbox == .junk)
        #expect(s.message(b.id)?.mailbox == .junk)
        s.toggleJunk([a.id, b.id])
        #expect(s.message(a.id)?.mailbox == .inbox)
        #expect(s.message(b.id)?.mailbox == .inbox)
    }
}
