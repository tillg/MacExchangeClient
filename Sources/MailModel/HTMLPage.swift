import Foundation

/// The page an HTML body is shown in. Mail is untrusted: our Content-Security-Policy comes first, so it covers
/// everything the message brings. It allows no scripts, frames or requests, and nothing from the web unless `allowRemote`.
public enum HTMLPage {
    /// The page's doctype. The mail's own one lands inside our page, where the parser ignores it, so without ours
    /// every mail would be in quirks mode, where tables don't inherit the 14 px default. HTML 4.01 Transitional with
    /// its URL gives almost-standards mode: as in standards mode, except that a picture alone in a table cell gets no
    /// gap under it, which newsletters built from sliced pictures rely on.
    static let doctype = #"<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">"#

    /// Bar and text colour of Apple Mail quotes (`<blockquote type="cite">`), levels 1 to 3. Mail fills these in at
    /// run time; the values are recalled from Mail's "Color quoted text" defaults (blue, green, purple), not read.
    static let quoteColours = ["rgb(0, 64, 214)", "rgb(0, 128, 64)", "rgb(128, 0, 160)"]

    /// The element the message's HTML is put in.
    public static let bodyID = "mail-replica-body"

    /// The app's script for the message's height (app scripts run with content JavaScript off): the bottom of the
    /// root element, whose box holds the body with its margins. Not our wrapper: a stray `</div>` in the mail closes
    /// it early, and what follows lands outside it. Counted from the page's top, not the view's: a form field with
    /// `autofocus` scrolls the page at load. Content placed with `position: absolute` is outside every box: the
    /// body's `scrollHeight` counts it (plus the body's bottom margin). Neither depends on the view's own height,
    /// which `documentElement.scrollHeight` never drops below, so the view still shrinks when the window widens.
    public static let measureScript = """
        (() => {
            const b = document.body, root = document.documentElement.getBoundingClientRect().bottom;
            const placed = b.getBoundingClientRect().top + b.scrollHeight + parseFloat(getComputedStyle(b).marginBottom);
            return Math.ceil(Math.max(root, placed) + window.scrollY);
        })()
        """

    /// `inline` replaces `cid:` references with the message's own images, as `data:` URIs the policy allows.
    /// References without an image stay `cid:` and hidden.
    public static func document(_ html: String, allowRemote: Bool, inline: [String: InlineImage] = [:]) -> String {
        var html = inline.isEmpty ? html : replacingContentIDs(in: html) { id in
            inline[id].map { "data:\(safeType($0.contentType));base64,\($0.data.base64EncodedString())" }
        }
        if !allowRemote { html = withoutLinks(html) }
        let csp = allowRemote
            ? "default-src 'none'; style-src * 'unsafe-inline'; img-src * data:; font-src * data:"
            : "default-src 'none'; style-src 'unsafe-inline'; img-src data:"
        // WebKit draws a blocked image as an outlined box with its alt text. Mail shows nothing but keeps the space.
        let blocked = allowRemote ? "" : #"img:not([src^="data:" i]) { visibility: hidden; }"#
        // Like Mail's MUIWebDocument.css, with Mail's default message font. The root is never as tall as the view
        // (`html { height: 100% }` in mail): the view is as tall as the page, so that would never shrink again. Its `max-width` for Apple Mail's pictures
        // is written `max-inline-size` (the same in horizontal text): no other image is limited to its container. No colours, as there: the sender's
        // `<body bgcolor text>` apply, and without them the light colour scheme gives a white page and black text.
        return """
            \(doctype)
            <meta http-equiv="Content-Security-Policy" content="\(csp)">
            <meta name="color-scheme" content="light">
            <style>
            html { font: 14px Helvetica; }
            html:root { height: auto !important; min-height: 0 !important; }
            body { margin: 18px 20px 22px; padding: 0; word-wrap: break-word; word-break: break-word; }
            table { word-break: normal; }
            blockquote[type=cite] { padding-left: 8px; margin: 0; border-left: 2px solid \(quoteColours[0]); color: \(quoteColours[0]); }
            blockquote[type=cite] blockquote[type=cite] { border-left-color: \(quoteColours[1]); color: \(quoteColours[1]); }
            blockquote[type=cite] blockquote[type=cite] blockquote[type=cite] { border-left-color: \(quoteColours[2]); color: \(quoteColours[2]); }
            img.Apple-web-attachment { vertical-align: top !important; max-inline-size: 100% !important; }
            video.Apple-web-attachment { max-inline-size: 100% !important; }
            img[src^="cid:"] { display: none; }
            \(blocked)
            #\(bodyID) { display: flow-root; }
            </style>
            <div id="\(bodyID)">\(html)</div>
            """
    }

    /// Makes `vh`, `vw` and the other viewport units of the page in `webView` (a `WKWebView`) resolve against `size`
    /// instead of the view. The body view is as tall as its content, so a `100vh` block would otherwise grow with
    /// each measurement. WebKit has no public API for this; the private `_setViewportSizeForCSSViewportUnits:` is
    /// used when the web view has it. Returns whether it did.
    @MainActor @discardableResult
    public static func pinViewportUnits(of webView: NSObject, to size: CGSize) -> Bool {
        let selector = NSSelectorFromString("_setViewportSizeForCSSViewportUnits:")
        guard size.width > 0, size.height > 0, webView.responds(to: selector) else { return false }
        typealias Setter = @convention(c) (NSObject, Selector, CGSize) -> Void
        unsafeBitCast(webView.method(for: selector), to: Setter.self)(webView, selector, size)
        return true
    }

