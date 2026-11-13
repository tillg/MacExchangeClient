import Foundation
import Testing
@testable import MailModel

/// `Message`'s derived values.
struct MessageTests {
    func message(_ body: String) -> Message {
        Message(accountID: UUID(), from: Contact(name: "A", email: "a@x"), to: [], subject: "S", body: body, date: .now)
    }

    /// The list reads the preview on every render: a long mail must not make it slow, and only the start is shown.
    @Test func previewOfAHugeBodyIsFastAndShort() {
        let m = message("> quoted\n" + String(repeating: "Lorem ipsum dolor sit amet\n", count: 40_000))  // ~1 MB
        let t = Date()
        for _ in 0..<10 { _ = m.preview }
        let per = Date().timeIntervalSince(t) / 10
        #expect(per < 0.05, "preview took \(per * 1000) ms per call")
        #expect(m.preview.hasPrefix("Lorem ipsum dolor sit amet Lorem ipsum"))
        #expect(m.preview.count <= 500)
        // One endless line, too.
        let line = message(String(repeating: "x", count: 1_000_000))
        let t2 = Date()
        #expect(line.preview.count <= 500)
        #expect(Date().timeIntervalSince(t2) < 0.05)
    }

    @Test func previewOfAShortBodyIsTheWholeBodyWithoutQuotes() {
        #expect(message("Hi\r\n> quoted\r\n\nBye ").preview == "Hi Bye")
    }

    /// BUG-190: a web address written with character references (as the browser decodes them) is remote content too.
    @Test func entityEncodedWebAddressIsRemoteContent() {
        func html(_ h: String) -> Message { var m = message(""); m.html = h; return m }
        #expect(html(#"<img src="&#104;ttp://t.example/p.png">"#).hasRemoteContent)
        #expect(html(#"<img src="&#x68;ttps://t.example/p.png">"#).hasRemoteContent)
        #expect(html(#"<img src="h&#116;tps://t.example/p.png">"#).hasRemoteContent)
        #expect(!html(#"<img src="cid:a&#64;b">"#).hasRemoteContent)
    }

    /// Every way a mail can load something from the web makes the Load Remote Content banner appear.
    @Test func remoteContentIncludesSrcsetLinkPosterAndEntityQuotedURL() {
        func html(_ h: String) -> Message { var m = message(""); m.html = h; return m }
        #expect(html(#"<img srcset="https://t.example/p.png 1x">"#).hasRemoteContent)
        #expect(html(#"<img src="cid:a" srcset="cid:a 1x, https://t.example/p2.png 2x">"#).hasRemoteContent)
        #expect(html(#"<link rel="stylesheet" href="https://t.example/s.css">"#).hasRemoteContent)
        #expect(html("<LINK HREF=http://t.example/s.css rel=stylesheet>").hasRemoteContent)
        #expect(html(#"<video poster="https://t.example/p.jpg"></video>"#).hasRemoteContent)
        #expect(html(#"<td style="background-image:url(&quot;https://t.example/bg.png&quot;)">"#).hasRemoteContent)
        #expect(html(#"<td style="background-image:url(&#39;https://t.example/bg.png&#39;)">"#).hasRemoteContent)
        // Links to the web load nothing by themselves.
        #expect(!html(#"<a href="https://x.example">link</a><img srcset="cid:a 1x">"#).hasRemoteContent)
    }

    /// Text that talks about CSS `@import` loads nothing; an `@import` of a web address does.
    @Test func importInTextIsNotRemoteContent() {
        func html(_ h: String) -> Message { var m = message(""); m.html = h; return m }
        #expect(!html("<p>Tip: write @import at the top of your stylesheet.</p>").hasRemoteContent)
        #expect(html(#"<style>@import "https://t.example/s.css";</style>"#).hasRemoteContent)
        #expect(html("<style>@import url(https://t.example/s.css);</style>").hasRemoteContent)
    }

