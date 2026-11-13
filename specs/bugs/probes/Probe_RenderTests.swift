import Foundation
import Network
import Testing
import WebKit
@testable import MailModel

// MARK: - Harness: a real WKWebView configured as MailWebView (HTMLBodyView.swift) does, kept alive so the
// app's sizing can be replayed: load at the view's width and 1 pt height (HTMLBodyView starts at height 1),
// measure with the app's own script, set the frame to that height, change the width, measure again.

@MainActor
final class RPage {
    let v: WKWebView

    init(_ page: String, width: CGFloat = 600, height: CGFloat = 1, dark: Bool = false) async {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        v = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: config)
        // MailWebView sets aqua; `dark` only to check what the system appearance would do.
        v.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        v.loadHTMLString(page, baseURL: nil)
        let deadline = Date().addingTimeInterval(30)
        try? await Task.sleep(for: .milliseconds(200))
        while v.isLoading && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .milliseconds(150))
    }

    func eval(_ js: String) async -> Any? {
        let r = try? await v.evaluateJavaScript(js)
        print("RPAGE \(String(describing: r))")
        return r
    }

    func string(_ js: String) async -> String { (await eval(js)).map { "\($0)" } ?? "nil" }

    /// HTMLBodyView.Coordinator.measure's script, verbatim.
    static let measureJS = """
        Math.ceil(document.getElementById('\(HTMLPage.bodyID)').getBoundingClientRect().bottom
            + parseFloat(getComputedStyle(document.body).marginBottom))
        """

    func measure() async -> Double { ((await eval(Self.measureJS)) as? NSNumber)?.doubleValue ?? -1 }

    func resize(width: CGFloat? = nil, height: CGFloat? = nil) async {
        v.setFrameSize(NSSize(width: width ?? v.frame.width, height: height ?? v.frame.height))
        v.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        _ = await eval("document.body.offsetHeight")  // force layout
    }

    /// The app's sequence: measured once loaded, then the view gets that height.
    func settleLikeTheApp() async -> Double {
        let h = await measure()
        if h > 0 { await resize(height: h) }
        return h
    }

    /// Everything the page draws, below the view's top: what the view would need to be fully visible.
    func contentHeight() async -> Double {
        let r = await eval("Math.max(document.documentElement.scrollHeight, document.body.scrollHeight)")
        return (r as? NSNumber)?.doubleValue ?? -1
    }
}

/// A loopback-only HTTP listener (127.0.0.1), to see whether a page asks for anything from "the web".
/// Nothing leaves the machine; it only records request lines.
final class LoopbackRecorder: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var _requests: [String] = []
    private var _connections = 0
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return _requests }
    var connections: Int { lock.lock(); defer { lock.unlock() }; return _connections }
    private(set) var port: UInt16 = 0

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { s in if case .ready = s { ready.signal() } }
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            self.lock.lock(); self._connections += 1; self.lock.unlock()
            c.start(queue: .global())
            c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                if let data, let s = String(data: data, encoding: .utf8), let line = s.split(separator: "\r\n").first {
                    self.lock.lock(); self._requests.append(String(line)); self.lock.unlock()
                }
                let body = "x"
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                c.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in c.cancel() })
            }
        }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    deinit { listener.cancel() }
}

private let png1x1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

@MainActor
@Suite(.serialized)
struct Probe_RenderTests {

    // MARK: Character set

    /// Outlook puts `<meta http-equiv="Content-Type" content="text/html; charset=…">` in every HTML body. The body
    /// is already decoded text (EWS gives a string); the page is handed to WebKit as a string. The meta must not
    /// make WebKit re-decode it, or every umlaut turns into mojibake.
    @Test func outlookCharsetMetaDoesNotGarbleUmlauts() async {
        let mail = """
            <html xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office">
            <head><meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1">
            <meta name="Generator" content="Microsoft Word 15 (filtered medium)"></head>
            <body lang="DE"><div class="WordSection1"><p class="MsoNormal" id="t">Grüße aus Köln – 5 €<o:p></o:p></p></div></body></html>
            """
        let p = await RPage(HTMLPage.document(mail, allowRemote: false))
        let r = await p.string("document.characterSet + '|' + document.getElementById('t').textContent")
        #expect(r == "UTF-8|Grüße aus Köln – 5 €", "\(r)")
    }

