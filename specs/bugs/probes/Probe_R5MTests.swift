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

    /// R5M-01: signing in again reuses the saved account only when `ewsURL` (and the username) compare exactly
    /// (AccountsSettings.signIn, d-bug-056). The same server written with other letter case or its default port gives
    /// another URL, so a second copy of the account is added and its mail downloads twice.
    @Test func sameServerWrittenDifferentlyIsTheSameAccount() {
        let plain = url("mail.example.com")
        #expect(url("Mail.Example.com") == plain, "host case: \(url("Mail.Example.com")?.absoluteString ?? "nil")")
        #expect(url("mail.example.com:443") == plain, "default port: \(url("mail.example.com:443")?.absoluteString ?? "nil")")
        #expect(url("https://MAIL.EXAMPLE.COM/EWS/Exchange.asmx") == plain,
                "pasted in capitals: \(url("https://MAIL.EXAMPLE.COM/EWS/Exchange.asmx")?.absoluteString ?? "nil")")
    }

    /// R5M-02: the EWS folder pasted without its file ("…/EWS/", "…/ews") gets a second /EWS/ in front of the file.
    @Test func ewsFolderPastedWithoutTheFileIsTheStandardURL() {
        let want = "https://mail.example.com/EWS/Exchange.asmx"
        for s in ["https://mail.example.com/EWS/", "https://mail.example.com/EWS", "mail.example.com/ews/"] {
            #expect(url(s)?.absoluteString == want, "\(s) -> \(url(s)?.absoluteString ?? "nil")")
        }
    }

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

    /// R5M-04: a password pasted in the server field ("https://me:pw@host") is kept in the URL; Settings saves the
    /// field as typed in UserDefaults and lists it under Accounts.
    @Test func credentialsInTheServerFieldAreNotKept() {
        let u = url("https://me:Secret123@mail.example.com")
        #expect(u == nil || (u?.user == nil && u?.password == nil), "\(u?.absoluteString ?? "nil")")
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

    /// R5M-07: a search's own notice (the 2,000 limit, "Search failed") replaces whatever the status said
    /// ("Couldn't send …", a paused sign-in); clearing the search then clears the status, so that notice is gone.
    @Test func searchNoticeDoesNotEraseAnotherNotice() async throws {
        let msgs = (0..<2001).map { mk(work, "Report \($0)", minutesAgo: Double($0)) }
        let (db, u) = try searchDB(msgs)
        defer { try? FileManager.default.removeItem(at: u.deletingLastPathComponent()) }
        let s = MailStore(accounts: [work], messages: msgs)
        s.searchDebounce = .zero
        s.searcher = { q, accounts in try db.search(q, accounts: accounts) }
        let notice = "Couldn't send “Budget”: The server refused it"
        s.status = notice
        s.searchText = "report"
        await s.searchTask?.value
        let during = s.status
        s.searchText = ""
        #expect(s.status == notice, "during the search: \(during ?? "nil"); after clearing it: \(s.status ?? "nil")")
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

    /// R5M-10: the window title names the mailbox while the list shows search results from the whole account
    /// (Mail: "Searching “%@”", Localizable.loctable SearchingWindowTitleFormat).
    @Test func titleSaysSearchingWhileSearching() {
        let s = MailStore(accounts: [work], messages: [mk(work, "Report"), mk(work, "Report 2", box: .sent)])
        s.selectedMailbox = .account(work.id, .inbox)
        s.searchText = "report"
        #expect(s.title.hasPrefix("Searching"), "title while searching: \(s.title); list: \(s.visibleMessages.map(\.subject))")
    }
}
