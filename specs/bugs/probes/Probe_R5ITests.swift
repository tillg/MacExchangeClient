import Foundation
import Testing
@testable import EWS
@testable import MailModel

// Round-5 hunter I: text and encoding end to end. Every test here fails until its bug
// (specs/bugs/drafts/R5I-NN-*.md) is fixed; tests named `control…` pass and show the working neighbour case.

func probeR5IDoc(_ body: String) throws -> XMLDocument {
    try XMLDocument(xmlString: """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><s:Body>\(body)</s:Body></s:Envelope>
        """)
}

/// `EWSBackend.plainText`: the text of an HTML body when Exchange sends no (or a blank) `TextBody`.
struct Probe_R5I_PlainText {
    /// R5I-01: HTML collapses white space in text, so a line break in the source is a space; only markup makes lines.
    /// Outlook writes its HTML with CRLF breaks inside paragraphs and after each `<br>`.
    @Test func htmlSourceLineBreaksAreSpaces() {
        let t = EWSBackend.plainText("<p class=MsoNormal>Thanks for the\r\nquick reply,   Ann</p>")
        #expect(t == "Thanks for the quick reply, Ann", "\(t.debugDescription)")
        let v = EWSBackend.plainText("Line one<br>\r\nLine two")
        #expect(v == "Line one\nLine two", "\(v.debugDescription)")
    }

    /// R5I-02: block elements other than p/div/tr/li/h1-h6 start a new line: blockquote, hr, an unclosed <p>.
    @Test func otherBlockElementsBreakLines() {
        let quote = EWSBackend.plainText("<blockquote>Original text</blockquote>My answer")
        #expect(quote.contains("\n"), "\(quote.debugDescription)")
        let paras = EWSBackend.plainText("<p>First<p>Second")
        #expect(paras.contains("\n"), "\(paras.debugDescription)")
        let rule = EWSBackend.plainText("Above<hr>Below")
        #expect(rule.contains("\n"), "\(rule.debugDescription)")
    }

    /// R5I-03: a quoted attribute value may contain ">" (HTML tokenizer, attribute value states): the rest of the tag
    /// isn't text.
    @Test func greaterThanInQuotedAttributeIsNotText() {
        let t = EWSBackend.plainText(#"<img alt="->" src="x.png"><a title="a > b" href="x">Link</a>"#)
        #expect(t == "Link", "\(t.debugDescription)")
    }

    /// R5I-04: numeric references to 0x80-0x9F mean Windows-1252 characters (HTML Living Standard, numeric character
    /// reference end state): `&#146;` is ’, `&#128;` is €, `&#150;` is –. They become C1 control characters.
    @Test func c1NumericReferencesAreWindows1252() {
        let t = EWSBackend.plainText("It&#146;s &#128;5 &#150; ok")
        #expect(t == "It\u{2019}s \u{20AC}5 \u{2013} ok", "\(t.unicodeScalars.map { String($0.value, radix: 16) })")
        // The same rules make `&#0;` and a surrogate reference U+FFFD; they are kept as written.
        let z = EWSBackend.plainText("a&#0;b&#xD800;c")
        #expect(z == "a\u{FFFD}b\u{FFFD}c", "\(z.debugDescription)")
    }
}

@MainActor
@Suite(.serialized)
struct Probe_R5I_EWS {
    let acct = Account(name: "Exchange", address: "me@work.com")

