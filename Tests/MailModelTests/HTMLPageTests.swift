import Foundation
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

    // MARK: Inline images (cid:)

    @Test func contentIDsReferencedByTheHTML() {
        let html = #"<img src="cid:image001.png@01DA0001.2B3C4D50"><img src='cid:part1.abc'>"#
            + #"<td style="background:url(cid:bg%40x)"><img src="cid:&lt;angle@x&gt;"><a href="cid:not-an-image">"#
        #expect(HTMLPage.contentIDs(in: html) == ["image001.png@01DA0001.2B3C4D50", "part1.abc", "bg@x", "angle@x", "not-an-image"])
        #expect(HTMLPage.contentIDs(in: "<p>No images</p>").isEmpty)
    }

    @Test func inlineImagesBecomeDataURIs() {
        let png = InlineImage(contentType: "image/png", data: Data([1, 2, 3]))
        let html = #"<img src="cid:image001.png@x"><img src="cid:image001.png@x2"><img src="cid:unknown@x">"#
        let page = HTMLPage.document(html, allowRemote: false, inline: ["image001.png@x": png])
        #expect(page.contains(#"<img src="data:image/png;base64,AQID">"#))
        #expect(page.contains(#"<img src="cid:image001.png@x2">"#))  // a longer ID that starts the same is not this image
        #expect(page.contains(#"<img src="cid:unknown@x">"#))         // stays, and stays hidden
    }

    /// The content type comes from the sender: only a plain `type/subtype` goes into the page, never markup.
    @Test func inlineImageContentTypeCannotInjectMarkup() {
        let html = #"<img src="cid:a@x">"#
        func page(_ type: String) -> String {
            HTMLPage.document(html, allowRemote: false, inline: ["a@x": InlineImage(contentType: type, data: Data([1]))])
        }
        let evil = page(#"image/png" onload="x" data-x=""#)
        #expect(!evil.contains("onload"))
        #expect(evil.contains(#"<img src="data:application/octet-stream;base64,AQ==">"#))
        #expect(!page("image/png><script>x</script>").contains("<script>"))
        #expect(page(#"image/png; name="a.png""#).contains(#"<img src="data:image/png;base64,AQ==">"#))
        #expect(page("Image/SVG+XML").contains(#"<img src="data:image/svg+xml;base64,AQ==">"#))
        #expect(page("").contains(#"<img src="data:application/octet-stream;base64,AQ==">"#))
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

    /// `<link>` resource hints (preconnect, dns-prefetch, prefetch, preload, prerender) reach the sender's server
    /// although the policy blocks everything: with remote content blocked, no `<link>` of the mail stays a link,
    /// however it is written.
    @Test(arguments: [
        #"<link rel="preconnect" href="https://t.example/">"#,
        #"<LINK REL="DNS-Prefetch" HREF="//t.example">"#,
        #"<link rel=prefetch href=https://t.example/a>"#,
        #"<link href="https://t.example/p.png" as="image" rel="preload">"#,
        #"<link rel="icon prerender" href="https://t.example/">"#,
        "<link\nrel=\"preconnect\"\nhref=\"https://t.example/\">",
        #"<link/rel="preconnect" href="https://t.example/"/>"#,
        "<link\trel=preconnect href=https://t.example/>",
    ])
    func blockedMailKeepsNoLinkElement(_ link: String) {
        let page = HTMLPage.document("<p>Hi</p>" + link + "<p>Bye</p>", allowRemote: false)
        #expect(page.range(of: #"<link[\s/>]"#, options: [.regularExpression, .caseInsensitive]) == nil, "\(page)")
        #expect(page.contains("<p>Hi</p>") && page.contains("<p>Bye</p>"))
    }

    /// Allowed remote content keeps the mail's links (its stylesheets load then), and words like "linked" stay.
    @Test func allowedMailAndTextKeepTheirLinks() {
        let link = #"<link rel="stylesheet" href="https://t.example/s.css">"#
        #expect(HTMLPage.document(link, allowRemote: true).contains(link))
        #expect(HTMLPage.document("<p>linked &lt;link&gt; <linkage></p>", allowRemote: false).contains("<p>linked &lt;link&gt; <linkage></p>"))
    }
}
