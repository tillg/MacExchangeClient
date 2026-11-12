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
    public var attachments: [Attachment]
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
    /// The server's conversation (Exchange ConversationId): the messages, received and sent, that belong together.
    public var conversationID: String?

    public init(id: UUID = UUID(), accountID: UUID, mailbox: MailboxKind = .inbox, from: Contact, to: [Contact],
                cc: [Contact] = [], subject: String, body: String, date: Date, isRead: Bool = false,
                flag: FlagColor? = nil, category: MailCategory = .primary, isVIP: Bool = false,
                attachments: [Attachment] = [], remoteID: String? = nil, hasAttachments: Bool? = nil,
                serverPreview: String? = nil, bodyLoaded: Bool = true, isInvite: Bool? = nil, invite: Invite? = nil) {
        self.id = id; self.accountID = accountID; self.mailbox = mailbox; self.from = from; self.to = to
        self.cc = cc; self.subject = subject; self.body = body; self.date = date; self.isRead = isRead
        self.flag = flag; self.category = category; self.isVIP = isVIP; self.attachments = attachments
        self.remoteID = remoteID; self.hasAttachments = hasAttachments ?? !attachments.isEmpty
        self.serverPreview = serverPreview; self.bodyLoaded = bodyLoaded
        self.isInvite = isInvite ?? (invite != nil ? true : nil); self.invite = invite
    }

    /// The body must be fetched: never loaded, or loaded from a server before HTML was asked for or
    /// before attachments had a size (needed to open them as Mail does).
    public var needsBody: Bool {
        !bodyLoaded || (remoteID != nil && (htmlChecked != true || attachments.contains { $0.size == nil }
            || (invite != nil && invite?.isCancellation == nil)))  // invites cached before cancellations were told apart
    }

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
    /// Files sent with the message. Stored optional, so drafts cached before it existed still load.
    private var files: [DraftAttachment]?
    public var attachments: [DraftAttachment] {
        get { files ?? [] }
        set { files = newValue.isEmpty ? nil : newValue }
    }
    /// The message whose attachments the compose window still has to add (a forward, or a reply that includes them).
    public var loadingOriginal: UUID?
    /// The message replied to or forwarded, when it has attachments (for Include/Exclude Attachments).
    public var original: UUID?
    public init(accountID: UUID, to: String = "", cc: String = "", subject: String = "", body: String = "",
                inviteAnswer: InviteAnswer? = nil) {
        self.accountID = accountID; self.to = to; self.cc = cc; self.subject = subject; self.body = body
        self.inviteAnswer = inviteAnswer
    }
}

extension Draft {
    /// Some of the files came from the message replied to or forwarded.
    public var hasOriginalAttachments: Bool { attachments.contains(where: \.fromOriginal) }

    /// Changed by the user since `start`, so closing the window asks first, as in Mail. The original's files
    /// arrive (and go) by themselves, so they don't count.
    public func hasChanges(since start: Draft) -> Bool { userContent != start.userContent }

    private var userContent: [AnyHashable] {
        [accountID, to, cc, subject, text, attachments.filter { !$0.fromOriginal }]
    }

    /// Exclude Attachments: takes out the original's files, keeps the ones added here.
    public mutating func excludeOriginalAttachments() {
        var k = 0
        body = String(body.filter { c in
            guard c == Self.fileMark else { return true }
            defer { k += 1 }
            return !(attachments.indices.contains(k) && attachments[k].fromOriginal)
        })
        attachments.removeAll(where: \.fromOriginal)
    }

    /// About the size Exchange counts against the account's limit: the text, and files in base64
    /// (4 bytes per 3, plus a line break every 76 characters).
    public var estimatedSize: Int {
        text.utf8.count + subject.utf8.count + attachments.reduce(0) { $0 + Self.encodedSize($1) }
    }

