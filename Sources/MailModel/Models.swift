import Foundation

public struct Account: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var address: String
    public init(id: UUID = UUID(), name: String, address: String) {
        self.id = id; self.name = name; self.address = address
    }
}

/// Standard per-account mailboxes, in Mail's sidebar order.
public enum MailboxKind: String, CaseIterable, Hashable, Sendable {
    case inbox, drafts, sent, junk, trash, archive

    public var title: String {
        switch self {
        case .inbox: "Inbox"
        case .drafts: "Drafts"
        case .sent: "Sent"
        case .junk: "Junk"
        case .trash: "Trash"
        case .archive: "Archive"
        }
    }

    /// SF Symbols Mail uses for these mailboxes.
    public var symbol: String {
        switch self {
        case .inbox: "tray"
        case .drafts: "doc"
        case .sent: "paperplane"
        case .junk: "xmark.bin"
        case .trash: "trash"
        case .archive: "archivebox"
        }
    }
}

/// Built-in smart mailboxes shown in Favorites.
public enum SmartMailbox: String, CaseIterable, Hashable, Sendable {
    case allInboxes, vip, flagged, unread

    public var title: String {
        switch self {
        case .allInboxes: "Inbox"
        case .vip: "VIPs"
        case .flagged: "Flagged"
        case .unread: "Unread"
        }
    }

    public var symbol: String {
        switch self {
        case .allInboxes: "tray"
        case .vip: "star"
        case .flagged: "flag"
        case .unread: "envelope.badge"
        }
    }
}

public enum MailboxRef: Hashable, Sendable {
    case smart(SmartMailbox)
    case account(UUID, MailboxKind)

    /// Whether the category bar (Primary / Transactions / …) applies.
    public var isInbox: Bool {
        switch self {
        case .smart(.allInboxes), .account(_, .inbox): true
        default: false
        }
    }
}

/// Flag colours, in Mail's Message ▸ Flag menu order.
public enum FlagColor: String, CaseIterable, Hashable, Sendable {
    case red, orange, yellow, green, blue, purple, gray
    public var title: String { rawValue.capitalized }
}

/// Mail Categories (Inbox top bar).
public enum MailCategory: String, CaseIterable, Hashable, Sendable {
    case primary, transactions, updates, promotions
    public var title: String { rawValue.capitalized }
    public var symbol: String {
        switch self {
        case .primary: "person"
        case .transactions: "cart"
        case .updates: "message"
        case .promotions: "megaphone"
        }
    }
}

public struct Contact: Hashable, Sendable {
    public var name: String
    public var email: String
    public init(name: String, email: String) { self.name = name; self.email = email }

    public var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap(\.first).map(String.init).joined().uppercased()
    }

    /// Parses "a@b.com, Name <c@d.com>".
    public static func parseList(_ s: String) -> [Contact] {
        s.split(separator: ",").compactMap { raw in
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            if let lt = t.firstIndex(of: "<"), let gt = t.lastIndex(of: ">"), lt < gt {
                let name = t[..<lt].trimmingCharacters(in: .whitespaces)
                let email = String(t[t.index(after: lt)..<gt])
                return Contact(name: name.isEmpty ? email : name, email: email)
            }
            return Contact(name: t, email: t)
        }
    }
}

public struct Message: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var accountID: UUID
    public var mailbox: MailboxKind
    public var from: Contact
    public var to: [Contact]
    public var cc: [Contact]
    public var subject: String
    public var body: String
    public var date: Date
    public var isRead: Bool
    public var flag: FlagColor?
    public var category: MailCategory
    public var isVIP: Bool
    public var attachments: [String]

    public init(id: UUID = UUID(), accountID: UUID, mailbox: MailboxKind = .inbox, from: Contact, to: [Contact],
                cc: [Contact] = [], subject: String, body: String, date: Date, isRead: Bool = false,
                flag: FlagColor? = nil, category: MailCategory = .primary, isVIP: Bool = false,
                attachments: [String] = []) {
        self.id = id; self.accountID = accountID; self.mailbox = mailbox; self.from = from; self.to = to
        self.cc = cc; self.subject = subject; self.body = body; self.date = date; self.isRead = isRead
        self.flag = flag; self.category = category; self.isVIP = isVIP; self.attachments = attachments
    }

    /// First lines of the body, as shown under the subject in the list.
    public var preview: String {
        body.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix(">") }
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

public struct Draft: Hashable, Codable, Sendable {
    public var accountID: UUID
    public var to: String
    public var cc: String
    public var subject: String
    public var body: String
    public init(accountID: UUID, to: String = "", cc: String = "", subject: String = "", body: String = "") {
        self.accountID = accountID; self.to = to; self.cc = cc; self.subject = subject; self.body = body
    }
}

public enum ReplyKind: Sendable { case reply, replyAll, forward }