    @Test func metaCharsetWindows1252DoesNotGarbleText() async {
        let mail = #"<meta charset="windows-1252"><p id="t">naïve café “quoted” 日本</p>"#
        let p = await RPage(HTMLPage.document(mail, allowRemote: false))
        let r = await p.string("document.getElementById('t').textContent")
        #expect(r == "naïve café “quoted” 日本", "\(r)")
    }

    // MARK: Mail's MUIWebDocument.css rules (MailUI.framework/Resources/MUIWebDocument.css)

    /// Mail caps pictures sent by Apple Mail (`img.Apple-web-attachment`) at the page width.
    @Test func appleMailPictureFitsTheWindow() async {
        let mail = #"<div>Look:</div><div><img class="Apple-web-attachment Singleton" id="i" width="3024" height="40" src="data:image/png;base64,\#(png1x1)"></div>"#
        let p = await RPage(HTMLPage.document(mail, allowRemote: false))
        let r = await p.string("document.getElementById('i').getBoundingClientRect().width + '|' + document.documentElement.scrollWidth")
        #expect(r == "560|600", "picture width|page scroll width = \(r)")
    }

    /// Mail draws Apple Mail's dash lists with dashes, and nested ordered lists as 1. a. i.
    @Test func appleMailListStyles() async {
        let mail = #"<ul class="Apple-dash-list" id="u"><li>one</li></ul><ol><li>a<ol id="o2"><li>b<ol id="o3"><li>c</li></ol></li></ol></li></ol>"#
        let p = await RPage(HTMLPage.document(mail, allowRemote: false))
        let r = await p.string("""
            ['u','o2','o3'].map(id => getComputedStyle(document.getElementById(id)).listStyleType).join(' ')
            """)
        #expect(r == "none lower-alpha lower-roman", "\(r)")
    }

    /// Mail's `* { -webkit-user-modify: initial !important }`: a message can't make itself editable.
    @Test func contentEditableMailIsNotEditable() async {
        let mail = #"<div contenteditable="true" id="e">Type here to change what I wrote</div>"#
        let p = await RPage(HTMLPage.document(mail, allowRemote: false))
        let r = await p.string("document.getElementById('e').isContentEditable + '|' + getComputedStyle(document.getElementById('e')).webkitUserModify")
        #expect(r == "false|read-only", "\(r)")
    }

    // MARK: No JavaScript

    static let scriptVectors = """
        <script>document.documentElement.setAttribute('r-script','1')</script>
        <img src="nothing.png" onerror="document.documentElement.setAttribute('r-onerror','1')">
        <svg onload="document.documentElement.setAttribute('r-svg','1')"><rect width="1" height="1"/></svg>
        <body onload="document.documentElement.setAttribute('r-bodyonload','1')">
        <iframe srcdoc="<script>parent.document.documentElement.setAttribute('r-srcdoc','1')</script>"></iframe>
        <object data="data:text/html,<script>parent.document.documentElement.setAttribute('r-object','1')</script>"></object>
        <details open ontoggle="document.documentElement.setAttribute('r-toggle','1')"><summary>s</summary>x</details>
        <input autofocus onfocus="document.documentElement.setAttribute('r-focus','1')">
        <style>@keyframes k{from{opacity:0}to{opacity:1}}</style>
        <div style="animation:k 10ms" onanimationstart="document.documentElement.setAttribute('r-anim','1')">a</div>
        <video><source src="nothing.mp4" onerror="document.documentElement.setAttribute('r-source','1')"></video>
        <svg><animate attributeName="x" dur="10ms" onbegin="document.documentElement.setAttribute('r-onbegin','1')"/></svg>
        <a id="js" href="javascript:document.documentElement.setAttribute('r-jsurl','1')">click</a>
        <form id="f" action="javascript:document.documentElement.setAttribute('r-form','1')"><button>go</button></form>
        """

    @Test func noScriptRunsInAMail() async {
        let p = await RPage(HTMLPage.document(Self.scriptVectors, allowRemote: true))
        _ = await p.eval("document.getElementById('js').click(); document.getElementById('f').requestSubmit(); 1")
        try? await Task.sleep(for: .milliseconds(800))
        let r = await p.string("Array.from(document.documentElement.attributes).map(a => a.name).filter(n => n.startsWith('r-')).join(',')")
        #expect(r == "", "scripts that ran: \(r)")
    }

