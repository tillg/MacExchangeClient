import Foundation
import Testing
import WebKit
@testable import MailModel

/// A real `WKWebView` configured and sized as `MailWebView` (HTMLBodyView.swift) does: loaded at the view's width
/// and 1 pt tall (where HTMLBodyView starts), measured with `HTMLPage.measureScript`, then given that height.
/// With `HTMLPage.resizeScript` installed, each of its messages is measured and sized again, as the app does.
@MainActor
final class BodyPage: NSObject, WKScriptMessageHandler {
    var v: WKWebView!
    private(set) var remeasured = 0

    init(_ mail: String, width: CGFloat = 600) async {
        super.init()
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        HTMLPage.observeResizes(config.userContentController, handler: self)
        v = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 1), configuration: config)
        v.appearance = NSAppearance(named: .aqua)
        HTMLPage.pinViewportUnits(of: v, to: CGSize(width: width, height: 700))
        v.loadHTMLString(HTMLPage.document(mail, allowRemote: false), baseURL: nil)
        try? await Task.sleep(for: .milliseconds(200))
        while v.isLoading { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .milliseconds(150))
    }

    nonisolated func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            remeasured += 1
            Task { _ = await self.settle() }
        }
    }

    func eval(_ js: String) async -> Double { ((try? await v.evaluateJavaScript(js)) as? NSNumber)?.doubleValue ?? -1 }

    func measure() async -> Double { await eval(HTMLPage.measureScript) }

    func resize(width: CGFloat? = nil, height: CGFloat? = nil) async {
        v.setFrameSize(NSSize(width: width ?? v.frame.width, height: height ?? v.frame.height))
        HTMLPage.pinViewportUnits(of: v, to: CGSize(width: v.frame.width, height: 700))
        v.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        _ = await eval("document.body.offsetHeight")  // lays the page out
    }

    /// What the app does once the page has loaded: measure, then give the view that height.
    func settle() async -> Double {
        let h = await measure()
        if h > 0 { await resize(height: h) }
        return h
    }

    /// Waits until the view holds everything the page draws (it re-measures by itself), at most `seconds`.
    func waitUntilItFits(seconds: Double = 15) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, await contentHeight() > v.frame.height { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// The height everything the page draws needs (at least the view's own height).
    func contentHeight() async -> Double {
        await eval("Math.max(document.documentElement.scrollHeight, document.body.scrollHeight)")
    }
}

/// The body view is as tall as its content, whatever the mail's markup, and the vertical scroll goes to the message
/// view, so anything below the measured height can't be reached.
@MainActor
@Suite(.serialized)
struct HTMLBodySizingTests {
    /// One `</div>` too many closes our wrapper early: the rest of the mail must still be measured.
    @Test func strayClosingDivDoesNotCutOffTheMail() async {
        let p = await BodyPage("<div><p>Hello</p></div></div><p style='height:600px'>Signature and the rest of the mail</p>")
        let content = await p.contentHeight()
        let h = await p.measure()
        #expect(h >= content && content > 600, "measured \(h), page \(content)")
    }

    /// A form field with `autofocus` scrolls the 1-pt page down to it at load: the measurement must not depend on
    /// where the page is scrolled.
    @Test func autofocusFieldDoesNotShortenTheMeasurement() async {
        let p = await BodyPage("<p>\(String(repeating: "Survey intro text. ", count: 200))</p><form><input autofocus name=q></form>")
        let scroll = await p.eval("window.scrollY")
        let content = await p.contentHeight()
        let h = await p.measure()
        #expect(h >= content, "measured \(h), page \(content), scrollY \(scroll)")
    }

    /// Newsletters give the body padding instead of margin; generated mail (invoices, PDF-to-HTML) places its text
    /// with `position: absolute`, out of flow. Both are part of the mail's height.
    @Test(arguments: [
        #"<body style="margin:0;padding:40px 0"><table width="100%"><tr><td>Newsletter</td></tr></table><p>Unsubscribe</p></body>"#,
        #"<div style="position:relative"><div style="position:absolute;top:0;left:0;width:500px">Line<br>Line<br>Line<br>Line<br>Line<br>Line<br>Line<br>Line<br>Total: 120,00 €</div></div>"#,
    ])
    func paddingAndPlacedContentAreMeasured(_ mail: String) async {
        let p = await BodyPage(mail)
        let content = await p.contentHeight()
        let h = await p.settle()
        #expect(h >= content, "measured \(h), page \(content)")
    }

