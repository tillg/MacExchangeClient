import Foundation
import Testing
@testable import MailModel

/// Bug-hunt probes for Models / HTMLPage / Invite helpers.
struct Probe_ModelTests {
    // MARK: Contact.parseList

    @Test func parseListPlusAndIDN() {
        let c = Contact.parseList("Tom <tom+tag@bücher.de>, ünï@xn--bcher-kva.de")
        #expect(c.map(\.email) == ["tom+tag@bücher.de", "ünï@xn--bcher-kva.de"])
    }

    // MARK: Contact.initials

    @Test func initialsAtMostTwoLetters() {
        for name in ["ßtefan Müller", "ǆenan Kovač", "ﬀoo Bar"] {
            let i = Contact(name: name, email: "x@x.com").initials
            #expect(i.count <= 2, "\(name) -> \(i)")
        }
    }

    @Test func initialsWeirdNames() {
        #expect(Contact(name: "👨‍👩‍👧 Family Group", email: "f@x").initials == "👨‍👩‍👧F")
        #expect(Contact(name: "", email: "f@x").initials == "")
        #expect(Contact(name: "Jane\u{00A0}Doe", email: "j@x").initials == "JD")
        #expect(Contact(name: "Jane\tDoe", email: "j@x").initials == "JD")
        #expect(Contact(name: "محمد علي", email: "m@x").initials == "مع")
    }

    // MARK: Message.preview

    @Test func previewCollapsesBlankWhitespaceLines() {
        let m = Message(accountID: UUID(), from: Contact(name: "A", email: "a@x"), to: [], subject: "S",
                        body: "Hello\n   \n\tWorld", date: .now)
        #expect(m.preview == "Hello World")
    }

    @Test func previewOfHugeBodyIsFast() {
        let body = String(repeating: "Lorem ipsum dolor sit amet\n", count: 40_000)  // ~1 MB
        let m = Message(accountID: UUID(), from: Contact(name: "A", email: "a@x"), to: [], subject: "S",
                        body: body, date: .now)
        let t = Date()
        for _ in 0..<10 { _ = m.preview }
        let per = Date().timeIntervalSince(t) / 10
        #expect(per < 0.005, "preview took \(per * 1000) ms per call")
    }

    @Test func previewCRLF() {
        let m = Message(accountID: UUID(), from: Contact(name: "A", email: "a@x"), to: [], subject: "S",
                        body: "Hi\r\n> quoted\r\nBye", date: .now)
        #expect(m.preview == "Hi Bye")
    }

    // MARK: hasRemoteContent

    func html(_ h: String) -> Message {
        var m = Message(accountID: UUID(), from: Contact(name: "A", email: "a@x"), to: [], subject: "S", body: "", date: .now)
        m.html = h
        return m
    }

    @Test func remoteContentSrcset() {
        #expect(html(#"<img srcset="https://t.example/p.png 1x">"#).hasRemoteContent)
    }

    @Test func remoteContentLinkStylesheet() {
        #expect(html(#"<link rel="stylesheet" href="https://t.example/s.css">"#).hasRemoteContent)
    }

    @Test func remoteContentEntityQuotedURL() {
        #expect(html(#"<td style="background-image:url(&quot;https://t.example/bg.png&quot;)">"#).hasRemoteContent)
    }


    // MARK: HTMLPage

