import Testing
@testable import MailModel

/// The page an HTML body is shown in: the Content-Security-Policy is what keeps mail from reaching the web.
struct HTMLPageTests {
    func csp(_ page: String) -> String {
        let start = page.range(of: #"http-equiv="Content-Security-Policy" content=""#)!.upperBound
        return String(page[start...].prefix { $0 != "\"" })
    }

    @Test func policyComesBeforeTheMessage() throws {
        let page = HTMLPage.document("<meta http-equiv=\"Content-Security-Policy\" content=\"img-src *\"><p>Hi</p>", allowRemote: false)
        let ours = try #require(page.range(of: "Content-Security-Policy"))
        let theirs = try #require(page.range(of: "img-src *"))
        #expect(ours.lowerBound < theirs.lowerBound)
    }

    @Test func blockedByDefaultNoScriptsEver() {
        let blocked = csp(HTMLPage.document("<p>Hi</p>", allowRemote: false))
        #expect(blocked.hasPrefix("default-src 'none'"))
        #expect(!blocked.contains("*") && !blocked.contains("http"))
        let allowed = csp(HTMLPage.document("<p>Hi</p>", allowRemote: true))
        #expect(allowed.hasPrefix("default-src 'none'") && allowed.contains("img-src *"))
        for p in [blocked, allowed] { #expect(!p.contains("script-src") && !p.contains("frame-src") && !p.contains("connect-src")) }
    }

    /// WebKit draws a blocked image as an outlined box with its alt text; Mail shows nothing, keeping the space.
    @Test func blockedImagesAreInvisibleUntilLoaded() {
        let rule = #"img:not([src^="data:" i]) { visibility: hidden; }"#
        #expect(HTMLPage.document("<p>Hi</p>", allowRemote: false).contains(rule))
        #expect(!HTMLPage.document("<p>Hi</p>", allowRemote: true).contains(rule))
    }

    /// Mail's MUIWebDocument.css with its default message font (Helvetica 14, measured against Mail) and margins.
    @Test func unstyledMailUsesMailsDefaultFontAndMargins() {
        let page = HTMLPage.document("<p>Hi</p>", allowRemote: false)
        #expect(page.contains("html { font: 14px Helvetica; }"))
        #expect(page.contains("margin: 18px 20px 22px;"))
        #expect(page.contains("word-break: break-word;"))
    }

    /// Some notification mails put avatars in zero-width boxes; `max-width: 100%` shrank them to nothing. Mail has no such rule.
    @Test func imagesAreNotLimitedToTheirContainer() {
        #expect(!HTMLPage.document("<p>Hi</p>", allowRemote: true).contains("max-width"))
    }

    @Test func onlyWebAndMailLinksAreOpened() {
        #expect(HTMLPage.opensLink("https://x.example/a"))
        #expect(HTMLPage.opensLink("HTTP://x.example"))
        #expect(HTMLPage.opensLink("mailto:a@x.example"))
        for bad in ["smb://server/share", "file:///etc/passwd", "ssh://host", "javascript:alert(1)", "x-apple.systempreferences:"] {
            #expect(!HTMLPage.opensLink(bad))
        }
    }

    // MARK: Download external images (Outlook's setting)

    let me = Account(name: "Work", address: "alex.morgan@northwind.example")
    func from(_ email: String) -> Contact { Contact(name: "X", email: email) }

    @Test func organisationLoadsForOwnDomainAndSubdomains() {
        let org = RemoteImages.organisation
        #expect(org.loadsAutomatically(from: from("ci-noreply@northwind.example"), account: me))
        #expect(org.loadsAutomatically(from: from("no-reply@builds.NORTHWIND.example"), account: me))
        #expect(!org.loadsAutomatically(from: from("news@tidewater.example"), account: me))
        #expect(!org.loadsAutomatically(from: from("evil@notnorthwind.example"), account: me))
        #expect(!org.loadsAutomatically(from: from("x@northwind.example.evil.example"), account: me))
        #expect(!org.loadsAutomatically(from: from(""), account: me))
    }

    /// Exchange gives internal senders without an SMTP address an X.500 address.
    @Test func organisationLoadsForExchangeInternalAddresses() {
        #expect(RemoteImages.organisation.loadsAutomatically(
            from: from("/O=NORTHWIND/OU=EXCHANGE ADMINISTRATIVE GROUP/CN=RECIPIENTS/CN=AMORGAN"), account: me))
    }

    @Test func alwaysAndAsk() {
        #expect(RemoteImages.always.loadsAutomatically(from: from("news@tidewater.example"), account: me))
        #expect(!RemoteImages.ask.loadsAutomatically(from: from("ci-noreply@northwind.example"), account: me))
        #expect(RemoteImages.defaultValue == .organisation)
    }
}