    func getItem(_ item: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
        <m:GetItemResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" \
        xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><m:ResponseMessages>\
        <m:GetItemResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode><m:Items>\(item)</m:Items>\
        </m:GetItemResponseMessage></m:ResponseMessages></m:GetItemResponse></s:Body></s:Envelope>
        """
    }

    /// A store whose server answers every request with `response` (a `file://` fixture, so any bytes can be served),
    /// holding one unloaded Exchange message.
    func fileStore(_ response: Data) throws -> (MailStore, Message.ID) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("R5I-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ews.xml")
        try response.write(to: url)
        let s = MailStore(accounts: [], messages: [])
        s.add(acct, backend: EWSBackend(client: EWSClient(url: url, username: "u", password: "p")))  // file:// fixture
        s.setRemoteFolders([RemoteFolder(role: .inbox, id: "INBOX")], account: acct.id)
        let m = Message(accountID: acct.id, from: Contact(name: "Ann", email: ""), to: [], subject: "Hi", body: "",
                        date: .now, remoteID: "M1", serverPreview: "Preview", bodyLoaded: false)
        s.apply(SyncResult(upserts: [m], deletedRemoteIDs: [], token: "T0", more: false), account: acct.id, mailbox: .inbox)
        let id = try #require(s.messages.first { $0.remoteID == "M1" }?.id)
        return (s, id)
    }

    func item(_ text: String) -> String {
        "<t:Message><t:ItemId Id=\"M1\" ChangeKey=\"CK\"/><t:Body BodyType=\"Text\">\(text)</t:Body>"
            + "<t:TextBody BodyType=\"Text\">\(text)</t:TextBody><t:Attachments/>"
            + "<t:From><t:Mailbox><t:Name>Ann</t:Name><t:EmailAddress>ann@x.com</t:EmailAddress></t:Mailbox></t:From></t:Message>"
    }

    /// R5I-05: a body with one byte that isn't UTF-8 (a Latin-1 "é" from an old mail) or a raw control character
    /// fails the whole response: the message never opens, every showing asks again. The same page with an invalid
    /// character *reference* in it is repaired (`EWSClient.sanitize`; control test below).
    @Test func bodyWithNonUTF8ByteOrRawControlLoads() async throws {
        var bytes = Data(getItem(item("Caf")).utf8)
        let cut = try #require(bytes.range(of: Data("Caf<".utf8)))
        bytes.insert(0xE9, at: cut.lowerBound + 3)  // Body: "Caf\xE9"
        let (s, id) = try fileStore(bytes)
        await s.loadBody(id)
        #expect(s.message(id)?.bodyLoaded == true, "status: \(s.status ?? "")")

        let (s2, id2) = try fileStore(Data(getItem(item("Tab\u{0B}stop")).utf8))
        await s2.loadBody(id2)
        #expect(s2.message(id2)?.bodyLoaded == true, "status: \(s2.status ?? "")")
    }

    /// Control for R5I-05: an invalid reference in the same place is repaired and the body loads.
    @Test func controlInvalidReferenceIsRepaired() async throws {
        let (s, id) = try fileStore(Data(getItem(item("Tab&#11;stop")).utf8))
        await s.loadBody(id)
        #expect(s.message(id)?.bodyLoaded == true, "status: \(s.status ?? "")")
    }

    /// R5I-07 ⚠️: Exchange's own text version of an HTML mail writes each inline picture as "[cid:image001.png@…]".
    /// That reference isn't text: it shows in the list preview and is quoted in replies.
    @Test func cidPlaceholdersOfTextBodyAreNotShownOrQuoted() throws {
        let doc = try probeR5IDoc("""
            <t:Message><t:ItemId Id="M1"/><t:Body BodyType="HTML">&lt;img src="cid:image001.png@01DA1B2C.3D4E5F60"&gt;\
            &lt;p&gt;Hi Ann&lt;/p&gt;&lt;p&gt;Regards&lt;/p&gt;</t:Body>\
            <t:TextBody BodyType="Text">[cid:image001.png@01DA1B2C.3D4E5F60]\r\nHi Ann\r\n\r\nRegards\r\n</t:TextBody>\
            <t:Attachments><t:FileAttachment><t:AttachmentId Id="A1"/><t:Name>image001.png</t:Name>\
            <t:ContentType>image/png</t:ContentType><t:ContentId>image001.png@01DA1B2C.3D4E5F60</t:ContentId>\
            <t:IsInline>true</t:IsInline></t:FileAttachment></t:Attachments></t:Message>
            """)
        let m = Message(accountID: acct.id, from: Contact(name: "Ann", email: "ann@x.com"), to: [], subject: "Hi",
                        body: "", date: .now, bodyLoaded: false)
        let s = MailStore(accounts: [acct], messages: [m])
        s.setBody(EWSBackend.parseBody(try #require(doc.first("Message"))), for: m.id)
        let loaded = try #require(s.message(m.id))
        #expect(!loaded.preview.contains("[cid:"), "preview: \(loaded.preview)")
        let quote = s.draft(.reply, to: m.id).body
        #expect(!quote.contains("[cid:"), "quote: \(quote)")
    }

    /// Control: every user-entered field survives the request's XML as typed (markup, `]]>`, quotes, astral
    /// characters, bidi controls, tabs): it is read back from the envelope exactly.
    @Test func controlRequestFieldsRoundTrip() throws {
        let nasty = "a<b>&c \"q\" 'x' ]]> <![CDATA[ 😀 \u{202E}rtl\u{202C} \t end"
        var d = Draft(accountID: acct.id, to: "\"\(nasty.replacingOccurrences(of: "\"", with: "\\\""))\" <bob@x.com>",
                      subject: nasty, body: nasty)
        d.attachments = [DraftAttachment(name: nasty + ".txt", contentType: "text/plain", data: Data("x".utf8))]
        let create = try XMLDocument(xmlString: EWSClient.envelope(EWSBackend.createRequest(d, send: true)))
        #expect(create.text("Subject") == nasty)
        #expect(create.first("Message")?.child("Body")?.stringValue == nasty)
        #expect(create.first("ToRecipients")?.text("Name") == nasty)
        let att = try XMLDocument(xmlString: EWSClient.envelope(EWSBackend.createAttachmentRequest(parentID: "P", d.attachments)))
        #expect(att.text("Name") == nasty + ".txt")
        let answer = try XMLDocument(xmlString: EWSClient.envelope(
            EWSBackend.respondRequest("I1", InviteReply(response: .accept, comment: nasty))))
        #expect(answer.first("AcceptItem")?.child("Body")?.stringValue == nasty)
    }
}

@MainActor
struct Probe_R5I_Attachments {
    let work = Account(name: "Work", address: "me@work.com")

    /// R5I-08 ⚠️: ":" in a POSIX file name shows as "/" in the Finder. An attached message is named after its subject
    /// ("Re: Budget"), so it is written as a file the Finder and the Save panel call "Re/ Budget 10/30.eml".
    @Test func colonInNameIsNotShownAsSlashInFinder() {
        let a = MailModel.Attachment(name: "Re: Budget 10:30.eml", contentType: "message/rfc822")
        #expect(!a.fileName.contains(":"), "\(a.fileName) shows as \(a.fileName.replacingOccurrences(of: ":", with: "/"))")
    }

    /// R5I-09: an attachment named "Original" (no extension) that an app changed can't be saved: the fresh copy goes
    /// to "Original/Original", but "Original" is the opened file itself.
    @Test func attachmentNamedOriginalCanBeSavedAfterAnEdit() async throws {
        let m = Message(accountID: work.id, from: Contact(name: "Ann", email: "ann@x.com"), to: [], subject: "S",
                        body: "B", date: .now, attachments: [MailModel.Attachment(name: "Original", size: 3)])
        let s = MailStore(accounts: [work], messages: [m])
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("R5I-\(UUID().uuidString)")
        s.downloadsFolder = tmp
        defer { try? FileManager.default.removeItem(at: tmp) }
        s.setAttachmentData([Data([1, 2, 3])], for: m.id)
        let opened = try #require(await s.attachmentFile(0, of: m.id))
        try Data([9, 9, 9, 9, 9]).write(to: opened)  // an app saved its edit in place
        let saved = await s.saveAttachment(0, of: m.id, to: tmp.appendingPathComponent("Out"))
        #expect(saved != nil, "\(s.status ?? "")")
        if let saved { #expect(try Data(contentsOf: saved) == Data([1, 2, 3])) }
    }
}

struct Probe_R5I_Recipients {
}