    /// File names may be 255 bytes: longer names are cut, at a whole character, keeping the extension.
    @Test func longAttachmentNamesAreShortenedToAFileName() throws {
        let name = String(repeating: "Überweisungsbestätigung ", count: 12) + ".pdf"
        let file = Attachment(name: name).fileName
        #expect(file.utf8.count <= 255 && file.utf8.count > 240)
        #expect(file.hasSuffix(".pdf") && name.hasPrefix(String(file.dropLast(4))))
        let cjk = Attachment(name: String(repeating: "請求書", count: 40) + ".xlsx").fileName  // 3 bytes each
        #expect(cjk.utf8.count <= 255 && cjk.hasSuffix(".xlsx"))
        let noExtension = Attachment(name: String(repeating: "ä", count: 300)).fileName
        #expect(noExtension == String(repeating: "ä", count: 127))
        #expect(Attachment(name: "Report.pdf").fileName == "Report.pdf")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MessageTests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([1]).write(to: dir.appendingPathComponent(file), options: .atomic)
    }

    /// BUG-193: a sender can't disguise a file's type with bidi controls ("invoice\u{202E}fdp.app" shows as
    /// "invoiceppa.pdf"), and a line break or other control character doesn't end up in a file name.
    @Test func fileNamesDropBidiAndControlCharacters() {
        #expect(Attachment(name: "invoice\u{202E}fdp.app").fileName == "invoicefdp.app")
        #expect(Attachment(name: "a\u{2066}b\u{2069}\u{200F}.pdf").fileName == "ab.pdf")
        #expect(Attachment(name: "a\nb\tc\u{7}.pdf").fileName == "a b c .pdf")
        #expect(Attachment(name: "\u{202E}").fileName == "Attachment")
    }

    /// Draft HTML has a line per `<div>`, whatever the line ending (quoted Exchange text uses CRLF).
    @Test func draftHTMLSplitsLinesOnEveryLineEnding() {
        let h = Draft(accountID: UUID(), body: "one\r\ntwo\rthree\n\r\nfour\u{2028}five").html { _ in nil }
        for line in ["one", "two", "three", "<br>", "four", "five"] {
            #expect(h.contains("<div>\(line)</div>"), "\(line) in \(h)")
        }
        #expect(!h.contains("\r"))
    }

    /// Runs of spaces and tabs survive in the HTML, as Mail writes them: spaces alternate with `&nbsp;` (also at the
    /// start of a line), tabs go in a `white-space:pre` span. Single spaces between words stay plain.
    @Test func draftHTMLKeepsRunsOfSpacesAndTabs() {
        let tab = #"<span class="Apple-tab-span" style="white-space:pre">\#t</span>"#
        let h = Draft(accountID: UUID(), body: "Name    Qty\n  Apple 3\nx\ty\n\t\tz \n ").html { _ in nil }
        #expect(h.contains("<div>Name &nbsp; &nbsp;Qty</div>"), "\(h)")
        #expect(h.contains("<div>&nbsp; Apple 3</div>"))
        #expect(h.contains("<div>x\(tab)y</div>"))
        #expect(h.contains("<div>\(tab)\(tab)z </div>"))
        #expect(h.contains("<div>&nbsp;</div>"))
    }

    /// Lines of only spaces and tabs leave no gap in the list preview; lines are trimmed.
    @Test func previewDropsBlankLinesWithSpacesAndTabs() {
        #expect(message("Hello\n   \n\tWorld").preview == "Hello World")
        #expect(message("Hi\r\n  > quoted\r\nBye").preview == "Hi Bye")
    }

    /// Moving a placed picture changes only where its mark is: still a change, so closing the window asks.
    @Test func movingAPlacedPictureIsAChange() {
        var d = Draft(accountID: UUID(), to: "a@x.com", subject: "S", body: "\u{FFFC}Hello world")
        d.attachments = [DraftAttachment(name: "p.png", contentType: "image/png", data: Data([1]))]
        let start = d
        d.body = "Hello world\u{FFFC}"
        #expect(d.hasChanges(since: start))
        // The original's files and their marks arriving by themselves are no change.
        var f = Draft(accountID: UUID(), body: "Hi")
        let opened = f
        f.attachments = [DraftAttachment(name: "o.png", contentType: "image/png", data: Data([1]), fromOriginal: true)]
        f.body = "Hi\u{FFFC}"
        #expect(!f.hasChanges(since: opened))
    }

