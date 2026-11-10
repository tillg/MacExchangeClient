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

    // Write-back. IDs are `remoteID`s; batches stay small (`MailStore.batchSize`).
    func setRead(_ ids: [String], _ read: Bool) async throws
    /// Servers know flagged/not flagged only; the colour stays local.
    func setFlagged(_ ids: [String], _ flagged: Bool) async throws
    /// Returns the new IDs (old → new): Exchange gives a moved item a new ID.
    func move(_ ids: [String], to folder: RemoteFolder) async throws -> [String: String]
    /// Erases from Trash, recoverably where the server supports it.
    func delete(_ ids: [String]) async throws
    func send(_ draft: Draft) async throws
    func saveDraft(_ draft: Draft) async throws
}

/// A local change waiting to be written to the server.
public enum ServerChange: Hashable, Codable, Sendable {
    case setRead([String], Bool)
    case setFlagged([String], Bool)
    case move([String], to: MailboxKind)
    case delete([String])
    case send(Draft)
    case saveDraft(Draft)

    func renamed(_ map: [String: String]) -> ServerChange {
        let r = { (ids: [String]) in ids.map { map[$0] ?? $0 } }
        return switch self {
        case let .setRead(ids, v): .setRead(r(ids), v)
        case let .setFlagged(ids, v): .setFlagged(r(ids), v)
        case let .move(ids, box): .move(r(ids), to: box)
        case let .delete(ids): .delete(r(ids))
        case .send, .saveDraft: self
        }
    }

    var remoteIDs: [String] {
        switch self {
        case let .setRead(ids, _), let .setFlagged(ids, _), let .move(ids, _), let .delete(ids): ids
        case .send, .saveDraft: []
        }
    }
}

public struct PendingChange: Hashable, Codable, Sendable {
    public var id = UUID()
    public let account: UUID
    public var change: ServerChange
    /// The messages as they were before, to undo the local change if the server refuses it.
    public var previous: [Message]
}

public struct RemoteFolder: Hashable, Sendable {
    public var role: MailboxKind
    public var id: String
    /// Messages in the folder on the server, for the history progress bar.
    public var totalCount: Int
    public init(role: MailboxKind, id: String, totalCount: Int = 0) {
        self.role = role; self.id = id; self.totalCount = totalCount
    }
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

/// Progress of a check for mail.
public struct SyncProgress: Equatable, Sendable {
    public var text: String
    public var fraction: Double
    public init(text: String, fraction: Double) { self.text = text; self.fraction = fraction }
}
