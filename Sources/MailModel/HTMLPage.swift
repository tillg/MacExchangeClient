import Foundation

/// The page an HTML body is shown in. Mail is untrusted: our Content-Security-Policy comes first, so it covers
/// everything the message brings. It allows no scripts, frames or requests, and nothing from the web unless `allowRemote`.
public enum HTMLPage {
    /// The page's doctype. The mail's own one lands inside our page, where the parser ignores it, so without ours
    /// every mail would be in quirks mode, where tables don't inherit the 14 px default. HTML 4.01 Transitional with
    /// its URL gives almost-standards mode: as in standards mode, except that a picture alone in a table cell gets no
    /// gap under it, which newsletters built from sliced pictures rely on.
    static let doctype = #"<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">"#

    /// The element whose height is the message's height.
    public static let bodyID = "mail-replica-body"

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
        // Like Mail's MUIWebDocument.css, with Mail's default message font. No colours, as there: the sender's
        // `<body bgcolor text>` apply, and without them the light colour scheme gives a white page and black text.
        return """
            \(doctype)
            <meta http-equiv="Content-Security-Policy" content="\(csp)">
            <meta name="color-scheme" content="light">
            <style>
            html { font: 14px Helvetica; }
            body { margin: 18px 20px 22px; padding: 0; word-wrap: break-word; word-break: break-word; }
            table { word-break: normal; }
            img[src^="cid:"] { display: none; }
            \(blocked)
            #\(bodyID) { display: flow-root; }
            </style>
            <div id="\(bodyID)">\(html)</div>
            """
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
