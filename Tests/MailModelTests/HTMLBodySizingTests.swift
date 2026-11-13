import Foundation
import Testing
import WebKit
@testable import MailModel

/// A real `WKWebView` configured and sized as `MailWebView` (HTMLBodyView.swift) does: loaded at the view's width
/// and 1 pt tall (where HTMLBodyView starts), measured with `HTMLPage.measureScript`, then given that height.
@MainActor
final class BodyPage {
    let v: WKWebView

    init(_ mail: String, width: CGFloat = 600) async {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        v = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 1), configuration: config)
        v.appearance = NSAppearance(named: .aqua)
        v.loadHTMLString(HTMLPage.document(mail, allowRemote: false), baseURL: nil)
        try? await Task.sleep(for: .milliseconds(200))
        while v.isLoading { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .milliseconds(150))
    }

    func eval(_ js: String) async -> Double { ((try? await v.evaluateJavaScript(js)) as? NSNumber)?.doubleValue ?? -1 }

    func measure() async -> Double { await eval(HTMLPage.measureScript) }

    func resize(width: CGFloat? = nil, height: CGFloat? = nil) async {
        v.setFrameSize(NSSize(width: width ?? v.frame.width, height: height ?? v.frame.height))
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
