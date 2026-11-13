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

    // MARK: Draft.hasChanges

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
