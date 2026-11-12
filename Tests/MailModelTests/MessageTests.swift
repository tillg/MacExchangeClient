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
}
