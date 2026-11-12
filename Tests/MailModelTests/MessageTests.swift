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
}