    // MARK: Nothing from the web without permission (loopback listener stands in for the sender's server)

    @Test func blockedMailRequestsNothing() async throws {
        let rec = try LoopbackRecorder()
        let base = "http://127.0.0.1:\(rec.port)"
        let mail = """
            <link rel="preconnect" href="\(base)/preconnect">
            <link rel="dns-prefetch" href="\(base)/dnsprefetch">
            <link rel="prefetch" href="\(base)/prefetch">
            <link rel="preload" as="image" href="\(base)/preload.png">
            <link rel="icon" href="\(base)/favicon.ico">
            <link rel="stylesheet" href="\(base)/style.css">
            <style>@import url("\(base)/import.css"); .b{background:url(\(base)/cssbg.png)} @font-face{font-family:F;src:url(\(base)/font.woff)} .f{font-family:F}</style>
            <body background="\(base)/bodybg.png">
            <img src="\(base)/img.png"><img srcset="\(base)/srcset.png 1x">
            <picture><source srcset="\(base)/source.png"><img src="data:image/png;base64,\(png1x1)"></picture>
            <video poster="\(base)/poster.png" src="\(base)/video.mp4" preload="auto"></video>
            <audio src="\(base)/audio.mp3" preload="auto"></audio>
            <input type="image" src="\(base)/input.png">
            <object data="\(base)/object"></object><embed src="\(base)/embed">
            <iframe src="\(base)/iframe"></iframe>
            <svg><image href="\(base)/svgimage.png" width="10" height="10"/></svg>
            <table background="\(base)/tablebg.png"><tr><td class="b f">x</td></tr></table>
            <script src="\(base)/script.js"></script>
            """
        _ = await RPage(HTMLPage.document(mail, allowRemote: false))
        try? await Task.sleep(for: .milliseconds(1500))
        #expect(rec.connections == 0 && rec.requests.isEmpty, "connections \(rec.connections), requests \(rec.requests)")
    }

    /// README: "No scripts, frames or fetches in either case" – also when remote content is allowed.
    @Test func allowedMailStillLoadsNoScriptsOrFrames() async throws {
        let rec = try LoopbackRecorder()
        let base = "http://127.0.0.1:\(rec.port)"
        let mail = """
            <script src="\(base)/script.js"></script>
            <iframe src="\(base)/iframe"></iframe>
            <object data="\(base)/object"></object><embed src="\(base)/embed">
            <link rel="prefetch" href="\(base)/prefetch">
            <img src="\(base)/img.png">
            """
        _ = await RPage(HTMLPage.document(mail, allowRemote: true))
        try? await Task.sleep(for: .milliseconds(1500))
        let bad = rec.requests.filter { !$0.contains("/img.png") }
        #expect(bad.isEmpty, "requests \(rec.requests)")
    }

    // MARK: Height (what HTMLBodyView measures vs. what the page draws)

    /// Many newsletters give the body padding instead of margin (`<body style="padding:24px 0">`).
    @Test func bodyPaddingIsInsideTheMeasuredHeight() async {
        let mail = #"<body style="margin:0;padding:40px 0"><table width="100%"><tr><td>Newsletter</td></tr></table><p>Unsubscribe</p></body>"#
        let p = await RPage(HTMLPage.document(mail, allowRemote: false), width: 600)
        let h = await p.settleLikeTheApp()
        let content = await p.contentHeight()
        #expect(h >= content, "measured \(h), page \(content)")
    }

    /// Content placed with position:absolute (some generated mails: invoices, PDF-to-HTML) is out of flow;
    /// the wrapper's box doesn't include it.
    @Test func absolutelyPlacedContentIsMeasured() async {
        let mail = #"<div style="position:relative"><div style="position:absolute;top:0;left:0;width:500px">Line<br>Line<br>Line<br>Line<br>Line<br>Line<br>Line<br>Line<br>Total: 120,00 €</div></div>"#
        let p = await RPage(HTMLPage.document(mail, allowRemote: false), width: 600)
        let h = await p.settleLikeTheApp()
        let content = await p.contentHeight()
        #expect(h >= content, "measured \(h), page \(content)")
    }

