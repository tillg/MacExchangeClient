import Foundation
import Testing
import WebKit
@testable import MailModel

// MARK: - WebKit helper: renders HTMLPage.document in a real WKWebView, as HTMLBodyView does, and runs a script.

@MainActor
enum Render {
    static func eval(_ page: String, _ script: String, settle: Int = 0, timeout: TimeInterval = 30) async -> Any? {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let v = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
        v.loadHTMLString(page, baseURL: nil)
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(200))
        while v.isLoading && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        if settle > 0 { try? await Task.sleep(for: .milliseconds(settle)) }
        let r = try? await v.evaluateJavaScript(script)
        print("RENDER loading=\(v.isLoading) result=\(String(describing: r))")
        return r
    }
}

@MainActor
struct Probe_Model2Tests {
    // MARK: WebKit sanity

    @Test func webkitHarnessWorks() async {
        let r = await Render.eval(HTMLPage.document("<p id=x>hello</p>", allowRemote: false), "document.getElementById('x').textContent")
        #expect(r as? String == "hello")
    }

    // MARK: HTMLPage.document structure

    /// The page's height is what HTMLBodyView.measure computes: the bottom of #mail-replica-body plus the body's
    /// bottom margin. All of the message must be inside the wrapper, or the view is cut short.
    static let measureJS = """
        [Math.ceil(document.getElementById('\(HTMLPage.bodyID)').getBoundingClientRect().bottom
            + parseFloat(getComputedStyle(document.body).marginBottom)),
         document.documentElement.scrollHeight,
         document.getElementById('\(HTMLPage.bodyID)').contains(document.getElementById('tail'))].join('|')
        """

    @Test func strayClosingDivDoesNotEscapeTheMeasuredWrapper() async throws {
        let mail = "<div><p>Hello</p></div></div><p id=tail style='height:600px'>Signature and the rest of the mail</p>"
        let r = await Render.eval(HTMLPage.document(mail, allowRemote: false), Self.measureJS)
        try #require(r != nil)
        let parts = (r as? String ?? "").split(separator: "|").map(String.init)
        #expect(parts.count == 3 && parts[2] == "true", "measured|content height|tail inside wrapper = \(parts)")
        #expect(parts.count == 3 && Int(parts[0])! >= Int(parts[1])!, "measured|content height|tail inside wrapper = \(parts)")
    }

    @Test func controlBalancedDivsStayInsideTheWrapper() async throws {
        let mail = "<div><p>Hello</p></div><p id=tail style='height:600px'>Signature and the rest of the mail</p>"
        let r = await Render.eval(HTMLPage.document(mail, allowRemote: false), Self.measureJS)
        try #require(r != nil)
        let parts = (r as? String ?? "").split(separator: "|").map(String.init)
        #expect(parts.count == 3 && parts[2] == "true" && Int(parts[0])! >= Int(parts[1])!, "\(parts)")
    }

    /// A sender's <body bgcolor> must win over our default white, as in Mail (MUIWebDocument.css sets no
    /// background or colour). Damaging case: light text on the sender's dark background becomes invisible.
    @Test func bodyBgcolorFromTheSenderIsKept() async throws {
        let mail = "<html><body bgcolor=\"#000000\"><font id=f color=\"#ffffff\">White text on the sender's black page</font></body></html>"
        let r = await Render.eval(HTMLPage.document(mail, allowRemote: false),
                                  "getComputedStyle(document.body).backgroundColor + '|' + getComputedStyle(document.getElementById('f')).color")
        try #require(r != nil)
        #expect(r as? String == "rgb(0, 0, 0)|rgb(255, 255, 255)", "body background|text colour = \(String(describing: r))")
    }

    @Test func bodyTextAttributeFromTheSenderIsKept() async throws {
        let mail = "<html><body bgcolor=\"#000000\" text=\"#ffffff\"><p id=p>Dark newsletter</p></body></html>"
        let r = await Render.eval(HTMLPage.document(mail, allowRemote: false),
                                  "getComputedStyle(document.body).backgroundColor + '|' + getComputedStyle(document.getElementById('p')).color")
        try #require(r != nil)
        #expect(r as? String == "rgb(0, 0, 0)|rgb(255, 255, 255)", "body background|text colour = \(String(describing: r))")
    }

