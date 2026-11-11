import Foundation

/// The page an HTML body is shown in. Mail is untrusted: our Content-Security-Policy comes first, so it covers
/// everything the message brings. It allows no scripts, frames or requests, and nothing from the web unless `allowRemote`.
public enum HTMLPage {
    /// The element whose height is the message's height.
    public static let bodyID = "mail-replica-body"

    public static func document(_ html: String, allowRemote: Bool) -> String {
        let csp = allowRemote
            ? "default-src 'none'; style-src * 'unsafe-inline'; img-src * data:; font-src * data:"
            : "default-src 'none'; style-src 'unsafe-inline'; img-src data:"
        // WebKit draws a blocked image as an outlined box with its alt text. Mail shows nothing but keeps the space.
        let blocked = allowRemote ? "" : #"img:not([src^="data:" i]) { visibility: hidden; }"#
        // Like Mail's MUIWebDocument.css, with Mail's default message font.
        return """
            <meta http-equiv="Content-Security-Policy" content="\(csp)">
            <meta name="color-scheme" content="light">
            <style>
            html, body { background: #fff; }
            html { font: 14px Helvetica; }
            body { margin: 18px 20px 22px; padding: 0; color: #000; word-wrap: break-word; word-break: break-word; }
            table { word-break: normal; }
            img[src^="cid:"] { display: none; }
            \(blocked)
            #\(bodyID) { display: flow-root; }
            </style>
            <div id="\(bodyID)">\(html)</div>
            """
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
    /// "Organisation" is the account's mail domain and its subdomains, plus Exchange's internal X.500 addresses.
    public func loadsAutomatically(from sender: Contact, account: Account) -> Bool {
        switch self {
        case .always: return true
        case .ask: return false
        case .organisation:
            let email = sender.email.lowercased()
            if email.hasPrefix("/o=") { return true }
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