    /// MailChimp-style `height="100%"` body table: once the window is widened, the text needs less height; the
    /// view should get shorter again (a fresh load at the new width is the reference).
    static let percentTemplate = """
        <body style="margin:0;padding:0"><center><table align="center" border="0" cellpadding="0" cellspacing="0" height="100%" width="100%" id="bodyTable"><tr><td align="center" valign="top" id="bodyCell">
        <table border="0" cellpadding="0" cellspacing="0" width="100%" style="max-width:600px"><tr><td valign="top" style="padding:9px 18px;font-family:Helvetica;font-size:16px;line-height:150%">
        \(String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore. ", count: 30))
        </td></tr></table></td></tr></table></center></body>
        """

    @Test func percentHeightNewsletterShrinksWhenWindowWidens() async {
        let p = await RPage(HTMLPage.document(Self.percentTemplate, allowRemote: false), width: 320)
        let narrow = await p.settleLikeTheApp()
        await p.resize(width: 900)
        let widened = await p.measure()
        let fresh = await RPage(HTMLPage.document(Self.percentTemplate, allowRemote: false), width: 900)
        let reference = await fresh.measure()
        #expect(abs(widened - reference) <= 2, "narrow \(narrow), after widening \(widened), fresh load at that width \(reference)")
    }

    /// Same check for a plain mail (control: no percentage heights).
    @Test func controlPlainMailShrinksWhenWindowWidens() async {
        let mail = "<p>\(String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 40))</p>"
        let p = await RPage(HTMLPage.document(mail, allowRemote: false), width: 320)
        _ = await p.settleLikeTheApp()
        await p.resize(width: 900)
        let widened = await p.measure()
        let fresh = await RPage(HTMLPage.document(mail, allowRemote: false), width: 900)
        let reference = await fresh.measure()
        #expect(abs(widened - reference) <= 2, "after widening \(widened), fresh \(reference)")
    }

    /// A `height:100vh` hero block: measured at height 1, then the view grows and so does the block.
    @Test func viewportHeightBlockDoesNotOutgrowTheView() async {
        let mail = #"<div style="height:100vh;background:#eee">Hero</div><p>Read more</p><p id="last">Unsubscribe</p>"#
        let p = await RPage(HTMLPage.document(mail, allowRemote: false), width: 600)
        let h = await p.settleLikeTheApp()
        let lastBottom = ((await p.eval("document.getElementById('last').getBoundingClientRect().bottom")) as? NSNumber)?.doubleValue ?? -1
        #expect(lastBottom <= h, "measured \(h), last line ends at \(lastBottom)")
    }

    /// A form field with autofocus at the end scrolls the 1-pt-tall page at load; the measurement is relative
    /// to that scroll position.
    @Test func autofocusFieldDoesNotShortenTheMeasurement() async {
        let mail = "<p>\(String(repeating: "Survey intro text. ", count: 200))</p><form><input autofocus name=q></form>"
        let p = await RPage(HTMLPage.document(mail, allowRemote: false), width: 600)
        let scroll = ((await p.eval("window.scrollY")) as? NSNumber)?.doubleValue ?? -1
        let h = await p.measure()
        let content = await p.contentHeight()
        #expect(h >= content, "measured \(h), page \(content), scrollY \(scroll)")
    }

    // MARK: Width

    @Test func controlNarrowNewsletterHasNoHorizontalOverflow() async {
        let mail = """
            <style>@media only screen and (max-width:480px){ .c{width:100% !important} }</style>
            <table width="100%"><tr><td align="center"><table class="c" width="600" style="max-width:600px"><tr><td>
            Newsletter text with a link: <a href="https://example.com/x">read more</a>
            </td></tr></table></td></tr></table>
            """
        let p = await RPage(HTMLPage.document(mail, allowRemote: false), width: 420)
        let r = await p.string("document.documentElement.scrollWidth")
        #expect(r == "420", "scroll width \(r)")
    }

    // MARK: Direction, appearance, font

    @Test func controlRightToLeftMail() async {
        let mail = #"<html dir="rtl"><body><p id="p">שלום עולם</p></body></html>"#
        let p = await RPage(HTMLPage.document(mail, allowRemote: false))
        let r = await p.string("getComputedStyle(document.getElementById('p')).direction")
        #expect(r == "rtl")
    }

