import Foundation

/// A mail server protocol (EWS today, Microsoft Graph later). `MailStore` only talks to this,
/// so switching protocols doesn't touch the data store.
///
/// Messages returned here carry `remoteID`; the store assigns account, mailbox and its own local IDs.
public protocol MailBackend: Sendable {
    /// The account's standard folders, mapped to Mail's mailbox roles.
    func folders() async throws -> [RemoteFolder]
    /// The newest messages of a folder, for a fast first screen before the full sync finishes.
    func newest(in folder: RemoteFolder, limit: Int) async throws -> [Message]
    /// Changes since `token` (nil = from scratch). The token is opaque: an EWS SyncState or a Graph deltaLink.
    func sync(_ folder: RemoteFolder, token: String?) async throws -> SyncResult
    /// Full text and attachment names of one message.
    func body(remoteID: String) async throws -> MessageBody
}

public struct RemoteFolder: Hashable, Sendable {
    public var role: MailboxKind
    public var id: String
    public init(role: MailboxKind, id: String) { self.role = role; self.id = id }
}

public struct SyncResult: Sendable {
    public var upserts: [Message]
    public var deletedRemoteIDs: [String]
    /// Read state changes that arrive without the rest of the message (EWS ReadFlagChange).
    public var readChanges: [String: Bool]
    public var token: String
    /// More changes are waiting; call `sync` again with `token`.
    public var more: Bool
    public init(upserts: [Message], deletedRemoteIDs: [String], readChanges: [String: Bool] = [:],
                token: String, more: Bool) {
        self.upserts = upserts; self.deletedRemoteIDs = deletedRemoteIDs; self.readChanges = readChanges
        self.token = token; self.more = more
    }
}

/// The full message. Sender and recipients are included because list summaries may lack email addresses.
public struct MessageBody: Sendable {
    public var text: String
    public var attachments: [String]
    public var from: Contact?
    public var to: [Contact]?
    public var cc: [Contact]?
    public init(text: String, attachments: [String], from: Contact? = nil, to: [Contact]? = nil, cc: [Contact]? = nil) {
        self.text = text; self.attachments = attachments; self.from = from; self.to = to; self.cc = cc
    }
}
