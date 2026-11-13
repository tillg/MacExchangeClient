import Foundation
import Testing
@testable import EWS
@testable import MailModel

/// Round 5, hunter M: accounts and settings (pure helpers only: the server field and the privacy domain rule; the
/// Keychain is never touched), Settings ▸ Viewing, and search together with the rest of the store. Real MailStore,
/// a real MailDatabase for the index path; no mocks.
@MainActor
@Suite(.serialized)
struct Probe_R5MAccounts {
    func url(_ server: String) -> URL? { ExchangeAccount(email: "me@work.com", username: "DOMAIN\\me", server: server).ewsURL }

    /// R5M-03: malformed input becomes a URL to another host or without the EWS path, instead of "Invalid server".
    @Test func malformedServerIsInvalidNotAnotherHost() {
        for s in ["ftp://mail.example.com", "https:/mail.example.com", "https//mail.example.com", "mail.example.com?x",
                  "mail.example.com#frag", "mail.example.com:99999"] {
            let u = url(s)
            #expect(u == nil || (u?.host == "mail.example.com" && u?.path == "/EWS/Exchange.asmx" && u?.query == nil
                                 && u?.fragment == nil && (u?.port ?? 443) <= 65535),
                    "\(s) -> \(u?.absoluteString ?? "nil") (host \(u?.host ?? "nil"), path \(u?.path ?? "nil"))")
        }
    }

    /// R5M-05: an IPv6 address typed without brackets is "Invalid server".
    @Test func bareIPv6AddressIsAServer() {
        #expect(url("2001:db8::1")?.absoluteString == "https://[2001:db8::1]/EWS/Exchange.asmx")
        #expect(url("fd00::25")?.absoluteString == "https://[fd00::25]/EWS/Exchange.asmx")
    }
}

@MainActor
@Suite(.serialized)
struct Probe_R5MPrivacy {
    func loads(_ sender: String, own: String) -> Bool {
        RemoteImages.organisation.loadsAutomatically(from: Contact(name: "", email: sender), account: Account(name: own, address: own))
    }

    /// R5M-06: "My organisation" compares domains as text: an international domain in Unicode vs its xn-- form,
    /// or a trailing root dot, counts as outside the organisation.
    @Test func sameDomainInAnotherSpellingIsTheOrganisation() {
        #expect(loads("kollege@xn--bcher-kva.de", own: "me@bücher.de"))
        #expect(loads("kollege@bücher.de", own: "me@xn--bcher-kva.de"))
        #expect(loads("kollege@work.com.", own: "me@work.com"))
    }
}

@MainActor
@Suite(.serialized)
struct Probe_R5MStore {
    let work = Account(name: "Work", address: "me@work.com")

    func mk(_ a: Account, _ subject: String, box: MailboxKind = .inbox, minutesAgo: Double = 1, read: Bool = false,
            conv: String? = nil) -> Message {
        var m = Message(accountID: a.id, mailbox: box, from: Contact(name: "Ann", email: "ann@x.com"),
                        to: [Contact(name: "Me", email: a.address)], subject: subject, body: "",
                        date: Date(timeIntervalSinceNow: -minutesAgo * 60), isRead: read, remoteID: "R-\(UUID())")
        m.conversationID = conv
        return m
    }

    func searchDB(_ msgs: [Message]) throws -> (MailDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Probe_R5M-\(UUID())/Mail.sqlite")
        let db = try MailDatabase(url: url)
        try db.write(StoreChanges(upserts: msgs))
        try db.prepareSearch()
        return (db, url)
    }

    /// R5M-08: with conversations and the unread filter on, open a conversation row (all its messages become read and
    /// count as opened), then turn conversations off in Settings ▸ Viewing: the row's other messages stay in the
    /// unread-filtered list though they are read and not selected.
    @Test func turningConversationsOffLetsGoOfUnselectedReadMessages() {
        let a = mk(work, "Plan", minutesAgo: 1, conv: "C1"), b = mk(work, "Re: Plan", minutesAgo: 2, conv: "C1"),
            c = mk(work, "Re: Re: Plan", minutesAgo: 3, conv: "C1"), other = mk(work, "Other", minutesAgo: 4)
        let s = MailStore(accounts: [work], messages: [a, b, c, other])
        s.groupsConversations = true
        s.selectedMailbox = .account(work.id, .inbox)
        s.filterUnread = true
        s.listSelection = [a.id]
        s.markSelectionRead()
        s.groupsConversations = false
        let list = s.visibleMessages.map(\.subject)
        #expect(!list.contains("Re: Plan") && !list.contains("Re: Re: Plan"),
                "read, unselected messages listed under the unread filter: \(list), selected \(s.selection.compactMap { s.message($0)?.subject })")
    }

    /// R5M-09: two results of one conversation selected while searching (the list isn't grouped then); clearing
    /// the search shows them as one selected row, but no message is open: the pane says "2 messages selected" and
    /// Reply is disabled.
    @Test func oneSelectedRowAfterClearingTheSearchOpensIt() {
        let a = mk(work, "Report", minutesAgo: 1, read: true, conv: "C1"), b = mk(work, "Re: Report", minutesAgo: 2, read: true, conv: "C1"),
            other = mk(work, "Other", minutesAgo: 4, read: true)
        let s = MailStore(accounts: [work], messages: [a, b, other])
        s.groupsConversations = true
        s.selectedMailbox = .account(work.id, .inbox)
        s.searchText = "report"
        s.listSelection = [a.id, b.id]
        s.searchText = ""
        let rows = s.listSelection.count, open = s.selectedMessage?.subject, held = s.selection.count
        #expect(rows != 1 || open != nil, "list shows \(rows) selected row, but selection holds \(held) messages and nothing is open")
    }
}