    @Test func darkMailCSSStaysLightInDarkMode() async {
        let mail = """
            <meta name="color-scheme" content="light dark"><style>:root{color-scheme:light dark} @media (prefers-color-scheme: dark){ body{background:#111 !important;color:#eee !important} }</style><p id="p">Hi</p>
            """
        let p = await RPage(HTMLPage.document(mail, allowRemote: false), dark: false)
        let r = await p.string("getComputedStyle(document.body).backgroundColor + '|' + getComputedStyle(document.getElementById('p')).color")
        #expect(r == "rgb(255, 255, 255)|rgb(0, 0, 0)", "\(r)")
    }

    @Test func defaultFontIsHelvetica14() async {
        let mail = #"<div id="d">Plain</div><font size="3" id="f">Sized</font><p style="font-size:medium" id="m">Medium</p>"#
        let p = await RPage(HTMLPage.document(mail, allowRemote: false))
        let r = await p.string("['d','f','m'].map(i => getComputedStyle(document.getElementById(i)).fontSize).join(' ') + '|' + getComputedStyle(document.getElementById('d')).fontFamily")
        #expect(r == "14px 14px 14px|Helvetica", "\(r)")
    }

    // MARK: More height cases

    /// position:fixed footer (seen in web-page-turned-newsletter mail): the view is as tall as the content, so the
    /// footer sits over the message's last lines for good.
    @Test func fixedFooterDoesNotCoverTheLastLine() async {
        let mail = #"<p>\#(String(repeating: "Body text. ", count: 100))</p><p id="last">Kind regards, Ann</p><div id="bar" style="position:fixed;bottom:0;left:0;right:0;height:60px;background:#333;color:#fff">Open in browser</div>"#
        let p = await RPage(HTMLPage.document(mail, allowRemote: false), width: 600)
        _ = await p.settleLikeTheApp()
        let r = await p.string("""
            (r => { const e = document.elementFromPoint(r.left + 5, r.top + r.height / 2); return e ? (e.id || e.tagName) : 'none' })(document.getElementById('last').getBoundingClientRect())
            """)
        #expect(r == "last", "element on top of the last line: \(r)")
    }

    /// <details> (and checkbox-driven "interactive email") change the page's height after it was measured.
    @Test func openingDetailsGrowsTheView() async {
        let mail = #"<details id="d"><summary>Show order</summary>\#(String(repeating: "<p>Item</p>", count: 20))</details><p>End</p>"#
        let p = await RPage(HTMLPage.document(mail, allowRemote: false), width: 600)
        let h = await p.settleLikeTheApp()
        _ = await p.eval("document.getElementById('d').open = true; 1")
        try? await Task.sleep(for: .milliseconds(300))
        let content = await p.contentHeight()
        // The app measures only on load and on width changes; nothing re-measures after this.
        #expect(content <= h, "view height \(h), page after opening \(content)")
    }

    @Test func lazyImageIsMeasured() async {
        let mail = #"<p>Top</p><img loading="lazy" style="display:block" src="data:image/png;base64,\#(png1x1)" width="1" height="1"><img loading="lazy" style="display:block;width:300px" src="data:image/png;base64,\#(png1x1)"><p>End</p>"#
        let p = await RPage(HTMLPage.document(mail, allowRemote: false), width: 600)
        let h = await p.settleLikeTheApp()
        try? await Task.sleep(for: .milliseconds(500))
        let content = await p.contentHeight()
        #expect(content <= h, "measured \(h), page \(content)")
    }

    // MARK: Blocked-image hiding vs. embedded pictures

    /// Embedded pictures need no permission; the blocked-image rule must not hide them.
    @Test func embeddedPicturesStayVisibleWhenRemoteBlocked() async {
        let d = "data:image/png;base64,\(png1x1)"
        let mail = """
            <img id="a" src=" \(d)" width="10" height="10">
            <img id="b" srcset="\(d) 1x" width="10" height="10">
            <picture><source srcset="\(d)"><img id="c" width="10" height="10"></picture>
            """
        let p = await RPage(HTMLPage.document(mail, allowRemote: false))
        let r = await p.string("['a','b','c'].map(i => { const e = document.getElementById(i); return i + ':' + getComputedStyle(e).visibility + ':' + (e.complete && e.naturalWidth > 0) }).join(' ')")
        #expect(r == "a:visible:true b:visible:true c:visible:true", "\(r)")
    }
}