    @Test func controlBodyStyleBackgroundIsKept() async throws {
        let mail = "<html><body style=\"background:#000\"><font id=f color=\"#ffffff\">x</font></body></html>"
        let r = await Render.eval(HTMLPage.document(mail, allowRemote: false),
                                  "getComputedStyle(document.body).backgroundColor + '|' + getComputedStyle(document.getElementById('f')).color")
        try #require(r != nil)
        #expect(r as? String == "rgb(0, 0, 0)|rgb(255, 255, 255)", "\(String(describing: r))")
    }

    /// Fonts embedded in the mail as data: URIs contact no one, like data: images (which the policy allows).
    static func fontMail() throws -> String {
        let font = try Data(contentsOf: URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/NotoSansCarian-Regular.ttf"))
        return "<style>@font-face { font-family: Embedded; src: url(data:font/ttf;base64,\(font.base64EncodedString())); }"
            + " p { font-family: Embedded, Helvetica; }</style><p>Embedded font</p>"
    }
    static let fontStatusJS = "Array.from(document.fonts).map(f => f.family + ':' + f.status).join(',')"

    @Test func embeddedDataFontsLoadWithoutRemoteContent() async throws {
        let r = await Render.eval(HTMLPage.document(try Self.fontMail(), allowRemote: false), Self.fontStatusJS, settle: 1000)
        try #require(r != nil)
        #expect(r as? String == "Embedded:loaded", "\(String(describing: r))")
    }

    @Test func controlEmbeddedDataFontsLoadWithRemoteContent() async throws {
        let r = await Render.eval(HTMLPage.document(try Self.fontMail(), allowRemote: true), Self.fontStatusJS, settle: 1000)
        try #require(r != nil)
        #expect(r as? String == "Embedded:loaded", "\(String(describing: r))")
    }

    // MARK: RemoteImages

    let me = Account(name: "Work", address: "alex@work.com")

    @Test func externalSenderWhoseAddressStartsWithSlashOIsNotOrganisation() {
        // An internet address may legally start with "/o=" in its local part; it is not an X.500 address.
        let s = Contact(name: "IT Department", email: "/o=work/cn=it@evil.example")
        #expect(!RemoteImages.organisation.loadsAutomatically(from: s, account: me))
    }

    // MARK: Draft.hasChanges

    @Test func movingAPictureInTheTextIsAChange() {
        let m = String(Draft.fileMark)
        var start = Draft(accountID: UUID(), to: "a@x.com", body: "Hello \(m)world")
        start.attachments = [DraftAttachment(name: "p.png", contentType: "image/png", data: Data([1, 2]))]
        var moved = start
        moved.body = "Hello world\(m)"
        #expect(moved.hasChanges(since: start))
    }

    // MARK: DayLayout

    let day = ISO8601DateFormatter().date(from: "2026-11-23T00:00:00Z")!
    func at(_ h: Double) -> Date { day.addingTimeInterval(h * 3600) }
    func ev(_ s: String, _ from: Double, _ to: Double) -> CalendarEvent { CalendarEvent(subject: s, start: at(from), end: at(to)) }

    @Test func zeroLengthEventAndMeetingAtTheSameTimeAreSideBySide() {
        let cols = DayLayout.columns([ev("Reminder", 9, 9), ev("Meeting", 9, 10)])
        // Drawn at the same top (the view gives every event at least 14 pt): they must not share a column.
        #expect(Set(cols.map(\.column)).count == 2, "\(cols.map { ($0.event.subject, $0.column, $0.of) })")
    }

    // MARK: WhatsNew

    @Test func whatsNewHasNoDuplicateLines() {
        let all = WhatsNew.days.flatMap(\.features)
        #expect(Set(all).count == all.count)
    }

    @Test func whatsNewIsPlainLanguage() {
        let banned = ["EWS", "SQLite", "FTS", "cid", "cache", "Cache", "JSON", "API", "HTML", "SDK", "Team ID", "token"]
        let hits = WhatsNew.days.flatMap(\.features).filter { f in banned.contains { f.range(of: "\\b\($0)\\b", options: .regularExpression) != nil } }
        #expect(hits.isEmpty, "\(hits)")
    }

    /// The sender's doctype is lost inside our wrapper, so every mail renders in quirks mode: tables then don't
    /// inherit the 14 px default (WebKit's quirks sheet resets table font-size to medium = 16 px).
    @Test func tableTextGetsTheDefaultFontSizeInAStandardsModeMail() async throws {
        let mail = "<!DOCTYPE html><html><body><table><tr><td id=c>Kind regards</td></tr></table></body></html>"
        let r = await Render.eval(HTMLPage.document(mail, allowRemote: false),
                                  "document.compatMode + '|' + getComputedStyle(document.getElementById('c')).fontSize")
        try #require(r != nil)
        #expect(r as? String == "CSS1Compat|14px", "\(String(describing: r))")
    }

    @Test func tableTextGetsTheDefaultFontSizeInAnUnstyledMail() async throws {
        let mail = "<p id=p>Hi,</p><table><tr><td id=c>Kind regards<br>Ann</td></tr></table>"
        let r = await Render.eval(HTMLPage.document(mail, allowRemote: false),
                                  "getComputedStyle(document.getElementById('p')).fontSize + '|' + getComputedStyle(document.getElementById('c')).fontSize")
        try #require(r != nil)
        #expect(r as? String == "14px|14px", "paragraph|table cell = \(String(describing: r))")
    }

    // MARK: DayLayout properties

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

    /// Positive-length events only: no two overlapping events share a column, column < of, overlapping events
    /// have the same width.
    @Test func dayLayoutPropertiesOverRandomDays() {
        var problems: [String] = []
        for seed in UInt64(0)..<2000 {
            var rng = SplitMix(state: seed)
            var evs: [CalendarEvent] = []
            for i in 0..<Int.random(in: 1...12, using: &rng) {
                let s = Double(Int.random(in: 0..<96, using: &rng)) / 4
                let len = Double(Int.random(in: 1...16, using: &rng)) / 4
                evs.append(ev("e\(i)", s, s + len))
            }
            let placed = DayLayout.columns(evs)
            if placed.count != evs.count { problems.append("seed \(seed): count"); continue }
            for a in placed { if a.column >= a.of { problems.append("seed \(seed): column \(a.column) of \(a.of)") } }
            for (i, a) in placed.enumerated() {
                for b in placed[(i + 1)...] where a.event.start < b.event.end && b.event.start < a.event.end {
                    if a.column == b.column { problems.append("seed \(seed): overlap in column") }
                    if a.of != b.of { problems.append("seed \(seed): overlapping events with different widths") }
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.prefix(5))")
    }

    /// With zero-length, negative and duplicate events: every placed entry is distinct (the day column's
    /// ForEach uses the Placed value as its id), and events that start together never share a column.
    @Test func dayLayoutWithDegenerateEventsOverRandomDays() {
        var problems: [String] = []
        for seed in UInt64(0)..<2000 {
            var rng = SplitMix(state: seed)
            var evs: [CalendarEvent] = []
            for _ in 0..<Int.random(in: 2...8, using: &rng) {
                let s = Double(Int.random(in: 32..<40, using: &rng)) / 4
                let len = Double(Int.random(in: -2...4, using: &rng)) / 4
                evs.append(ev("Busy", s, s + len))
            }
            let placed = DayLayout.columns(evs)
            if placed.count != evs.count { problems.append("seed \(seed): count \(placed.count) of \(evs.count)"); continue }
            if Set(placed).count != placed.count { problems.append("seed \(seed): duplicate Placed values") }
            for (i, a) in placed.enumerated() {
                for b in placed[(i + 1)...] where a.event.start == b.event.start && a.column == b.column {
                    problems.append("seed \(seed): two events at \(a.event.start) in column \(a.column)")
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.count) problems, e.g. \(problems.prefix(3))")
    }

    // MARK: freeURL

    @Test func saveNextToADanglingSymlinkDoesNotPickItsName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("report.pdf").path,
                                                   withDestinationPath: "/nonexistent/old-report.pdf")
        let source = dir.appendingPathComponent("download.pdf")
        try Data([1, 2, 3]).write(to: source)
        let url = MailStore.freeURL(for: "report.pdf", in: dir)
        // saveAttachment copies to this URL; it must not fail.
        #expect(throws: Never.self) { try FileManager.default.copyItem(at: source, to: url) }
        #expect(url.lastPathComponent == "report 2.pdf", "\(url.lastPathComponent)")
    }
}
