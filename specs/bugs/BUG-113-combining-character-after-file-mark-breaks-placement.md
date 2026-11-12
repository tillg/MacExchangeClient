---
title: 'A combining character right after a placed file breaks the file marks: pictures change place, a stray U+FFFC is sent, Exclude removes the wrong file'
priority: P4
area: Models
status: open
found: 2026-11-13
---
## Summary
Draft finds file marks by comparing Swift `Character`s with `"\u{FFFC}"`. NSTextView stores the attachment's U+FFFC and the next character as separate UTF-16 units. When the next character is a combining one (an accent, an Arabic shadda, ZWJ or ZWNJ, which Persian keyboards type often), Swift joins them into one grapheme `"\u{FFFC}\u{651}"` that isn't counted as a mark. Every later mark then points to the wrong file: the first picture goes where the second one was, the last picture goes as an ordinary attachment, and the sent text or HTML has a visible U+FFFC ("OBJ" box). `excludeOriginalAttachments` keeps the original's mark and drops the user's file from the text.

## Repro
```swift
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

    /// NSTextView keeps U+FFFC for the picture and the next character as separate UTF-16 units; when the next
    /// character is a combining one (Arabic shadda, an accent, ZWJ/ZWNJ), Swift sees one Character "\u{FFFC}\u{651}"
    /// that is not `fileMark`.
    @Test func markFollowedByCombiningCharacterStillCountsAsAFile() {
        for combining in ["\u{0651}", "\u{0301}", "\u{200C}", "\u{200D}"] {
            var d = Draft(accountID: work.id, to: "a@x.com", body: "A\(mark)\(combining)B\(mark)C")
            d.attachments = [png("one.png"), png("two.png")]
            #expect(d.placedPictures == [0, 1], "combining U+\(String(combining.unicodeScalars.first!.value, radix: 16)): placed \(d.placedPictures)")
            #expect(!d.text.unicodeScalars.contains("\u{FFFC}"),
                    "sent text keeps an object replacement character: \(d.text.unicodeScalars.map { String($0.value, radix: 16) })")
            let h = d.html { "id\($0)" }
            #expect(h.contains("A<img src=\"cid:id0\""), "first picture not after A: \(h)")
        }
    }

    /// Exclude Attachments with a combining character after the original's picture: the user's own file must stay.
    @Test func excludeOriginalWithCombiningCharacterKeepsUsersFile() {
        var d = Draft(accountID: work.id, body: "x\(mark)\u{0301}y\(mark)z")
        d.attachments = [DraftAttachment(name: "orig.png", contentType: "image/png", data: Data([1]), fromOriginal: true),
                         png("mine.png")]
        d.excludeOriginalAttachments()
        #expect(d.attachments.map(\.name) == ["mine.png"])
        #expect(d.body.unicodeScalars.filter { $0 == "\u{FFFC}" }.count == 1, "marks left: \(d.body.unicodeScalars.map { String($0.value, radix: 16) })")
        #expect(d.placedPictures == [0], "placed: \(d.placedPictures)")
    }

    /// Property: for random bodies built from marks and text, the marks counted by scalars equal the files placed.
    @Test func randomDraftsMarksMatchPictures() {
        var rng = ComposeRNG(state: 42)
        let pieces = ["a", " ", "\n", "é", "\u{0301}", "😀", "👍🏽", "שלום", "\u{200D}", "<", "&", mark]
        var failures = 0, first = ""
        for _ in 0..<2000 {
            var body = ""
            for _ in 0..<Int.random(in: 0..<20, using: &rng) { body += pieces.randomElement(using: &rng)! }
            let scalarMarks = body.unicodeScalars.filter { $0 == "\u{FFFC}" }.count
            var d = Draft(accountID: work.id, body: body)
            d.attachments = (0..<scalarMarks).map { png("p\($0).png") }
            if d.placedPictures != Array(0..<scalarMarks) || d.text.unicodeScalars.contains("\u{FFFC}") {
                failures += 1
                if first.isEmpty { first = body.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " ") }
            }
        }
        #expect(failures == 0, "\(failures) of 2000 drafts misplace files; first body scalars: \(first)")
    }

}
```

## Expected vs actual
Expected: `placedPictures == [0, 1]`, no U+FFFC in `text`, the first `<img>` right after "A". Actual (the same for U+0651, U+0301, U+200C, U+200D):
```
combining U+651: placed [0]
sent text keeps an object replacement character: ["41", "fffc", "651", "42", "43"]
first picture not after A: …<div>A￼ّB<img src="cid:id0" alt="one.png">C</div>…
```
Exclude Attachments: `placed: []` (the expected `[0]`). Random bodies: `244 of 2000 drafts misplace files; first body scalars: 61 5e9 … 3c fffc 200d 3c …`.

## Why expected
`specs/system/domain-model.md`: "`body` holds U+FFFC where a file is placed; the k-th mark is `attachments[k]`. `text` is `body` without marks". `ComposeTextView` writes `body` from `NSTextView.string`, so marks are UTF-16 units and the model must count them that way. README: "Pictures placed in the text go out in their place".

## Likely cause
`Models.swift` `Draft.text` (`body.filter { $0 != Self.fileMark }`), `placedPictures` (`body.filter { $0 == Self.fileMark }.count`), `html(contentID:)` (`for c in line` with `c == Self.fileMark`) and `excludeOriginalAttachments` (`body.filter` per Character) all work on grapheme clusters. They should iterate `unicodeScalars`. `ComposeTextView.load(body:attachments:)` (`for c in body`) has the same flaw and would drop such a file when the text is loaded.
