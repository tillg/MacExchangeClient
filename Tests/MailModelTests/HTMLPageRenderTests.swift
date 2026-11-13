import Foundation
import Network
import Testing
import WebKit
@testable import MailModel

/// `HTMLPage` in a real `WKWebView`, configured as `MailWebView` (HTMLBodyView.swift) does, with a listener on
/// 127.0.0.1 standing in for the sender's server. Nothing leaves the machine.
@MainActor
struct HTMLPageRenderTests {
    /// Loads the page as the app does (content JavaScript off, non-persistent store) and waits until it has loaded.
    func show(_ page: String) async -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let v = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 1), configuration: config)
        v.appearance = NSAppearance(named: .aqua)
        v.loadHTMLString(page, baseURL: nil)
        let deadline = Date().addingTimeInterval(30)
        try? await Task.sleep(for: .milliseconds(200))
        while v.isLoading && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return v
    }

    /// Runs `script` on the page as the app shows it; its result as text.
    func eval(_ page: String, _ script: String) async -> String {
        let v = await show(page)
        return (try? await v.evaluateJavaScript(script)).map { "\($0)" } ?? "nil"
    }

    /// Newsletters and Outlook templates set the page colour with `<body bgcolor text>`: our page must not override it.
    @Test func sendersBodyColoursAreKept() async {
        let colours = "getComputedStyle(document.body).backgroundColor + '|' + getComputedStyle(document.getElementById('t')).color"
        let font = ##"<html><body bgcolor="#000000"><font id=t color="#ffffff">White text on the sender's black page</font></body></html>"##
        #expect(await eval(HTMLPage.document(font, allowRemote: false), colours) == "rgb(0, 0, 0)|rgb(255, 255, 255)")
        let text = ##"<html><body bgcolor="#000000" text="#ffffff"><p id=t>Dark newsletter</p></body></html>"##
        #expect(await eval(HTMLPage.document(text, allowRemote: false), colours) == "rgb(0, 0, 0)|rgb(255, 255, 255)")
    }

    /// Mail's 14 px default reaches text in tables (signatures, Outlook layouts): no quirks mode resetting tables to 16 px.
    @Test func tableTextGetsTheDefaultFontSize() async {
        let withDoctype = "<!DOCTYPE html><html><body><table><tr><td id=c>Kind regards</td></tr></table></body></html>"
        #expect(await eval(HTMLPage.document(withDoctype, allowRemote: false),
                           "document.compatMode + '|' + getComputedStyle(document.getElementById('c')).fontSize") == "CSS1Compat|14px")
        let plain = "<p id=p>Hi,</p><table><tr><td id=c>Kind regards<br>Ann</td></tr></table>"
        #expect(await eval(HTMLPage.document(plain, allowRemote: false),
                           "getComputedStyle(document.getElementById('p')).fontSize + '|' + getComputedStyle(document.getElementById('c')).fontSize") == "14px|14px")
    }

    /// Newsletters build their layout from pictures in table cells: as in almost-standards mode, a cell holding
    /// only a picture is as tall as the picture (full standards mode would add a gap under it).
    @Test func pictureInATableCellLeavesNoGap() async {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let mail = "<table cellpadding=0 cellspacing=0><tr><td id=t><img src='data:image/png;base64,\(png)' width=10 height=10></td></tr></table>"
        #expect(await eval(HTMLPage.document(mail, allowRemote: false), "document.getElementById('t').getBoundingClientRect().height") == "10")
    }

    /// Apple Mail quotes as `<blockquote type="cite">`; Mail draws it with its quote bar (MUIWebDocument.css):
    /// no margin, 8 px padding, a 2 px bar on the left, another colour for each of three levels.
    @Test func appleMailQuoteHasMailsQuoteBar() async {
        let mail = """
            <div dir="ltr">Sounds good.</div><div><br><blockquote type="cite" id="q1"><div>On 12 Nov 2026, at 09:14, Ann Lee &lt;ann@example.com&gt; wrote:</div><br><div>Shall we meet at 10?</div>\
            <blockquote type="cite" id="q2">Earlier<blockquote type="cite" id="q3">Even earlier</blockquote></blockquote></blockquote></div>
            """
        let r = await eval(HTMLPage.document(mail, allowRemote: false), """
            ['q1','q2','q3'].map(id => (s => [s.borderLeftWidth, s.borderLeftStyle, s.marginLeft, s.marginRight, s.paddingLeft, s.borderLeftColor].join(' '))(getComputedStyle(document.getElementById(id)))).join('|')
            """)
        let levels = r.split(separator: "|").map { $0.split(separator: " ", maxSplits: 5).map(String.init) }
        #expect(levels.count == 3 && levels.allSatisfy { Array($0.prefix(5)) == ["2px", "solid", "0px", "0px", "8px"] }, "\(r)")
        #expect(Set(levels.compactMap { $0.last }).count == 3, "each level has its own colour: \(r)")
    }

    /// Mail caps pictures sent by Apple Mail (`img.Apple-web-attachment`) at the page width.
    @Test func appleMailPictureFitsTheWindow() async {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let mail = #"<div>Look:</div><div><img class="Apple-web-attachment Singleton" id="i" width="3024" height="40" src="data:image/png;base64,\#(png)"></div>"#
        let r = await eval(HTMLPage.document(mail, allowRemote: false), "document.getElementById('i').getBoundingClientRect().width + '|' + document.documentElement.scrollWidth")
        #expect(r == "560|600", "picture width|page scroll width = \(r)")
    }

    /// Fonts embedded in the mail (`data:`) load with remote content blocked.
    @Test func embeddedDataFontsLoadWithoutRemoteContent() async throws {
        let font = try Data(contentsOf: URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/NotoSansCarian-Regular.ttf"))
        let mail = "<style>@font-face { font-family: Embedded; src: url(data:font/ttf;base64,\(font.base64EncodedString())); }"
            + " p { font-family: Embedded, Helvetica; }</style><p>Embedded font</p>"
        let v = await show(HTMLPage.document(mail, allowRemote: false))
        try? await Task.sleep(for: .milliseconds(1000))
        let r = (try? await v.evaluateJavaScript("Array.from(document.fonts).map(f => f.family + ':' + f.status).join(',')")) as? String
        #expect(r == "Embedded:loaded", "\(String(describing: r))")
    }

    /// Apple Mail's dashed lists and nested numbered lists, as in Mail's MUIWebDocument.css.
    @Test func appleMailListStyles() async {
        let mail = #"<ul class="Apple-dash-list" id="u"><li id="l">one</li></ul><ol><li>a<ol id="o2"><li>b<ol id="o3"><li>c</li></ol></li></ol></li></ol>"#
        let r = await eval(HTMLPage.document(mail, allowRemote: false),
                           "['u','o2','o3'].map(id => getComputedStyle(document.getElementById(id)).listStyleType).join(' ') + '|' + getComputedStyle(document.getElementById('l'), '::before').content")
        #expect(r == "none lower-alpha lower-roman|\"\u{2013}\"", "\(r)")
        // The mail's own numbering wins.
        let own = #"<ol><li>a<ol type="A" id="t"><li>b</li></ol><ol id="s" style="list-style-type: upper-roman"><li>c</li></ol></li></ol>"#
        #expect(await eval(HTMLPage.document(own, allowRemote: false),
                           "['t','s'].map(id => getComputedStyle(document.getElementById(id)).listStyleType).join(' ')") == "upper-alpha upper-roman")
    }

    /// Received mail is never editable, whatever `contenteditable` it carries.
    @Test func contentEditableMailIsNotEditable() async {
        let mail = #"<div contenteditable="true" id="e">Type here to change what I wrote</div>"#
        let r = await eval(HTMLPage.document(mail, allowRemote: false),
                           "document.getElementById('e').isContentEditable + '|' + getComputedStyle(document.getElementById('e')).webkitUserModify")
        #expect(r == "false|read-only", "\(r)")
    }

    /// Pictures embedded in the mail need no permission: with remote content blocked they stay visible, also with
    /// a space before `data:`, from `srcset`, or from a `<picture>` source. A blocked one stays hidden.
    @Test func embeddedPicturesStayVisibleWhenRemoteBlocked() async {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let d = "data:image/png;base64,\(png)"
        let mail = """
            <img id="a" src=" \(d)" width="10" height="10">
            <img id="b" srcset="\(d) 1x" width="10" height="10">
            <picture><source srcset="\(d)"><img id="c" width="10" height="10"></picture>
            <img id="d" src="http://127.0.0.1:9/x.png" width="10" height="10">
            """
        let r = await eval(HTMLPage.document(mail, allowRemote: false),
                           "['a','b','c','d'].map(i => { const e = document.getElementById(i); return i + ':' + getComputedStyle(e).visibility + ':' + (e.complete && e.naturalWidth > 0) }).join(' ')")
        #expect(r == "a:visible:true b:visible:true c:visible:true d:hidden:false", "\(r)")
    }

    /// A mail that refreshes or links to `about:blank` must not replace itself with an empty page; the app's own
    /// loads (a second one when remote content is allowed) still show.
    @Test func mailCannotNavigateToAnEmptyPage() async {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let v = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 1), configuration: config)
        let delegate = NavigationDelegate()
        v.navigationDelegate = delegate
        func load(_ mail: String) async {
            delegate.navigation.willLoad()
            v.loadHTMLString(HTMLPage.document(mail, allowRemote: false), baseURL: nil)
            try? await Task.sleep(for: .milliseconds(200))
            while v.isLoading { try? await Task.sleep(for: .milliseconds(50)) }
            try? await Task.sleep(for: .milliseconds(600))
        }
        func text() async -> String { (try? await v.evaluateJavaScript("document.body ? document.body.innerText.trim() : ''")) as? String ?? "nil" }
        await load(#"<p>Your invoice 4711</p><meta http-equiv="refresh" content="0;url=about:blank">"#)
        #expect(await text() == "Your invoice 4711")
        await load(#"<p>Second load</p><a id="a" href="about:blank">x</a>"#)
        #expect(await text().hasPrefix("Second load"))
        _ = try? await v.evaluateJavaScript("document.getElementById('a').click(); 1")
        try? await Task.sleep(for: .milliseconds(600))
        #expect(await text().hasPrefix("Second load"))
        #expect(delegate.navigation.decide(url: URL(string: "https://x.example/a"), linkActivated: true) == .open(URL(string: "https://x.example/a")!))
        #expect(delegate.navigation.decide(url: URL(string: "file:///etc/passwd"), linkActivated: true) == .cancel)
    }

    nonisolated static let blockedVectors: [String] = [
        #"<link rel="preconnect" href="BASE/preconnect">"#,
        "<link/\u{301} rel=preconnect href=BASE/preconnect-mark>",
        "<link \u{200D}rel=preconnect href=BASE/preconnect-zwj>",
        #"<link rel="dns-prefetch" href="BASE/dnsprefetch">"#,
        #"<link rel="prefetch" href="BASE/prefetch">"#,
        #"<link rel="preload" as="image" href="BASE/preload.png">"#,
        #"<link rel="prerender" href="BASE/prerender">"#,
        #"<link rel="icon" href="BASE/favicon.ico">"#,
        #"<link rel="stylesheet" href="BASE/style.css">"#,
        #"<style>@import url("BASE/import.css");</style>"#,
        #"<img src="BASE/img.png">"#,
        #"<video poster="BASE/poster.png" src="BASE/video.mp4" preload="auto"></video>"#,
        #"<iframe src="BASE/iframe"></iframe>"#,
        #"<a href="BASE/link">link</a>"#,
        #"<form action="BASE/form"><input name=q></form>"#,
    ]

    /// With remote content blocked, opening a mail opens no connection to the sender's server: not even the
    /// handshake a resource hint such as `<link rel="preconnect">` makes, which the policy doesn't cover.
    @Test(arguments: blockedVectors)
    func blockedMailConnectsNowhere(_ vector: String) async throws {
        let server = try LoopbackListener()
        let mail = "<p>Hello</p>" + vector.replacingOccurrences(of: "BASE", with: "http://127.0.0.1:\(server.port)")
        let view = await show(HTMLPage.document(mail, allowRemote: false))
        try? await Task.sleep(for: .milliseconds(1200))
        #expect(server.connections == 0, "\(vector): connections \(server.connections), requests \(server.requests)")
        _ = view
    }
}

/// Hands WebKit's navigation questions to `BodyNavigation`, as `MailWebView`'s coordinator does.
@MainActor
final class NavigationDelegate: NSObject, WKNavigationDelegate {
    let navigation = BodyNavigation()

    func webView(_ v: WKWebView, didCommit navigation: WKNavigation!) { self.navigation.didCommit() }

    func webView(_ v: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let d = navigation.decide(url: action.request.url, linkActivated: action.navigationType == .linkActivated)
        decisionHandler(d == .allow ? .allow : .cancel)
    }
}

/// A listener on 127.0.0.1 only, recording the connections and request lines it gets.
final class LoopbackListener: @unchecked Sendable {
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
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx"
                c.send(content: Data(response.utf8), completion: .contentProcessed { _ in c.cancel() })
            }
        }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    deinit { listener.cancel() }
}
