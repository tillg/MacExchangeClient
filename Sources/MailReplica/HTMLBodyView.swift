import AppKit
import MailModel
import SwiftUI
import WebKit

/// An HTML message body, as tall as its content, so it scrolls with the header in the message view.
/// Mail is untrusted: no JavaScript, no cookies, nothing from the web unless `allowRemote`, links open in the browser.
struct HTMLBodyView: View {
    let html: String
    let allowRemote: Bool
    var inline: [String: InlineImage] = [:]
    @State private var height: CGFloat = 1

    var body: some View {
        MailWebView(html: html, allowRemote: allowRemote, inline: inline, height: $height)
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}

private struct MailWebView: NSViewRepresentable {
    let html: String
    let allowRemote: Bool
    let inline: [String: InlineImage]
    @Binding var height: CGFloat

    /// What the page is built from. Compared instead of the page, which can be megabytes with images in it.
    struct Inputs: Equatable { var html: String; var allowRemote: Bool; var inline: Set<String> }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> BodyWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let v = BodyWebView(frame: .zero, configuration: config)
        // Mail is written for a white page: Outlook sets dark text and no background.
        v.appearance = NSAppearance(named: .aqua)
        v.navigationDelegate = context.coordinator
        // Measures again when the page changes size after load (lazy pictures, an opened <details>). Only with viewport
        // units pinned to the window: otherwise a 100vh block would grow with every measurement.
        if HTMLPage.pinViewportUnits(of: v, to: CGSize(width: 1, height: 800)) {
            HTMLPage.observeResizes(v.configuration.userContentController, handler: context.coordinator)
        }
        v.onWidthChange = { [weak coordinator = context.coordinator, weak v] in
            if let v { coordinator?.measure(v) }
        }
        return v
    }

    func updateNSView(_ v: BodyWebView, context: Context) {
        context.coordinator.parent = self
        let inputs = Inputs(html: html, allowRemote: allowRemote, inline: Set(inline.keys))
        // updateNSView runs on every store change; reloading would flicker and reset the page.
        guard context.coordinator.loaded != inputs else { return }
        context.coordinator.loaded = inputs
        context.coordinator.navigation.willLoad()
        v.loadHTMLString(HTMLPage.document(html, allowRemote: allowRemote, inline: inline), baseURL: nil)
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MailWebView
        var loaded: Inputs?
        let navigation = BodyNavigation()
        init(_ parent: MailWebView) { self.parent = parent }

        func measure(_ v: WKWebView) {
            v.evaluateJavaScript(HTMLPage.measureScript) { [weak self] result, _ in
                guard let self, let h = result as? Double, h > 0, abs(h - parent.height) > 0.5 else { return }
                parent.height = h
            }
        }

        func webView(_ v: WKWebView, didFinish navigation: WKNavigation!) { measure(v) }

        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            if let v = message.webView { measure(v) }
        }

        func webView(_ v: WKWebView, didCommit navigation: WKNavigation!) { self.navigation.didCommit() }

        func webView(_ v: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            switch navigation.decide(url: action.request.url, linkActivated: action.navigationType == .linkActivated) {
            case .allow: decisionHandler(.allow)
            case .open(let url): NSWorkspace.shared.open(url); decisionHandler(.cancel)
            case .cancel: decisionHandler(.cancel)
            }
        }
    }
}

/// Hands vertical scrolling to the message view's scroll view; this view is always as tall as its content.
final class BodyWebView: WKWebView {
    var onWidthChange: (() -> Void)?
    private var lastWidth: CGFloat = 0
    private var lastViewport = CGSize.zero

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)  // wide newsletters still scroll sideways
        }
    }

    override func layout() {
        super.layout()
        // Viewport units (`100vh`) follow the window, not this view, which is as tall as the page.
        let viewport = CGSize(width: bounds.width, height: window?.contentLayoutRect.height ?? 800)
        if viewport != lastViewport, HTMLPage.pinViewportUnits(of: self, to: viewport) { lastViewport = viewport }
        if bounds.width != lastWidth {
            lastWidth = bounds.width
            onWidthChange?()
        }
    }
}