    static func encodedSize(_ a: DraftAttachment) -> Int {
        let b64 = (a.data.count + 2) / 3 * 4
        return b64 + b64 / 76 * 2 + 300
    }

    /// A file placed in the text sits at this character of `body`: the k-th one is `attachments[k]`, as in
    /// an attributed string. Files beyond the marks were added without a place (they show at the end).
    public static let fileMark: Character = "\u{FFFC}"

    /// The text that is sent: the body without the marks of the files placed in it.
    public var text: String { body.filter { $0 != Self.fileMark } }

    /// Pictures placed in the text, by their index in `attachments`: they are sent in their place. Only types every
    /// mail client draws in HTML; others (HEIC, TIFF…) go as ordinary files, so the recipient still gets them.
    public var placedPictures: [Int] {
        let marks = body.filter { $0 == Self.fileMark }.count
        return attachments.indices.filter { $0 < marks && Self.inlineTypes.contains(attachments[$0].contentType?.lowercased() ?? "") }
    }

    static let inlineTypes: Set<String> = ["image/jpeg", "image/jpg", "image/png", "image/gif"]

    /// The body as HTML with the placed pictures at their marks, as `cid:` references. A line per `<div>` and
    /// `<div><br></div>` for an empty one, the way Mail writes its HTML; other files' marks are left out.
    public func html(contentID: (Int) -> String?) -> String {
        func escape(_ s: Substring) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var k = 0
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var out = "", run = Substring()
            for c in line {
                guard c == Self.fileMark else { run.append(c); continue }
                out += escape(run); run = ""
                if let id = contentID(k) { out += "<img src=\"cid:\(id)\" alt=\"\(escape(Substring(attachments[k].name)))\">" }
                k += 1
            }
            out += escape(run)
            return "<div>\(out.isEmpty ? "<br>" : out)</div>"
        }
        return "<html><head><meta http-equiv=\"content-type\" content=\"text/html; charset=utf-8\"></head>"
            + "<body style=\"overflow-wrap: break-word; -webkit-nbsp-mode: space; line-break: after-white-space;\">"
            + lines.joined(separator: "\n") + "</body></html>"
    }
}

/// Edit ▸ Include Attachments With Replies, as in Mail.
public enum IncludeAttachments: String, CaseIterable, Sendable {
    case never, ask, whenAddingRecipients, always
    public var title: String {
        switch self {
        case .never: "Never"
        case .ask: "Ask"
        case .whenAddingRecipients: "When Adding Recipients"
        case .always: "Always"
        }
    }
}

/// A file added to a message being written, with its content (kept until the message is sent).
public struct DraftAttachment: Hashable, Codable, Sendable {
    public var name: String
    public var contentType: String?
    public var data: Data
    /// Taken from the message replied to or forwarded.
    public var fromOriginal: Bool
    public init(name: String, contentType: String?, data: Data, fromOriginal: Bool = false) {
        self.name = name; self.contentType = contentType; self.data = data; self.fromOriginal = fromOriginal
    }
    public var attachment: Attachment { Attachment(name: name, size: data.count, contentType: contentType) }
}

public enum ReplyKind: Sendable { case reply, replyAll, forward }

/// A file sent with a message. Only its name, size and type are kept; the content is fetched when it is opened.
public struct Attachment: Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public var name: String
    /// Bytes, when the server reports it.
    public var size: Int?
    public var contentType: String?

    public init(name: String, size: Int? = nil, contentType: String? = nil) {
        self.name = name; self.size = size; self.contentType = contentType
    }

    public init(stringLiteral name: String) { self.init(name: name) }

    /// The name as a file name: the sender's name can't point into another folder.
    /// A "/" becomes ":", which the Finder shows as "/" again.
    public var fileName: String {
        let n = name.replacingOccurrences(of: "/", with: ":").replacingOccurrences(of: "\0", with: "")
        return n.isEmpty || n == "." || n == ".." ? "Attachment" : n
    }
}