    /// NSTextView keeps a picture's U+FFFC and a following combining character (accent, shadda, ZWJ, ZWNJ) apart;
    /// Swift joins them into one Character. The mark still counts as the file's place.
    @Test func markFollowedByCombiningCharacterStillCountsAsAFile() {
        let mark = String(Draft.fileMark)
        func png(_ name: String, original: Bool = false) -> DraftAttachment {
            DraftAttachment(name: name, contentType: "image/png", data: Data([7]), fromOriginal: original)
        }
        for combining in ["\u{0651}", "\u{0301}", "\u{200C}", "\u{200D}"] {
            var d = Draft(accountID: UUID(), to: "a@x.com", body: "A\(mark)\(combining)B\(mark)C")
            d.attachments = [png("one.png"), png("two.png")]
            #expect(d.placedPictures == [0, 1])
            #expect(!d.text.unicodeScalars.contains("\u{FFFC}"))
            #expect(d.text.unicodeScalars.elementsEqual("A\(combining)BC".unicodeScalars))
            let h = d.html { "id\($0)" }
            #expect(h.contains("A<img src=\"cid:id0\""), "\(h)")
            #expect(h.contains("B<img src=\"cid:id1\""), "\(h)")
            #expect(!h.unicodeScalars.contains("\u{FFFC}"))
        }
        var d = Draft(accountID: UUID(), body: "x\(mark)\u{0301}y\(mark)z")
        d.attachments = [png("orig.png", original: true), png("mine.png")]
        d.excludeOriginalAttachments()
        #expect(d.attachments.map(\.name) == ["mine.png"])
        #expect(d.body.unicodeScalars.filter { $0 == "\u{FFFC}" }.count == 1)
        #expect(d.placedPictures == [0])
    }

    /// For random bodies of marks, combining characters, emoji and text, every mark counted by scalar is a placed file.
    @Test func randomDraftsMarksMatchPictures() {
        var rng = SplitMix(state: 42)
        let pieces = ["a", " ", "\n", "é", "\u{0301}", "😀", "👍🏽", "שלום", "\u{200D}", "<", "&", String(Draft.fileMark)]
        var failures = 0
        for _ in 0..<2000 {
            var body = ""
            for _ in 0..<Int.random(in: 0..<20, using: &rng) { body += pieces.randomElement(using: &rng)! }
            let marks = body.unicodeScalars.filter { $0 == "\u{FFFC}" }.count
            var d = Draft(accountID: UUID(), body: body)
            d.attachments = (0..<marks).map { DraftAttachment(name: "p\($0).png", contentType: "image/png", data: Data([7])) }
            if d.placedPictures != Array(0..<marks) || d.text.unicodeScalars.contains("\u{FFFC}") { failures += 1 }
        }
        #expect(failures == 0, "\(failures) of 2000 drafts misplace files")
    }

    /// The compose window shows the size on every keystroke: the estimate must not walk a long body.
    @Test func estimatedSizeIsCheapForALongReply() {
        let line = "> Thanks, that works for me. Let's keep Friday at 10 as planned, ok?\n"
        var d = Draft(accountID: UUID(), body: String(repeating: line, count: 6_000))  // ~420 KB quoted thread
        d.attachments = [DraftAttachment(name: "p.png", contentType: "image/png", data: Data(repeating: 7, count: 1_000_000))]
        let clock = ContinuousClock()
        var total = 0
        let t = clock.measure { for _ in 0..<3 { total &+= d.estimatedSize } }
        #expect(t < .milliseconds(16), "three size estimates (one keystroke's render) took \(t)")
    }

    /// Each New Message (or Reply to the same message) opens its own window: the window values differ even for
    /// equal drafts, and carry the draft.
    @Test func twoNewMessagesAreDistinctWindowValues() {
        let d = Draft(accountID: UUID())
        let a = ComposeWindow(d), b = ComposeWindow(d)
        #expect(a != b)
        #expect(a.draft == d && b.draft == d)
    }
}

/// A seeded random number generator (SplitMix64), so random tests repeat.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
