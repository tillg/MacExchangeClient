import Foundation
import Testing
@testable import EWS
@testable import MailModel

/// Reading the To and Cc fields into recipients (`Contact.parseList`).
struct ContactTests {
    func recipients(_ to: String) throws -> [String] {
        let draft = Draft(accountID: UUID(), to: to, subject: "s", body: "b")
        let xml = try XMLDocument(xmlString: EWSClient.envelope(EWSBackend.createRequest(draft, send: true)))
        return try #require(xml.first("Message")?.child("ToRecipients")).all("EmailAddress").compactMap(\.stringValue)
    }

    // BUG-005: quoted display names (RFC 5322).

    @Test func commaInsideAQuotedNameDoesNotSplit() {
        let c = Contact.parseList(#""Doe, John" <john.doe@x.com>, ann@y.com"#)
        #expect(c.map(\.email) == ["john.doe@x.com", "ann@y.com"])
        #expect(c.first?.name == "Doe, John")
    }

    @Test func quotesAroundANameAreRemoved() {
        #expect(Contact.parseList(#""John Doe" <john@x.com>"#).first?.name == "John Doe")
        #expect(Contact.parseList(#""Say \"hi\"; ok" <s@x.com>"#).map(\.name) == [#"Say "hi"; ok"#])
    }

    /// Outlook copies recipients as `Last, First <addr>`, without quotes: still one recipient.
    @Test func unquotedLastFirstNameStaysOneRecipient() throws {
        let c = Contact.parseList("Gartner, Till <till@x.com>, ann@y.com")
        #expect(c.map(\.email) == ["till@x.com", "ann@y.com"])
        #expect(c.first?.name == "Gartner, Till")
        #expect(try recipients(#""Gartner, Till" <till@x.com>"#) == ["till@x.com"])
        #expect(try recipients("Gartner, Till <till@x.com>") == ["till@x.com"])
    }

    // BUG-015: Outlook separates recipients with semicolons.

    @Test func semicolonsSeparateRecipients() throws {
        #expect(Contact.parseList("a@x.com; b@y.com").map(\.email) == ["a@x.com", "b@y.com"])
        #expect(Contact.parseList("Ann <a@x.com>;Bob <b@y.com>;").map(\.name) == ["Ann", "Bob"])
        #expect(try recipients("a@x.com; b@x.com") == ["a@x.com", "b@x.com"])
    }

    // BUG-016: no blanks or line breaks in an address.

    @Test func lineBreaksAndBlanksAroundAddressesAreTrimmed() {
        #expect(Contact.parseList("a@x.com, b@y.com\n").map(\.email) == ["a@x.com", "b@y.com"])
        #expect(Contact.parseList("\na@x.com,\r\n b@y.com").map(\.email) == ["a@x.com", "b@y.com"])
        #expect(Contact.parseList("Jane < jane@x.com >").first?.email == "jane@x.com")
    }

    /// A quote or `<` that never closes must not swallow the recipients after it.
    @Test func anUnclosedQuoteOrBracketDropsNoRecipient() {
        #expect(Contact.parseList(#"Bob "Bobby Smith <bob@x.com>, ann@y.com"#).map(\.email) == ["bob@x.com", "ann@y.com"])
        #expect(Contact.parseList("Ann <a@x.com, Bob <b@y.com>").map(\.email).last == "b@y.com")
        #expect(Contact.parseList("Ann <a@x.com, Bob <b@y.com>").count == 2)
    }

    /// What already worked stays as it was.
    @Test func plainListsParseAsBefore() {
        let c = Contact.parseList("a@b.com, Name <c@d.com>, ,Tom <tom+tag@bücher.de>")
        #expect(c.map(\.email) == ["a@b.com", "c@d.com", "tom+tag@bücher.de"])
        #expect(c.map(\.name) == ["a@b.com", "Name", "Tom"])
        #expect(Contact.parseList("<x@y.com>").first?.name == "x@y.com")
        #expect(Contact.parseList("").isEmpty)
    }

    /// Avatar initials: the first letters of the first two words, split on any space, never more than two letters.
    @Test func initialsSplitOnAnySpaceAndStayTwoLetters() {
        #expect(Contact(name: "Jane\u{00A0}Doe", email: "j@x").initials == "JD")
        #expect(Contact(name: "Jane\tDoe", email: "j@x").initials == "JD")
        #expect(Contact(name: "👨‍👩‍👧 Family Group", email: "f@x").initials == "👨‍👩‍👧F")
        #expect(Contact(name: "", email: "f@x").initials == "")
        #expect(Contact(name: "محمد علي", email: "m@x").initials == "مع")
        for name in ["ßtefan Müller", "ǆenan Kovač", "ﬀoo Bar"] {
            let i = Contact(name: name, email: "x@x.com").initials
            #expect(i.count <= 2, "\(name) -> \(i)")
        }
        #expect(Contact(name: "ßtefan Müller", email: "x@x.com").initials == "SM")
    }
}
