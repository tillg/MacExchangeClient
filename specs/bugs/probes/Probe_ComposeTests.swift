import Foundation
import Testing
import WebKit
@testable import EWS
@testable import MailModel

/// Renders HTML in a real WKWebView and runs a script (same approach as Probe_Model2Tests' harness).
@MainActor
enum ComposeRender {
    static func eval(_ page: String, _ script: String, width: CGFloat = 600, timeout: TimeInterval = 30) async -> Any? {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let v = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 400), configuration: config)
        v.loadHTMLString(page, baseURL: nil)
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(200))
        while v.isLoading && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return try? await v.evaluateJavaScript(script)
    }
}

struct ComposeRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@MainActor
struct Probe_ComposeTests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")
    let mark = String(Draft.fileMark)

    func msg(_ acct: Account, _ box: MailboxKind = .inbox, subject: String = "Hi", from: Contact? = nil,
             to: [Contact]? = nil, cc: [Contact] = [], body: String = "Body") -> Message {
        Message(accountID: acct.id, mailbox: box, from: from ?? Contact(name: "Ann", email: "ann@x.com"),
                to: to ?? [Contact(name: "Me", email: acct.address)], cc: cc, subject: subject, body: body,
                date: Date(timeIntervalSince1970: 1_000_000))
    }

    func store(_ msgs: [Message]) -> MailStore { MailStore(accounts: [work, home], messages: msgs) }

    func png(_ name: String, _ bytes: Int = 4) -> DraftAttachment {
        DraftAttachment(name: name, contentType: "image/png", data: Data(repeating: 7, count: bytes))
    }

    // MARK: File marks and grapheme clusters

    // MARK: Draft.html in WebKit

    /// Property: what WebKit shows of Draft.html is the text that was typed (for text without the known
    /// whitespace-collapsing cases: runs of spaces, tabs, CR, leading/trailing blanks).
    @Test func htmlRendersTypedTextRandom() async throws {
        var rng = ComposeRNG(state: 7)
        let words = ["Hello", "<b>bold</b>", "a & b", "\"quoted\"", "'single'", "https://example.com/a?b=1&c=2#x",
                     "😀👍🏽", "مرحبا", "שלום", "日本語", "e\u{0301}", "x<y>z", "&amp;", "&lt;tag&gt;", "]]>", "<!-- c -->",
                     "<script>x</script>", "100%", "C:\\path\\file", "`code`", String(repeating: "W", count: 300)]
        var mismatches: [String] = []
        for _ in 0..<40 {
            var lines: [String] = []
            for _ in 0..<Int.random(in: 1..<6, using: &rng) {
                let n = Int.random(in: 0..<5, using: &rng)
                lines.append((0..<n).map { _ in words.randomElement(using: &rng)! }.joined(separator: " "))
            }
            let text = lines.joined(separator: "\n")
            let d = Draft(accountID: work.id, body: text)
            let shown = try #require(await ComposeRender.eval(d.html { _ in nil }, "document.body.innerText") as? String)
            let norm = { (s: String) in s.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .newlines) }
            if norm(shown) != norm(text) { mismatches.append("typed: \(text.debugDescription)\nshown: \(shown.debugDescription)") }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches, first:\n\(mismatches.first ?? "")")
    }

    /// A long URL or word wraps instead of making the mail wider than the window.
    @Test func htmlLongLineWraps() async throws {
        let d = Draft(accountID: work.id, body: "https://example.com/" + String(repeating: "abcdefghij", count: 200))
        let r = try #require(await ComposeRender.eval(d.html { _ in nil },
            "[document.documentElement.scrollWidth, window.innerWidth].join('|')", width: 400) as? String)
        let p = r.split(separator: "|").compactMap { Int($0) }
        #expect(p.count == 2 && p[0] <= p[1], "scrollWidth|innerWidth = \(r)")
    }

    /// Placed pictures appear in the HTML in the order and place of their marks.
    @Test func htmlPicturesFollowMarksRandom() async throws {
        var rng = ComposeRNG(state: 99)
        var bad: [String] = []
        for _ in 0..<15 {
            var body = "", files: [DraftAttachment] = []
            for i in 0..<Int.random(in: 1..<8, using: &rng) {
                body += ["t\(i) ", "\n", mark, mark].randomElement(using: &rng)!
                if body.last == Draft.fileMark && files.count < body.filter({ $0 == Draft.fileMark }).count {
                    files.append(Bool.random(using: &rng) ? png("p\(files.count).png")
                                 : DraftAttachment(name: "f\(files.count).pdf", contentType: "application/pdf", data: Data([1])))
                }
            }
            var d = Draft(accountID: work.id, body: body)
            d.attachments = files
            let ids = EWSBackend.contentIDs(d)
            let shown = try #require(await ComposeRender.eval(d.html { ids[$0] },
                "Array.from(document.images).map(i => i.alt).join(',')") as? String)
            let want = d.placedPictures.map { d.attachments[$0].name }.joined(separator: ",")
            if shown != want { bad.append("body \(body.debugDescription): shown \(shown) want \(want)") }
        }
        #expect(bad.isEmpty, "\(bad)")
    }

    // MARK: Size

    /// Base64 with a CRLF every 76 characters: the per-file estimate is never below the encoded size, for any length.
    @Test func attachmentEstimateNeverBelowBase64() {
        for n in [0, 1, 2, 3, 56, 57, 58, 76, 100, 1_000, 4_096, 99_999, 1_000_000] {
            let a = DraftAttachment(name: "f.bin", contentType: nil, data: Data(repeating: 1, count: n))
            let real = a.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]).utf8.count
            #expect(Draft.encodedSize(a) >= real, "n=\(n): estimate \(Draft.encodedSize(a)) < \(real)")
        }
    }

    // MARK: Save / send without a server and while files load

    /// README: "Changes to Exchange mail show at once and are then written to the server … Send and Save Draft."
    @Test func savedDraftOnExchangeShowsAtOnce() {
        let s = store([])
        s.merge([(.inbox, [])], account: work.id)  // the work account is a server account
        s.saveDraft(Draft(accountID: work.id, to: "bo@x.com", subject: "Plan", body: "Draft text"))
        #expect(s.messages.contains { $0.mailbox == .drafts && $0.subject == "Plan" },
                "drafts in the list: \(s.messages.filter { $0.mailbox == .drafts }.count), outbox: \(s.outbox.count)")
    }

    @Test func sentMessageOnExchangeShowsAtOnce() {
        let s = store([])
        s.merge([(.inbox, [])], account: work.id)
        s.send(Draft(accountID: work.id, to: "bo@x.com", subject: "Hello", body: "Text"))
        #expect(s.messages.contains { $0.mailbox == .sent && $0.subject == "Hello" },
                "sent in the list: \(s.messages.filter { $0.mailbox == .sent }.count), outbox: \(s.outbox.count)")
    }

    /// Local send then local save: a sent picture message keeps its place info (control, not filed separately).
    @Test func localSendKeepsFilesOpenable() async {
        let s = store([])
        s.downloadsFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ProbeCompose-\(UUID())")
        var d = Draft(accountID: home.id, to: "bo@x.com", subject: "Pic", body: "see \(mark)")
        d.attachments = [png("p.png", 10)]
        s.send(d)
        let sent = s.messages.first { $0.mailbox == .sent }
        #expect(sent != nil)
        if let sent { #expect(await s.attachmentFile(0, of: sent.id) != nil) }
    }

    // MARK: Header formats

    // MARK: Compose windows

    // MARK: Include attachments / new recipients (controls and edge cases)

    @Test func addsNewRecipientIgnoresKnownAddressWithDifferentCaseAndSpaces() {
        var m = msg(work, from: Contact(name: "Ann", email: "Ann@X.com"))
        m.attachments = ["a.pdf"]
        let s = store([m])
        var d = s.draft(.reply, to: m.id)
        d.to = " ann@x.COM ; "
        #expect(s.addsNewRecipient(d) == false)
        d.cc = "Neu <neu@y.com>"
        #expect(s.addsNewRecipient(d) == true)
    }

    @Test func hasChangesIgnoresOriginalFilesArriving() async {
        var m = msg(home, subject: "Files")
        m.attachments = ["a.pdf"]
        let s = store([m])
        s.downloadsFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ProbeCompose-\(UUID())")
        s.setAttachmentData([Data([1, 2, 3])], for: m.id)
        var d = s.draft(.forward, to: m.id)
        let start = d
        await s.includeOriginalAttachments(in: &d)
        #expect(d.attachments.count == 1)
        #expect(!d.hasChanges(since: start))
        d.excludeOriginalAttachments()
        #expect(!d.hasChanges(since: start))
    }
}
