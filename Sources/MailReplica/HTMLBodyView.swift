import AppKit
import MailModel
import SwiftUI
import WebKit

/// An HTML message body, as tall as its content, so it scrolls with the header in the message view.
/// Mail is untrusted: no JavaScript, no cookies, nothing from the web unless `allowRemote`, links open in the browser.
struct HTMLBodyView: View {
    let html: String
    let allowRemote: Bool
    @State private var height: CGFloat = 1

    var body: some View {
        MailWebView(html: html, allowRemote: allowRemote, height: $height)
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}

private struct MailWebView: NSViewRepresentable {
    let html: String
    let allowRemote: Bool
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> BodyWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let v = BodyWebView(frame: .zero, configuration: config)
        // Mail is written for a white page: Outlook sets dark text and no background.
        v.appearance = NSAppearance(named: .aqua)
        v.navigationDelegate = context.coordinator
        v.onWidthChange = { [weak coordinator = context.coordinator, weak v] in
            if let v { coordinator?.measure(v) }
        }
        return v
    }

    func updateNSView(_ v: BodyWebView, context: Context) {
        context.coordinator.parent = self
        let page = HTMLPage.document(html, allowRemote: allowRemote)
        // updateNSView runs on every store change; reloading would flicker and reset the page.
        guard context.coordinator.loaded != page else { return }
        context.coordinator.loaded = page
        v.loadHTMLString(page, baseURL: nil)
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: MailWebView
        var loaded: String?
        init(_ parent: MailWebView) { self.parent = parent }

        func measure(_ v: WKWebView) {
            // App scripts still run with content JavaScript off. Adds the body's bottom margin, which mail may change.
            v.evaluateJavaScript("""
                Math.ceil(document.getElementById('\(HTMLPage.bodyID)').getBoundingClientRect().bottom
                    + parseFloat(getComputedStyle(document.body).marginBottom))
                """) {
                [weak self] result, _ in
                guard let self, let h = result as? Double, h > 0, abs(h - parent.height) > 0.5 else { return }
                parent.height = h
            }
        }

        func webView(_ v: WKWebView, didFinish navigation: WKNavigation!) { measure(v) }

        func webView(_ v: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.request.url?.absoluteString == "about:blank" { return decisionHandler(.allow) }
            if action.navigationType == .linkActivated, let url = action.request.url, HTMLPage.opensLink(url.absoluteString) {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)  // links, redirects, meta refresh, frames
        }
    }
}

/// Hands vertical scrolling to the message view's scroll view; this view is always as tall as its content.
final class BodyWebView: WKWebView {
    var onWidthChange: (() -> Void)?
    private var lastWidth: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)  // wide newsletters still scroll sideways
        }
    }

    override func layout() {
        super.layout()
        if bounds.width != lastWidth {
            lastWidth = bounds.width
            onWidthChange?()
        }
    }
}
