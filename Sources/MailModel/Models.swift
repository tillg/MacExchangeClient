import Foundation

public struct Account: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var address: String
    /// An account on a mail server (set up in Settings), as opposed to the sample data. Stays true while its
    /// password is missing and it has no connection.
    public var isServer: Bool
    public init(id: UUID = UUID(), name: String, address: String, isServer: Bool = false) {
        self.id = id; self.name = name; self.address = address; self.isServer = isServer
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

    /// The first letters of the first two words (split on any space, tab or no-break space), uppercased. A letter
    /// whose uppercase is two (ß → SS, ﬀ → FF) gives its first, so the avatar never shows more than two.
    public var initials: String {
        let parts = name.split(whereSeparator: \.isWhitespace).prefix(2)
        return parts.compactMap { $0.first.flatMap { String($0).uppercased().first } }.map(String.init).joined()
    }

    /// Parses "a@b.com, Name <c@d.com>; \"Doe, John\" <e@f.com>". Commas and semicolons separate recipients,
    /// except inside double quotes or `<>`; the quotes around a name are removed. A piece without an address
    /// followed by one with `<…>` is a name with a comma written without quotes (Outlook's `Last, First <addr>`).
    public static func parseList(_ s: String) -> [Contact] {
        /// Nil when a quote or `<` is never closed: it would swallow the recipients after it.
        func split(nesting: Bool) -> [String]? {
            var pieces: [String] = [], piece = "", quoted = false, escaped = false, inAngle = false
            for c in s {
                if nesting {
                    if escaped { escaped = false } else if quoted && c == "\\" { escaped = true }
                    else if c == "\"" { quoted.toggle() } else if !quoted && c == "<" { if inAngle { return nil }; inAngle = true }
                    else if !quoted && c == ">" { inAngle = false }
                }
                if !quoted && !inAngle && (c == "," || c == ";") { pieces.append(piece); piece = ""; continue }
                piece.append(c)
            }
            return quoted || inAngle ? nil : pieces + [piece]
        }
        let pieces = (split(nesting: true) ?? split(nesting: false)!)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var merged: [String] = []
        for p in pieces {
            if let last = merged.last, !last.contains("@"), !last.contains("<"), !last.contains("\""), p.contains("<") {
                merged[merged.count - 1] = last + ", " + p
            } else {
                merged.append(p)
            }
        }
        return merged.map { t in
            if let lt = t.lastIndex(of: "<"), let gt = t.lastIndex(of: ">"), lt < gt {
                let name = unquoted(t[..<lt].trimmingCharacters(in: .whitespacesAndNewlines))
                let email = t[t.index(after: lt)..<gt].trimmingCharacters(in: .whitespacesAndNewlines)
                return Contact(name: name.isEmpty ? email : name, email: email)
            }
            return Contact(name: t, email: t)
        }
    }

    /// A name without the double quotes around it, and `\"` or `\\` inside as plain characters.
    private static func unquoted(_ name: String) -> String {
        guard name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") else { return name }
        var out = "", escaped = false
        for c in name.dropFirst().dropLast() {
            if !escaped && c == "\\" { escaped = true; continue }
            escaped = false
            out.append(c)
        }
        return out
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
        // src, background, poster; any candidate of srcset; <link href> (stylesheets, fonts); url() quoted
        // directly or with an entity (`&quot;`, `&#39;`, as Outlook writes inside style attributes); `@import` of a
        // quoted web address (`@import url(…)` is a url()). Text that merely mentions `@import` loads nothing.
        let quote = #"(?:["']|&quot;|&apos;|&#0*3[49];|&#x0*2[27];)?"#
        return html.range(of: #"(src|background|poster)\s*=\s*["']?\s*https?:|srcset\s*=\s*["']?[^"'>]*https?:"#
                          + #"|<link\b[^>]*\bhref\s*=\s*["']?\s*https?:|url\(\s*"# + quote + #"\s*https?:|@import\s*"# + quote + #"\s*https?:"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// First lines of the body, as shown under the subject in the list. The list reads it on every render and
    /// shows two lines, so only the start of the body is looked at, however long the mail.
    public var preview: String {
        if !bodyLoaded, let serverPreview { return serverPreview }
        let text = body.prefix(10_000).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix(">") }
            .joined(separator: " ")
        return String(text.prefix(500))
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

    /// The body with the marks of the files placed here (moving a picture is a change), without the original's.
    private var userContent: [AnyHashable] {
        [accountID, to, cc, subject, bodyWithoutMarks(of: \.fromOriginal), attachments.filter { !$0.fromOriginal }]
    }

    /// `body` without the marks of the files for which `drop` is true (marks beyond the files stay).
    private func bodyWithoutMarks(of drop: (DraftAttachment) -> Bool) -> String {
        var k = 0
        return String(String.UnicodeScalarView(body.unicodeScalars.filter { c in
            guard c == Self.fileMarkScalar else { return true }
            defer { k += 1 }
            return !(attachments.indices.contains(k) && drop(attachments[k]))
        }))
    }

    /// Exclude Attachments: takes out the original's files, keeps the ones added here.
    public mutating func excludeOriginalAttachments() {
        body = bodyWithoutMarks(of: \.fromOriginal)
        attachments.removeAll(where: \.fromOriginal)
    }

    /// About the size Exchange counts against the account's limit: the text, and files in base64
    /// (4 bytes per 3, plus a line break every 76 characters). The window shows it on every keystroke, so the
    /// marks are found with `memchr` over the body's bytes instead of building `text`.
    public var estimatedSize: Int {
        body.utf8.count - 3 * markCount + subject.utf8.count + attachments.reduce(0) { $0 + Self.encodedSize($1) }
    }

    /// The file marks in `body` (U+FFFC is EF BF BC in UTF-8).
    private var markCount: Int {
        var body = body
        return body.withUTF8 { bytes in
            guard var p = bytes.baseAddress else { return 0 }
            let end = p + bytes.count
            var n = 0
            while p < end, let hit = memchr(p, 0xEF, end - p).map({ UnsafePointer($0.assumingMemoryBound(to: UInt8.self)) }) {
                if end - hit >= 3, hit[1] == 0xBF, hit[2] == 0xBC { n += 1 }
                p = hit + 1
            }
            return n
        }
    }

    static func encodedSize(_ a: DraftAttachment) -> Int {
        let b64 = (a.data.count + 2) / 3 * 4
        return b64 + b64 / 76 * 2 + 300
    }

    /// A file placed in the text sits at this character of `body`: the k-th one is `attachments[k]`, as in
    /// an attributed string. Files beyond the marks were added without a place (they show at the end).
    /// Marks are counted by Unicode scalar: a combining character typed after a file (an accent, ZWJ, ZWNJ) joins
    /// the mark into one `Character`, but stays a separate character in the text view.
    public static let fileMark: Character = "\u{FFFC}"
    static let fileMarkScalar: Unicode.Scalar = "\u{FFFC}"

    /// The text that is sent: the body without the marks of the files placed in it.
    public var text: String { String(String.UnicodeScalarView(body.unicodeScalars.filter { $0 != Self.fileMarkScalar })) }

    /// Pictures placed in the text, by their index in `attachments`: they are sent in their place. Only types every
    /// mail client draws in HTML; others (HEIC, TIFF…) go as ordinary files, so the recipient still gets them.
    public var placedPictures: [Int] {
        let marks = body.unicodeScalars.filter { $0 == Self.fileMarkScalar }.count
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
        // Text, with its runs of spaces and tabs kept as Mail writes them: a space after a space (or at the start
        // of a line) becomes `&nbsp;`, so they alternate; a tab goes in a `white-space:pre` span.
        func text(_ s: Substring, atLineStart: Bool) -> String {
            guard s.contains(where: { $0 == " " || $0 == "\t" }) else { return escape(s) }
            var out = "", afterSpace = atLineStart
            for c in s {
                switch c {
                case " ": out += afterSpace ? "&nbsp;" : " "; afterSpace.toggle()
                case "\t": out += "<span class=\"Apple-tab-span\" style=\"white-space:pre\">\t</span>"; afterSpace = false
                default: out += escape(Substring(String(c))); afterSpace = false
                }
            }
            return out
        }
        var k = 0
        // Any line ending: "\r\n" (as in quoted Exchange text) is one Character, not "\n".
        let lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line -> String in
            var out = "", run = String.UnicodeScalarView()
            for c in line.unicodeScalars {
                guard c == Self.fileMarkScalar else { run.append(c); continue }
                out += text(Substring(String(run)), atLineStart: out.isEmpty); run = .init()
                if let id = contentID(k) { out += "<img src=\"cid:\(id)\" alt=\"\(escape(Substring(attachments[k].name)))\">" }
                k += 1
            }
            out += text(Substring(String(run)), atLineStart: out.isEmpty)
            return "<div>\(out.isEmpty ? "<br>" : out)</div>"
        }
        // Each line takes its direction from its first strong letter, as in the text view and in plain-text mail,
        // so a Hebrew or Arabic line stays right to left.
        return "<html><head><meta http-equiv=\"content-type\" content=\"text/html; charset=utf-8\">"
            + "<style>div { unicode-bidi: plaintext; }</style></head>"
            + "<body style=\"overflow-wrap: break-word; -webkit-nbsp-mode: space; line-break: after-white-space;\">"
            + lines.joined(separator: "\n") + "</body></html>"
    }
}

/// What a compose window is opened with. SwiftUI brings a window to the front instead of opening one when it already
/// shows an equal value, and two new messages (or two replies to one message) are equal drafts: each request is
/// its own value, so each opens its own window, as in Mail.
public struct ComposeWindow: Hashable, Codable, Sendable {
    public let id: UUID
    public var draft: Draft
    public init(_ draft: Draft) { id = UUID(); self.draft = draft }
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

    private enum CodingKeys: String, CodingKey { case name, size, contentType }

    /// Also reads a bare name, as builds up to b75308d wrote it (Cache.json and outbox rows still hold those).
    public init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self.init(name: name)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name), size: try c.decodeIfPresent(Int.self, forKey: .size),
                  contentType: try c.decodeIfPresent(String.self, forKey: .contentType))
    }

    /// The name as a file name: the sender's name can't point into another folder.
    /// A "/" becomes ":", which the Finder shows as "/" again. A name over 255 bytes is shortened, keeping its extension.
    public var fileName: String {
        let n = name.replacingOccurrences(of: "/", with: ":").replacingOccurrences(of: "\0", with: "")
        guard !(n.isEmpty || n == "." || n == "..") else { return "Attachment" }
        let ext = (n as NSString).pathExtension
        guard !ext.isEmpty, ext.utf8.count <= 32 else { return Self.fileName(n, ending: "") }
        return Self.fileName((n as NSString).deletingPathExtension, ending: "." + ext)
    }

    /// `base` + `ending` within the 255 bytes (UTF-8) a file name may have: `base` is cut at a whole character.
    public static func fileName(_ base: String, ending: String) -> String {
        let room = 255 - ending.utf8.count
        guard base.utf8.count > room else { return base + ending }
        var cut = "", bytes = 0
        for c in base {
            bytes += c.utf8.count
            if bytes > room { break }
            cut.append(c)
        }
        return cut + ending
    }
}
