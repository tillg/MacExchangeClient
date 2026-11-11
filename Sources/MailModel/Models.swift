import Foundation

public struct Account: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var address: String
    public init(id: UUID = UUID(), name: String, address: String) {
        self.id = id; self.name = name; self.address = address
    }
}

/// A mailbox of an account: one of the standard ones, in Mail's sidebar order, or a folder of the user's own.
/// A string, so caches written when only the standard ones existed still load.
public struct MailboxKind: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let inbox = Self(rawValue: "inbox")
    public static let drafts = Self(rawValue: "drafts")
    public static let sent = Self(rawValue: "sent")
    public static let junk = Self(rawValue: "junk")
    public static let trash = Self(rawValue: "trash")
    public static let archive = Self(rawValue: "archive")

    /// The standard mailboxes every account has.
    public static let allCases: [MailboxKind] = [.inbox, .drafts, .sent, .junk, .trash, .archive]

    /// A folder of the user's own; `id` is unique within its account (the server's folder ID).
    public static func folder(_ id: String) -> Self { Self(rawValue: "folder:" + id) }

    public var isStandard: Bool { Self.allCases.contains(self) }

    /// The standard mailbox's name. A folder's name is in `MailStore.name(of:in:)`.
    public var title: String {
        [.inbox: "Inbox", .drafts: "Drafts", .sent: "Sent", .junk: "Junk", .trash: "Trash", .archive: "Archive"][self] ?? ""
    }

    /// SF Symbols Mail uses for these mailboxes; a plain folder for the user's own.
    public var symbol: String {
        [.inbox: "tray", .drafts: "doc", .sent: "paperplane", .junk: "xmark.bin", .trash: "trash",
         .archive: "archivebox"][self] ?? "folder"
    }
}

/// A folder of the user's own, in the account's tree.
public struct Folder: Hashable, Codable, Sendable {
    public var box: MailboxKind
    public var name: String
    /// The mailbox it sits in, standard or not; nil at the top of the account.
    public var parent: MailboxKind?
    public init(box: MailboxKind, name: String, parent: MailboxKind? = nil) {
        self.box = box; self.name = name; self.parent = parent
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
public enum FlagColor: String, CaseIterable, Hashable, Codable, Sendable {
    case red, orange, yellow, green, blue, purple, gray
    public var title: String { rawValue.capitalized }
}

/// Mail Categories (Inbox top bar).
public enum MailCategory: String, CaseIterable, Hashable, Codable, Sendable {
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

public struct Contact: Hashable, Codable, Sendable {
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

public struct Message: Identifiable, Hashable, Codable, Sendable {
    public internal(set) var id: UUID
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
    /// Set for messages that live on a server; nil for local sample data.
    public var remoteID: String?
    /// Servers report this before the attachment names are fetched with the body.
    public var hasAttachments: Bool
    /// Preview text from the server, shown until the body is loaded.
    public var serverPreview: String?
    /// False while only the summary has been fetched from the server.
    public var bodyLoaded: Bool
    /// The server says this is a meeting invite (known from the summary, before the body loads).
    /// Optional, like `invite`, so caches written before these fields existed still load.
    public var isInvite: Bool?
    /// Time, place and attendees, loaded with the body.
    public var invite: Invite?
    /// The HTML version of the body, when the sender sent one. `body` stays plain text for the list, search and replies.
    public var html: String?
    /// The body was fetched by a version that asks for HTML. Optional, so older caches load; those bodies are fetched once more.
    public var htmlChecked: Bool?

    public init(id: UUID = UUID(), accountID: UUID, mailbox: MailboxKind = .inbox, from: Contact, to: [Contact],
                cc: [Contact] = [], subject: String, body: String, date: Date, isRead: Bool = false,
                flag: FlagColor? = nil, category: MailCategory = .primary, isVIP: Bool = false,
                attachments: [String] = [], remoteID: String? = nil, hasAttachments: Bool? = nil,
                serverPreview: String? = nil, bodyLoaded: Bool = true, isInvite: Bool? = nil, invite: Invite? = nil) {
        self.id = id; self.accountID = accountID; self.mailbox = mailbox; self.from = from; self.to = to
        self.cc = cc; self.subject = subject; self.body = body; self.date = date; self.isRead = isRead
        self.flag = flag; self.category = category; self.isVIP = isVIP; self.attachments = attachments
        self.remoteID = remoteID; self.hasAttachments = hasAttachments ?? !attachments.isEmpty
        self.serverPreview = serverPreview; self.bodyLoaded = bodyLoaded
        self.isInvite = isInvite ?? (invite != nil ? true : nil); self.invite = invite
    }

    /// The body must be fetched: never loaded, or loaded from a server before HTML was asked for.
    public var needsBody: Bool { !bodyLoaded || (remoteID != nil && htmlChecked != true) }

    /// The HTML loads images, styles or fonts from the web. They are blocked until the user allows them, so
    /// opening a message doesn't tell the sender it was read.
    public var hasRemoteContent: Bool {
        guard let html else { return false }
        return html.range(of: #"(src|background)\s*=\s*["']?\s*https?:|url\(\s*["']?\s*https?:|@import"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// First lines of the body, as shown under the subject in the list.
    public var preview: String {
        if !bodyLoaded, let serverPreview { return serverPreview }
        return body.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix(">") }
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

public struct Draft: Hashable, Codable, Sendable {
    public var accountID: UUID
    public var to: String
    public var cc: String
    public var subject: String
    public var body: String
    /// Set when this is an answer to an invite: Send answers it, with the body as the comment.
    /// Optional, so drafts cached before it existed still load.
    public var inviteAnswer: InviteAnswer?
    public init(accountID: UUID, to: String = "", cc: String = "", subject: String = "", body: String = "",
                inviteAnswer: InviteAnswer? = nil) {
        self.accountID = accountID; self.to = to; self.cc = cc; self.subject = subject; self.body = body
        self.inviteAnswer = inviteAnswer
    }
}

public enum ReplyKind: Sendable { case reply, replyAll, forward }
