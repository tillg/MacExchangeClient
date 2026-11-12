import Foundation
import Testing
@testable import MailModel

@MainActor
struct Probe_StoreFlowsTests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")

    func msg(_ acct: Account, _ box: MailboxKind = .inbox, subject: String = "Hi", from: String = "Ann",
             body: String? = nil, to: [Contact]? = nil, cc: [Contact] = [], minutesAgo: Double = 0) -> Message {
        Message(accountID: acct.id, mailbox: box, from: Contact(name: from, email: "\(from.lowercased())@x.com"),
                to: to ?? [Contact(name: "Me", email: acct.address)], cc: cc, subject: subject,
                body: body ?? "Body of \(subject)", date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60))
    }

    func store(_ msgs: [Message]) -> MailStore { MailStore(accounts: [work, home], messages: msgs) }

    // MARK: Reply / forward

    @Test func probe_draftForUnknownMessageWithoutAccountsDoesNotCrash() {
        // Only checks that a missing message gives an empty draft for an existing account.
        let s = store([])
        let d = s.draft(.reply, to: UUID())
        #expect(d.to.isEmpty)
    }

    // MARK: Sending / drafts without a backend

    @Test func probe_localSendEmptySubjectShowsNoSubject() {
        let s = store([])
        s.send(Draft(accountID: work.id, to: "a@x.com", subject: "", body: "B"))
        let m = s.messages.first { $0.mailbox == .sent }
        #expect(m?.subject == "(No Subject)", "subject: \(String(describing: m?.subject))")
    }

    @Test func probe_localSendStripsFileMarks() {
        let s = store([])
        var d = Draft(accountID: work.id, to: "a@x.com", subject: "S", body: "a\u{FFFC}b")
        d.attachments = [DraftAttachment(name: "p.png", contentType: "image/png", data: Data([1]))]
        s.send(d)
        let m = s.messages.first { $0.mailbox == .sent }
        #expect(m?.body == "ab")
    }

    // MARK: Search (memory)

    @Test func probe_memorySearchMatchesEveryWordAnywhere() {
        let s = store([msg(work, subject: "Review of the budget")])
        s.searchText = "budget review"
        #expect(s.visibleMessages.count == 1)
    }

    @Test func probe_memorySearchIgnoresAccents() {
        let s = store([msg(work, subject: "Hi", from: "Müller")])
        s.searchText = "muller"
        #expect(s.visibleMessages.count == 1)
    }

    @Test func probe_memorySearchFindsRecipients() {
        let s = store([msg(work, subject: "Hi", to: [Contact(name: "Zoe Quill", email: "zoe@q.com")])])
        s.searchText = "quill"
        #expect(s.visibleMessages.count == 1)
    }

    @Test func probe_memorySearchFindsServerPreviewOfUnloadedBody() {
        var m = msg(work, subject: "Hi", body: "")
        m.bodyLoaded = false
        m.serverPreview = "the quarterly forecast"
        m.remoteID = "r1"
        let s = store([m])
        s.searchText = "forecast"
        #expect(s.visibleMessages.count == 1)
    }

    @Test func probe_searchWithUnreadFilterKeepsCountOfMatches() {
        // Not a claim, just a data point.
        let s = store([msg(work, subject: "Lunch")])
        s.filterUnread = true
        s.searchText = "lunch"
        #expect(s.visibleMessages.count == 1)
    }

    // MARK: Attachments

    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ProbeStoreFlows-\(UUID())")
    }

    @Test func probe_attachmentTraversalStaysInFolder() async throws {
        var m = msg(work)
        m.attachments = [Attachment(name: "../../evil.sh"), Attachment(name: ".."), Attachment(name: "a\\..\\b")]
        let s = store([m])
        let dl = tempDir()
        s.downloadsFolder = dl
        s.setAttachmentData([Data("1".utf8), Data("2".utf8), Data("3".utf8)], for: m.id)
        for i in 0..<3 {
            let url = try #require(await s.attachmentFile(i, of: m.id))
            #expect(url.standardizedFileURL.path.hasPrefix(dl.appendingPathComponent(m.id.uuidString).path), "\(url.path)")
        }
    }

    @Test func probe_saveDotFileTwiceKeepsName() async throws {
        let folder = tempDir()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent(".env"))
        let u = MailStore.freeURL(for: ".env", in: folder)
        #expect(u.lastPathComponent == ".env 2", "\(u.lastPathComponent)")
    }

    @Test func probe_saveAttachmentTwiceGivesSecondName() async throws {
        var m = msg(work)
        m.attachments = [Attachment(name: "Ünïcødé 📎.pdf")]
        let s = store([m])
        s.downloadsFolder = tempDir()
        s.setAttachmentData([Data("x".utf8)], for: m.id)
        let folder = tempDir()
        let a = try #require(await s.saveAttachment(0, of: m.id, to: folder))
        let b = try #require(await s.saveAttachment(0, of: m.id, to: folder))
        #expect(a.lastPathComponent == "Ünïcødé 📎.pdf")
        #expect(b.lastPathComponent == "Ünïcødé 📎 2.pdf")
    }

    @Test func probe_forwardIncludesAttachmentsWithSameName() async {
        var m = msg(work)
        m.attachments = [Attachment(name: "a.txt"), Attachment(name: "a.txt")]
        let s = store([m])
        s.downloadsFolder = tempDir()
        s.setAttachmentData([Data("1".utf8), Data("2".utf8)], for: m.id)
        var d = s.draft(.forward, to: m.id)
        await s.includeOriginalAttachments(in: &d)
        #expect(d.attachments.map(\.data) == [Data("1".utf8), Data("2".utf8)])
    }

    // MARK: Invites

    // MARK: WhatsNew

    @Test func probe_whatsNewFeaturesAreUniqueAndNonEmpty() {
        let all = WhatsNew.days.flatMap(\.features)
        #expect(all.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        #expect(Set(all).count == all.count)
        let banned = ["EWS", "SQLite", "FTS", "cid", "cache", "JSON"]
        for f in all {
            let words = Set(f.components(separatedBy: CharacterSet.alphanumerics.inverted).map { $0.lowercased() })
            for b in banned { #expect(!words.contains(b.lowercased()), "\(f)") }
        }
    }

    // MARK: Batch 2

    @Test func probe_searchFailedNoticeGoesWhenSearchCleared() async {
        let s = store([msg(work, subject: "Lunch")])
        s.searchDebounce = .zero
        s.searcher = { _, _ in throw DatabaseError(errorDescription: "broken") }
        s.searchText = "lun"
        await s.searchTask?.value
        #expect(s.status?.contains("broken") == true)
        s.searchText = ""
        #expect(s.status == nil, "status: \(String(describing: s.status))")
    }

    @Test func probe_searchFailedNoticeGoesAfterNextSuccess() async {
        let m = msg(work, subject: "Lunch")
        let s = store([m])
        s.searchDebounce = .zero
        let fail = Fail()
        s.searcher = { q, _ in if fail.on { throw DatabaseError(errorDescription: "broken") }; return [m.id] }
        fail.on = true
        s.searchText = "lun"
        await s.searchTask?.value
        fail.on = false
        s.searchText = "lunch"
        await s.searchTask?.value
        #expect(s.searchHits?.query == "lunch")
        #expect(s.status == nil, "status: \(String(describing: s.status))")
    }

    final class Fail: @unchecked Sendable { var on = false }

    @Test func probe_saveAllAttachmentsSameNames() async throws {
        var m = msg(work)
        m.attachments = [Attachment(name: "scan.pdf"), Attachment(name: "scan.pdf"), Attachment(name: "scan.pdf")]
        let s = store([m])
        s.downloadsFolder = tempDir()
        s.setAttachmentData([Data("1".utf8), Data("2".utf8), Data("3".utf8)], for: m.id)
        let saved = await s.saveAllAttachments(of: m.id, to: tempDir())
        #expect(saved.map(\.lastPathComponent) == ["scan.pdf", "scan 2.pdf", "scan 3.pdf"])
        #expect(try saved.map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) } == ["1", "2", "3"])
    }

    @Test func probe_attachFolderZipsIt() throws {
        let dir = tempDir().appendingPathComponent("Prüfung 📁")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: dir.appendingPathComponent("a.txt"))
        let s = store([])
        let files = s.files([dir])
        #expect(files.map(\.name) == ["Prüfung 📁.zip"])
        #expect(files.first?.data.prefix(2) == Data("PK".utf8))
    }

    @Test func probe_replyAllFromSentMessageGoesToRecipients() {
        let m = Message(accountID: work.id, mailbox: .sent, from: Contact(name: "Me", email: "me@work.com"),
                        to: [Contact(name: "Bo", email: "bo@x.com")], cc: [Contact(name: "Cy", email: "cy@x.com")],
                        subject: "Plans", body: "x", date: .now)
        let s = store([m])
        let d = s.draft(.replyAll, to: m.id)
        let all = Contact.parseList(d.to + "," + d.cc).map(\.email)
        #expect(Set(all) == ["bo@x.com", "cy@x.com"], "\(d.to) | \(d.cc)")
    }

    @Test func probe_replyAllUsesAccountOfMessageForSelf() {
        // Message in iCloud account that also lists the Work address: Work address stays (another of my accounts) - data point.
        let m = msg(home, to: [Contact(name: "Me", email: "me@icloud.com"), Contact(name: "W", email: "me@work.com")])
        let s = store([m])
        let d = s.draft(.replyAll, to: m.id)
        #expect(!d.to.contains("me@icloud.com"))
    }

    @Test func probe_forwardHasNoRecipientsAndKeepsAccount() {
        let m = msg(home)
        let s = store([m])
        let d = s.draft(.forward, to: m.id)
        #expect(d.to.isEmpty && d.accountID == home.id)
    }

}