    /// MailChimp's `height="100%"` body table, and mail that makes the page as tall as the window: once the window
    /// is widened, the view gets shorter again (a fresh load at the new width is the reference).
    nonisolated static let percentTemplate = """
        <body style="margin:0;padding:0"><center><table align="center" border="0" cellpadding="0" cellspacing="0" height="100%" width="100%" id="bodyTable"><tr><td align="center" valign="top" id="bodyCell">
        <table border="0" cellpadding="0" cellspacing="0" width="100%" style="max-width:600px"><tr><td valign="top" style="padding:9px 18px;font-family:Helvetica;font-size:16px;line-height:150%">
        \(String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore. ", count: 30))
        </td></tr></table></td></tr></table></center></body>
        """

    @Test(arguments: [percentTemplate, "<style>html, body { height: 100% !important; }</style><p>\(String(repeating: "Short mail. ", count: 60))</p>"])
    func windowHighMailShrinksWhenTheWindowWidens(_ mail: String) async {
        let p = await BodyPage(mail, width: 320)
        let narrow = await p.settle()
        await p.resize(width: 900)
        let widened = await p.measure()
        let reference = await BodyPage(mail, width: 900).measure()
        #expect(abs(widened - reference) <= 2, "narrow \(narrow), after widening \(widened), fresh load at that width \(reference)")
    }

    /// A `height: 100vh` block is measured at the view's start height of 1 pt, then grows with the view: viewport
    /// units must not follow the view's own height.
    @Test func viewportHeightBlockDoesNotOutgrowTheView() async {
        let p = await BodyPage(#"<div style="height:100vh;background:#eee">Hero</div><p>Read more</p><p id="last">Unsubscribe</p>"#)
        let h = await p.settle()
        let again = await p.measure()
        let lastBottom = await p.eval("document.getElementById('last').getBoundingClientRect().bottom")
        #expect(lastBottom <= h && again == h, "measured \(h), last line ends at \(lastBottom), measured again \(again)")
    }

    /// Content that grows after load: lazy pictures (loaded once the view has grown to them) and an opened
    /// `<details>`. The view must grow with it.
    @Test func lazyPicturesAreMeasured() async {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let p = await BodyPage(#"<p>Top</p><img loading="lazy" style="display:block" src="data:image/png;base64,\#(png)" width="1" height="1"><img loading="lazy" style="display:block;width:300px" src="data:image/png;base64,\#(png)"><p>End</p>"#)
        _ = await p.settle()
        await p.waitUntilItFits()
        let content = await p.contentHeight()
        #expect(content <= p.v.frame.height, "view \(p.v.frame.height), page \(content)")
    }

    @Test func openingDetailsGrowsTheView() async {
        let p = await BodyPage(#"<details id="d"><summary>Show order</summary>\#(String(repeating: "<p>Item</p>", count: 20))</details><p>End</p>"#)
        let closed = await p.settle()
        _ = await p.eval("document.getElementById('d').open = true; 1")  // what a click on the summary does
        await p.waitUntilItFits()
        let content = await p.contentHeight()
        #expect(content <= p.v.frame.height && p.v.frame.height > closed, "closed \(closed), view \(p.v.frame.height), page \(content)")
    }

    /// Re-measuring on every change must settle: a `100vh` block doesn't grow with the view it is measured in.
    @Test func remeasuringSettles() async {
        let p = await BodyPage(#"<div style="height:100vh">Hero</div><p>End</p>"#)
        _ = await p.settle()
        try? await Task.sleep(for: .milliseconds(1500))
        let count = p.remeasured, height = p.v.frame.height
        try? await Task.sleep(for: .milliseconds(1500))
        #expect(p.remeasured == count && p.v.frame.height == height && count < 10, "re-measured \(p.remeasured) times, view \(p.v.frame.height)")
    }

    /// The view gets shorter again when the window is widened (a fresh load at the new width is the reference).
    @Test func plainMailShrinksWhenTheWindowWidens() async {
        let mail = "<p>\(String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 40))</p>"
        let p = await BodyPage(mail, width: 320)
        _ = await p.settle()
        await p.resize(width: 900)
        let widened = await p.measure()
        let reference = await BodyPage(mail, width: 900).measure()
        #expect(abs(widened - reference) <= 2, "after widening \(widened), fresh \(reference)")
    }
}