    /// The mail's `<link>` elements, renamed to an element that does nothing. WebKit opens connections for resource
    /// hints (`preconnect`, `dns-prefetch`, `prefetch`, `preload`, `prerender`) without asking the policy, which tells
    /// the sender the mail was opened. Everything else a link loads is blocked anyway while remote content is.
    /// Renaming needs only the tag's start, so no way of writing its attributes gets past it. Matched by scalar, as
    /// the HTML parser reads: by character, a combining mark after the `/` would hide the tag start.
    static func withoutLinks(_ html: String) -> String {
        html.replacing(/<(link)(?=[\s\/>])/.ignoresCase().matchingSemantics(.unicodeScalar), with: { _ in "<x-blocked-link" })
    }

    /// The sender's content type, reduced to a lowercased `type/subtype` of token characters (parameters dropped),
    /// else `application/octet-stream`: it goes into an attribute, so it must never carry quotes or markup.
    static func safeType(_ contentType: String) -> String {
        let t = contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        let token = "[a-z0-9!#$&^_.+-]+"
        return t.range(of: "^\(token)/\(token)$", options: .regularExpression) != nil ? t : "application/octet-stream"
    }

    /// The content IDs the HTML refers to with `cid:` (in `src`, `background` or CSS `url()`).
    public static func contentIDs(in html: String) -> Set<String> {
        var ids = Set<String>()
        _ = replacingContentIDs(in: html) { ids.insert($0); return nil }
        return ids
    }

    /// A reference runs to the closing quote, bracket or space, so `cid:a@x` never matches inside `cid:a@x2`.
    private static let cidReference = try! NSRegularExpression(pattern: #"cid:([^"'\s)>]+)"#, options: .caseInsensitive)

    /// Calls `replacement` with each referenced content ID (unescaped, without `<>`); nil keeps the reference.
    private static func replacingContentIDs(in html: String, _ replacement: (String) -> String?) -> String {
        let ns = html as NSString
        var out = html
        for m in cidReference.matches(in: html, range: NSRange(location: 0, length: ns.length)).reversed() {
            var id = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
            id = id.removingPercentEncoding ?? id
            id = id.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            guard let new = replacement(id), let r = Range(m.range, in: out) else { continue }
            out.replaceSubrange(r, with: new)
        }
        return out
    }

    /// Clicked links open elsewhere only for the web and mail. Other schemes (smb:, file:, app handlers) could
    /// launch programs or send the user's credentials.
    public static func opensLink(_ url: String) -> Bool {
        guard let scheme = URL(string: url)?.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto"].contains(scheme)
    }
}

/// What the body's web view lets happen: only the page the app loads, never a navigation the mail starts. A load
/// from a string arrives as `about:blank`, so that URL is allowed only between `willLoad()` and the load's commit;
/// afterwards a meta refresh or link to `about:blank` would replace the message with an empty page.
@MainActor public final class BodyNavigation {
    public enum Decision: Equatable { case allow, cancel, open(URL) }

    private var loading = false

    public init() {}

    /// Call right before each load of a page.
    public func willLoad() { loading = true }

    /// Call when a load commits: from then on everything is the mail's doing.
    public func didCommit() { loading = false }

    /// Clicked links open in the default app if `HTMLPage.opensLink`; links, redirects, meta refresh and frames
    /// are cancelled.
    public func decide(url: URL?, linkActivated: Bool) -> Decision {
        if loading, url?.absoluteString == "about:blank" { return .allow }
        if linkActivated, let url, HTMLPage.opensLink(url.absoluteString) { return .open(url) }
        return .cancel
    }
}

/// Outlook's "Download external images" setting. Images load straight from the sender's server, which tells
/// the sender the mail was opened and from where. There is no relay like Mail Privacy Protection.
public enum RemoteImages: String, CaseIterable, Sendable {
    case always, organisation, ask

    public static let defaultValue = RemoteImages.organisation

    public var title: String {
        switch self {
        case .always: "Always"
        case .organisation: "My organisation"
        case .ask: "Ask before downloading"
        }
    }

    /// Whether a mail from `sender` to `account` shows its remote content without the banner.
    /// "Organisation" is the account's mail domain and its subdomains, plus Exchange's internal X.500 addresses
    /// (`/o=…` without `@`).
    public func loadsAutomatically(from sender: Contact, account: Account) -> Bool {
        switch self {
        case .always: return true
        case .ask: return false
        case .organisation:
            let email = sender.email.lowercased()
            // X.500 addresses have no domain; "/o=…@domain" is an internet address in that domain.
            if email.hasPrefix("/o="), !email.contains("@") { return true }
            guard let domain = Self.domain(email), let own = Self.domain(account.address.lowercased()) else { return false }
            return domain == own || domain.hasSuffix("." + own)
        }
    }

    private static func domain(_ email: String) -> String? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        let d = email[email.index(after: at)...]
        return d.isEmpty ? nil : String(d)
    }
}

/// An image attached to a message and shown in its HTML through `cid:`.
public struct InlineImage: Hashable, Sendable {
    public var contentType: String
    public var data: Data
    public init(contentType: String, data: Data) { self.contentType = contentType; self.data = data }
}
