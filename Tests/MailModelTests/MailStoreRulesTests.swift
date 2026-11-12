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

    // MARK: Folders inside Trash

    /// Exchange keeps a deleted folder (and its subfolders) inside Deleted Items: its mail counts as Trash.
    func trashTree(_ s: MailStore) {
        s.setFolders([Folder(box: .folder("D"), name: "Old", parent: .trash),
                      Folder(box: .folder("E"), name: "Older", parent: .folder("D")),
                      Folder(box: .folder("K"), name: "Kept", parent: nil)], account: work.id)
    }

    @Test func conversationLeavesOutTrashSubfolders() {
        let a = msg(work, subject: "a", minutesAgo: 1, rid: "1", conv: "C"),
            b = msg(work, .folder("D"), subject: "b", minutesAgo: 2, rid: "2", conv: "C"),
            c = msg(work, .folder("E"), subject: "c", minutesAgo: 3, rid: "3", conv: "C"),
            k = msg(work, .folder("K"), subject: "k", minutesAgo: 4, rid: "4", conv: "C")
        let s = store([a, b, c, k])
        trashTree(s)
        #expect(s.conversation(of: a.id).map(\.id) == [a.id, k.id])
    }

    @Test func flaggedLeavesOutTrashSubfolders() {
        let a = msg(work, .folder("D"), subject: "a", flag: .red), b = msg(work, .folder("E"), subject: "b", flag: .red),
            k = msg(work, .folder("K"), subject: "k", flag: .red)
        let s = store([a, b, k])
        #expect(s.count(.smart(.flagged)) == 3)  // read before the folders are known: the cache must not stick
        trashTree(s)
        #expect(s.count(.smart(.flagged)) == 1)
        s.selectedMailbox = .smart(.flagged)
        #expect(s.visibleMessages.map(\.subject) == ["k"])
    }

    @Test func searchLeavesOutTrashSubfolders() async throws {
        let a = msg(work, .folder("D"), subject: "Report a"), b = msg(work, .folder("E"), subject: "Report b"),
            k = msg(work, .folder("K"), subject: "Report k")
        let s = store([a, b, k])
        trashTree(s)
        s.searchText = "report"
        #expect(s.visibleMessages.map(\.subject) == ["Report k"])  // memory
        s.searchDebounce = .zero
        s.searcher = { _, _ in [a.id, b.id, k.id] }
        await s.searchTask?.value
        #expect(s.searchHits?.query == "report")
        #expect(s.visibleMessages.map(\.subject) == ["Report k"])  // index hits, checked against memory
    }

    // MARK: Replies

    /// Reply All names each address once, whatever its case; the first occurrence is kept.
    @Test func replyAllHasNoDuplicateRecipients() {
        let m = msg(work, from: "Ann", to: [Contact(name: "Me", email: "me@work.com"), Contact(name: "Bo", email: "bo@x.com")],
                    cc: [Contact(name: "Ann", email: "ann@x.com"), Contact(name: "Bo", email: "BO@x.com")])
        let s = store([m])
        let d = s.draft(.replyAll, to: m.id)
        let emails = Contact.parseList(d.to + "," + d.cc).map(\.email)
        #expect(emails == ["ann@x.com", "bo@x.com"], "to: \(d.to) cc: \(d.cc)")
    }

    /// Reply All: sender and To go to To, the original Cc stays in Cc; my own address is in neither.
    @Test func replyAllKeepsOriginalCcInCc() {
        let m = msg(work, from: "Ann", to: [Contact(name: "Me", email: "me@work.com"), Contact(name: "Bo", email: "bo@x.com")],
                    cc: [Contact(name: "Carl", email: "carl@x.com"), Contact(name: "Me", email: "ME@work.com"),
                         Contact(name: "Bo", email: "Bo@x.com")])
        let s = store([m])
        let d = s.draft(.replyAll, to: m.id)
        #expect(d.to == "ann@x.com, bo@x.com", "to: \(d.to)")
        #expect(d.cc == "carl@x.com", "cc: \(d.cc)")
    }

    /// An existing reply or forward prefix is recognised in any case, with or without a space, also Outlook's
    /// German AW: and WG:; it becomes "Re: " or "Fwd: " instead of getting a second one.
    @Test func replyAndForwardPrefixesAreNormalisedNotStacked() {
        func subject(_ kind: ReplyKind, _ original: String) -> String {
            let m = msg(work, subject: original)
            return store([m]).draft(kind, to: m.id).subject
        }
        for re in ["Re: Plans", "RE: Plans", "re: Plans", "Re:Plans", "AW: Plans", "aw:Plans", "Plans"] {
            #expect(subject(.reply, re) == "Re: Plans", "\(re)")
            #expect(subject(.replyAll, re) == "Re: Plans", "\(re)")
        }
        for fwd in ["Fwd: Plans", "FWD: Plans", "fwd:Plans", "Fw: Plans", "FW: Plans", "WG: Plans", "wg:Plans", "Plans"] {
            #expect(subject(.forward, fwd) == "Fwd: Plans", "\(fwd)")
        }
        // A prefix of the other kind stays; words that only start like one aren't prefixes.
        #expect(subject(.reply, "FW: Plans") == "Re: FW: Plans")
        #expect(subject(.forward, "RE: Plans") == "Fwd: RE: Plans")
        #expect(subject(.reply, "Report: Q3") == "Re: Report: Q3")
        #expect(subject(.forward, "Fwiw: hi") == "Fwd: Fwiw: hi")
    }

    /// Reply to a message I sent goes to its recipients, as in Mail.
    @Test func replyToOwnSentMessageGoesToRecipients() {
        let m = Message(accountID: work.id, mailbox: .sent, from: Contact(name: "Me", email: "Me@Work.com"),
                        to: [Contact(name: "Bo", email: "bo@x.com"), Contact(name: "Cy", email: "cy@x.com")],
                        cc: [Contact(name: "Di", email: "di@x.com")], subject: "Plans", body: "x", date: .now)
        let s = store([m])
        let d = s.draft(.reply, to: m.id)
        #expect(d.to == "bo@x.com, cy@x.com", "to: \(d.to)")
        #expect(d.cc == "")
    }

    // MARK: Drafts

    /// Save Draft without a server keeps what was typed in Cc.
    @Test func localSaveDraftKeepsCc() {
        let s = store([])
        s.saveDraft(Draft(accountID: work.id, to: "a@x.com", cc: "c@x.com, Di <d@x.com>", subject: "S", body: "B"))
        let d = s.messages.first { $0.mailbox == .drafts }
        #expect(d?.cc.map(\.email) == ["c@x.com", "d@x.com"])
    }

    // MARK: Search

    final class Fail: @unchecked Sendable { var on = true }

    /// "Search failed" goes when the search is cleared.
    @Test func searchFailedNoticeGoesWhenSearchCleared() async {
        let s = store([msg(work, subject: "Lunch")])
        s.searchDebounce = .zero
        s.searcher = { _, _ in throw DatabaseError(errorDescription: "broken") }
        s.searchText = "lun"
        await s.searchTask?.value
        #expect(s.status?.contains("broken") == true)
        s.searchText = ""
        #expect(s.status == nil, "status: \(String(describing: s.status))")
    }

    /// "Search failed" goes once the next search succeeds; another notice set meanwhile stays.
    @Test func searchFailedNoticeGoesAfterNextSuccess() async {
        let m = msg(work, subject: "Lunch")
        let s = store([m])
        s.searchDebounce = .zero
        let fail = Fail()
        s.searcher = { _, _ in if fail.on { throw DatabaseError(errorDescription: "broken") }; return [m.id] }
        s.searchText = "lun"
        await s.searchTask?.value
        fail.on = false
        s.searchText = "lunch"
        await s.searchTask?.value
        #expect(s.searchHits?.query == "lunch")
        #expect(s.status == nil, "status: \(String(describing: s.status))")
        s.status = "Offline"
        s.searchText = "lunc"
        await s.searchTask?.value
        s.searchText = ""
        #expect(s.status == "Offline")
    }
}
