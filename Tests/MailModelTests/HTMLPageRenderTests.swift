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