    @Test func inlineContentTypeIsNotMarkup() {
        let evil = InlineImage(contentType: #"image/png" onload="x" data-x=""#, data: Data([1]))
        let page = HTMLPage.document(#"<img src="cid:a@x">"#, allowRemote: false, inline: ["a@x": evil])
        #expect(!page.contains(#"onload="x""#))
    }

    @Test func cidInsideWordsIsNotAReference() {
        #expect(HTMLPage.contentIDs(in: "<p>Placid:lake and acid:rain, Lucid:dreams</p>").isEmpty)
    }

    @Test func cidUnquotedSelfClosing() {
        #expect(HTMLPage.contentIDs(in: "<img src=cid:logo@x/>") == ["logo@x"])
    }

    @Test func cidAmpEntity() {
        #expect(HTMLPage.contentIDs(in: #"<img src="cid:a&amp;b@x">"#) == ["a&b@x"])
    }

    @Test func unresolvedUppercaseCIDHidden() {
        let page = HTMLPage.document(#"<img src="CID:missing@x">"#, allowRemote: true)
        // The hiding rule must match regardless of the scheme's case, like the data: rule does.
        #expect(page.contains(#"img[src^="cid:" i]"#))
    }

    @Test func manyCIDsLargeHTMLPerformance() {
        let png = InlineImage(contentType: "image/png", data: Data(repeating: 7, count: 100))
        var inline: [String: InlineImage] = [:]
        var h = ""
        for i in 0..<2000 { inline["i\(i)@x"] = png; h += "<p>\(String(repeating: "x", count: 400))</p><img src=\"cid:i\(i)@x\">" }
        let t = Date()
        let page = HTMLPage.document(h, allowRemote: false, inline: inline)
        let el = Date().timeIntervalSince(t)
        #expect(!page.contains("cid:i1999@x"))
        #expect(el < 1, "took \(el) s")
    }

    @Test func opensLinkOddInputs() {
        #expect(HTMLPage.opensLink("https://bücher.de/ä ö"))
        #expect(!HTMLPage.opensLink("javascript:alert(1)"))
        #expect(!HTMLPage.opensLink(""))
    }

    // MARK: RemoteImages

    @Test func organisationTrailingDotAndCase() {
        let me = Account(name: "W", address: "Alex@Northwind.Example")
        #expect(RemoteImages.organisation.loadsAutomatically(from: Contact(name: "X", email: "b@NORTHWIND.example"), account: me))
        #expect(!RemoteImages.organisation.loadsAutomatically(from: Contact(name: "X", email: "b@evilnorthwind.example"), account: me))
        #expect(!RemoteImages.organisation.loadsAutomatically(from: Contact(name: "X", email: "b@northwind.example.evil.com"), account: me))
    }

    // MARK: Attachment.fileName

    @Test func longAttachmentNameCanBeWritten() throws {
        let name = String(repeating: "Überweisungsbestätigung ", count: 12) + ".pdf"  // ~300 UTF-8 bytes
        let a = Attachment(name: name)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([1]).write(to: dir.appendingPathComponent(a.fileName), options: .atomic)
    }


    // MARK: Draft.html

    @Test func draftHTMLSplitsCRLFLines() {
        let d = Draft(accountID: UUID(), body: "one\r\ntwo\r\nthree")
        let h = d.html { _ in nil }
        #expect(h.contains("<div>one</div>") && h.contains("<div>three</div>"), "\(h)")
    }

    @Test func draftHTMLKeepsRunsOfSpaces() {
        let d = Draft(accountID: UUID(), body: "Name    Qty\nApple      3")
        let h = d.html { _ in nil }
        // Multiple spaces must survive in HTML: &nbsp; or a white-space: pre-wrap style.
        #expect(h.contains("&nbsp;") || h.contains("pre-wrap"), "\(h)")
    }

    @Test func draftHTMLEscapesWeirdText() {
        let d = Draft(accountID: UUID(), body: "<script>alert('x')</script> & \"q\"")
        let h = d.html { _ in nil }
        #expect(!h.contains("<script>"))
    }

    @Test func draftHTMLMoreMarksThanAttachments() {
        let m = String(Draft.fileMark)
        var d = Draft(accountID: UUID(), body: "a\(m)b\(m)c")
        d.attachments = [DraftAttachment(name: "p.png", contentType: "image/png", data: Data([1]))]
        let h = d.html { k in k < d.attachments.count ? "id\(k)" : nil }
        #expect(h.contains("cid:id0"))
    }


    @Test func excludeOriginalKeepsMarksAligned() {
        let m = String(Draft.fileMark)
        var d = Draft(accountID: UUID(), body: "x\(m)y\(m)z\(m)")
        d.attachments = [DraftAttachment(name: "a", contentType: "image/png", data: Data([1])),
                         DraftAttachment(name: "o", contentType: "image/png", data: Data([2]), fromOriginal: true),
                         DraftAttachment(name: "c", contentType: "image/png", data: Data([3]))]
        d.excludeOriginalAttachments()
        #expect(d.body == "x\(m)yz\(m)")
        #expect(d.attachments.map(\.name) == ["a", "c"])
    }

    // MARK: Codable round-trips

    @Test func messageRoundTripWeirdData() throws {
        let m = Message(accountID: UUID(), mailbox: .folder("AAMk:/\u{0}x"), from: Contact(name: "👩🏽‍💻 \u{202E}x", email: "\"a b\"@x.com"),
                        to: [Contact(name: "", email: "")], subject: "\u{FEFF}Ünïcødé 𝓢", body: String(repeating: "ä", count: 1_000_000),
                        date: Date(timeIntervalSinceReferenceDate: 123456789.123456789), flag: .purple,
                        attachments: ["a.txt"], remoteID: "R", invite: Invite(start: .distantPast, end: .distantFuture))
        let d = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(m))
        #expect(d == m)
    }

    @Test func draftRoundTripKeepsAttachments() throws {
        var d = Draft(accountID: UUID(), to: "a@x", body: "hi")
        d.attachments = [DraftAttachment(name: "x", contentType: nil, data: Data([0, 1]))]
        d.original = UUID(); d.loadingOriginal = UUID()
        let r = try JSONDecoder().decode(Draft.self, from: JSONEncoder().encode(d))
        #expect(r == d)
    }

    @Test func pendingChangeRoundTrip() throws {
        let p = PendingChange(account: UUID(), change: .move(["a", "b"], to: .folder("x")), previous: [])
        let r = try JSONDecoder().decode(PendingChange.self, from: JSONEncoder().encode(p))
        #expect(r == p)
    }

    // MARK: Invite / DayLayout

    let day = ISO8601DateFormatter().date(from: "2026-03-29T00:00:00Z")!  // EU DST switch
    func at(_ h: Double) -> Date { day.addingTimeInterval(h * 3600) }

    @Test func zeroLengthEventsAtSameTimeShareColumns() {
        let evs = [CalendarEvent(subject: "A", start: at(9), end: at(9)), CalendarEvent(subject: "B", start: at(9), end: at(9))]
        let cols = DayLayout.columns(evs)
        #expect(Set(cols.map(\.column)).count == 2 || cols.allSatisfy { $0.of == 1 })
    }

    @Test func malformedEventEndBeforeStart() {
        let evs = [CalendarEvent(subject: "A", start: at(10), end: at(9)), CalendarEvent(subject: "B", start: at(9.5), end: at(11))]
        let cols = DayLayout.columns(evs)
        #expect(cols.count == 2)
    }

    @Test func conflictsZeroLengthInvite() {
        let inv = Invite(start: at(10), end: at(10))
        let c = inv.conflicts(in: [CalendarEvent(subject: "M", start: at(9), end: at(11))], subject: "X")
        #expect(c.count == 1)
    }

    @Test func layoutManyEvents() {
        var evs: [CalendarEvent] = []
        for i in 0..<5000 { evs.append(CalendarEvent(subject: "\(i)", start: at(Double(i % 24)), end: at(Double(i % 24) + 1.5))) }
        let t = Date()
        let cols = DayLayout.columns(evs)
        #expect(cols.count == 5000)
        #expect(Date().timeIntervalSince(t) < 1)
    }

    // MARK: ServerChange

    @Test func renamedMapsAllIDs() {
        let c = ServerChange.move(["a", "b"], to: .trash).renamed(["a": "A"])
        #expect(c.remoteIDs == ["A", "b"])
    }

    @Test func remoteContentVideoPoster() {
        #expect(html(#"<video poster="https://t.example/p.jpg"></video>"#).hasRemoteContent)
    }

    @Test func remoteContentFalsePositiveImportInText() {
        #expect(!html("<p>Tip: write @import at the top of your stylesheet.</p>").hasRemoteContent)
    }

    @Test func remoteContentFalsePositiveTextAboutSrc() {
        #expect(!html("<pre>&lt;img src=&quot;https://x.example/a.png&quot;&gt;</pre>").hasRemoteContent)
    }

}
