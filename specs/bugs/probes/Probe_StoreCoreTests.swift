import Foundation
import Testing
@testable import MailModel

@MainActor
struct Probe_StoreCoreTests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")

    func msg(_ acct: Account, _ box: MailboxKind = .inbox, subject: String = "Hi", from: String = "Ann",
             read: Bool = false, minutesAgo: Double = 0, flag: FlagColor? = nil, rid: String? = nil,
             conv: String? = nil) -> Message {
        var m = Message(accountID: acct.id, mailbox: box, from: Contact(name: from, email: "\(from.lowercased())@x.com"),
                        to: [Contact(name: "Me", email: acct.address)], subject: subject, body: "Body of \(subject)",
                        date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60), isRead: read, flag: flag,
                        remoteID: rid)
        m.conversationID = conv
        return m
    }

    func store(_ msgs: [Message]) -> MailStore { MailStore(accounts: [work, home], messages: msgs) }

    // 6. Next selection: deleting the last row selects the one above.
    @Test func deletingTheLastRowSelectsThePrevious() {
        let a = msg(work, subject: "a", minutesAgo: 1), b = msg(work, subject: "b", minutesAgo: 2)
        let s = store([a, b])
        s.selectedMailbox = .account(work.id, .inbox)
        s.selection = [b.id]
        s.deleteSelection()
        #expect(s.selection == [a.id])
    }

    // 7. Non-contiguous multi-selection: the message after the last selected one.
    @Test func deletingANonContiguousSelectionSelectsTheNext() {
        let ms = (0..<5).map { msg(work, subject: "\($0)", minutesAgo: Double($0)) }
        let s = store(ms)
        s.selectedMailbox = .account(work.id, .inbox)
        s.selection = [ms[0].id, ms[2].id]
        s.deleteSelection()
        #expect(s.selection == [ms[3].id])
    }

    // 3'. An action that changes nothing (Archive while viewing Archive) must not move the selection.
    @Test func archivingInArchiveKeepsTheSelection() {
        let a = msg(work, .archive, subject: "a", minutesAgo: 1), b = msg(work, .archive, subject: "b", minutesAgo: 2)
        let s = store([a, b])
        s.selectedMailbox = .account(work.id, .archive)
        s.selection = [a.id]
        s.archiveSelection()
        #expect(s.message(a.id)?.mailbox == .archive)
        #expect(s.selection == [a.id])
    }

    // 9. drop returns false when nothing changed (doc comment): flagged message in Trash dropped on Flagged.
    @Test func dropOnFlaggedOfAnAlreadyFlaggedTrashMessageChangesNothing() {
        let a = msg(work, .trash, flag: .blue)
        let s = store([a])
        let r = s.drop([a.id], on: .smart(.flagged))
        #expect(s.message(a.id)?.flag == .blue && s.message(a.id)?.mailbox == .trash)
        #expect(!r, "drop reported a change although the message is unchanged")
    }

    // 10. Mixed drop of the selection where a server message is blocked: it stays put, so it should stay selected.
    @Test func blockedMessagesOfADroppedSelectionStaySelected() {
        let local = msg(work, subject: "local", minutesAgo: 1), remote = msg(work, subject: "remote", minutesAgo: 2, rid: "R"),
            other = msg(work, subject: "other", minutesAgo: 3)
        let s = store([local, remote, other])
        s.selectedMailbox = .account(work.id, .inbox)
        s.selection = [local.id, remote.id]
        #expect(s.drop([local.id, remote.id], on: .account(home.id, .inbox)))
        #expect(s.message(remote.id)?.accountID == work.id)
        #expect(s.message(remote.id)?.mailbox == .inbox)
        #expect(s.selection.contains(remote.id) || s.selection == [other.id])
    }

    // 14. Counts match the mailbox rules for custom folders, thousands of interleaved messages, both accounts.
    @Test func countsMatchRulesForFoldersAndInterleavedMail() {
        let boxes: [MailboxKind] = MailboxKind.allCases + (0..<7).map { .folder("F\($0)") }
        var msgs: [Message] = []
        for i in 0..<5000 {
            var m = msg(i % 3 == 0 ? home : work, boxes[(i * 7) % boxes.count], subject: "\(i)", read: i % 4 == 0,
                        minutesAgo: Double(i % 97), flag: i % 5 == 0 ? FlagColor.allCases[i % 7] : nil)
            m.isVIP = i % 11 == 0
            msgs.append(m)
        }
        let s = store(msgs)
        let refs: [MailboxRef] = SmartMailbox.allCases.map { .smart($0) }
            + [work, home].flatMap { a in boxes.map { .account(a.id, $0) } }
        for r in refs {
            #expect(s.count(r) == s.messages.filter { s.contains(r, $0) }.count)
            #expect(s.unreadCount(r) == s.messages.filter { !$0.isRead && s.contains(r, $0) }.count)
            s.selectedMailbox = r
            #expect(s.visibleMessages.count == s.count(r))
        }
        s.markAllRead(in: .smart(.allInboxes))
        #expect(s.unreadCount(.smart(.allInboxes)) == 0)
        #expect(s.unreadCount(.smart(.unread)) == 0)
    }

    // 15. The list after a toggle keeps equal-date messages in a stable order.
    @Test func equalDatesKeepAStableOrderAcrossChanges() {
        let ms = (0..<50).map { msg(work, subject: "\($0)", minutesAgo: 5) }
        let s = store(ms)
        s.selectedMailbox = .account(work.id, .inbox)
        let before = s.visibleMessages.map(\.id)
        s.toggleRead([ms[10].id])
        #expect(s.visibleMessages.map(\.id) == before)
    }

    // MARK: Big mailboxes (same shape as MailStorePerformanceTests: ≈70k messages)

    func bigStore(unread: Bool = false) -> MailStore {
        let boxes: [(MailboxKind, Int)] = [(.inbox, 2_900), (.drafts, 300), (.sent, 54_000), (.trash, 11_800), (.archive, 30)]
        var msgs: [Message] = []
        var n = 0
        for (box, count) in boxes {
            for _ in 0..<count {
                n += 1
                msgs.append(Message(accountID: work.id, mailbox: box, from: Contact(name: "S\(n % 500)", email: "s\(n % 500)@x.com"),
                                    to: [], subject: "Subject \(n)", body: "", date: Date(timeIntervalSince1970: Double(n * 60)),
                                    isRead: unread ? false : n % 30 != 0, remoteID: "R\(n)", bodyLoaded: false))
            }
        }
        return MailStore(accounts: [work], messages: msgs)
    }

    func time(_ f: () -> Void) -> Double { let t = Date(); f(); return Date().timeIntervalSince(t) }

    @Test func markAllReadOnABigMailboxIsQuick() {
        let s = bigStore(unread: true)
        let t = time { s.markAllRead(in: .account(work.id, .sent)) }
        print("PROBE markAllRead 54k:", t)
        #expect(t < 5.0)
    }

    @Test func deletingAllOfABigTrashIsQuick() {
        let s = bigStore()
        s.selectedMailbox = .account(work.id, .trash)
        s.selection = Set(s.visibleMessages.map(\.id))
        let t = time { s.deleteSelection() }
        print("PROBE erase 11.8k trash:", t)
        #expect(t < 5.0)
        #expect(s.count(.account(work.id, .trash)) == 0)
    }

    @Test func movingABigSelectionIsQuick() {
        let s = bigStore()
        s.selectedMailbox = .account(work.id, .sent)
        s.selection = Set(s.visibleMessages.prefix(20_000).map(\.id))
        let t = time { s.drop(s.selection, on: .account(work.id, .archive)) }
        print("PROBE drop 20k:", t)
        #expect(t < 5.0)
    }

    @Test func togglingReadOnABigSelectionIsQuick() {
        let s = bigStore()
        let ids = Set(s.messages.filter { $0.mailbox == .sent }.map(\.id))
        let t = time { s.toggleRead(ids) }
        print("PROBE toggleRead 54k:", t)
        #expect(t < 5.0)
    }
}
