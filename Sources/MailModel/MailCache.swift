import Foundation

/// What `MailStore` keeps on disk between launches: one JSON file, readable only by the user.
/// It holds real mail, so it lives in Application Support, never in the project folder.
public struct MailCache: Codable, Sendable {
    public struct AccountState: Codable, Sendable {
        public var messages: [Message]
        public var syncTokens: [MailboxKind: String]
        public var outbox: [PendingChange]
        /// Folders whose full sync has finished. Optional, so caches from before it existed still load.
        public var complete: [MailboxKind]?
        /// The account's folders of its own, so their mail has a place in the sidebar before the server answers.
        public var folders: [Folder]?
    }

    public var accounts: [UUID: AccountState]

    public init(accounts: [UUID: AccountState]) { self.accounts = accounts }

    /// `~/Library/Application Support/MailReplica/Cache.json`
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(components: "MailReplica", "Cache.json")
    }

    public static func load(from url: URL = defaultURL) -> MailCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MailCache.self, from: data)
    }

    public func save(to url: URL = defaultURL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
