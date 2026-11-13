import Foundation
import SQLite3

/// A mailbox of an account, for loading some mailboxes before the others.
public struct MailboxKey: Hashable, Sendable {
    public var account: UUID
    public var mailbox: MailboxKind
    public init(account: UUID, mailbox: MailboxKind) { self.account = account; self.mailbox = mailbox }
}

/// Where a folder's sync stands: the server's token and whether the full history has arrived.
public struct SyncState: Hashable, Sendable {
    public var account: UUID
    public var mailbox: MailboxKind
    public var token: String?
    public var complete: Bool
    public init(account: UUID, mailbox: MailboxKind, token: String?, complete: Bool) {
        self.account = account; self.mailbox = mailbox; self.token = token; self.complete = complete
    }
}

/// Everything but the messages: small, loaded first.
public struct StoredMeta: Sendable {
    public var folders: [UUID: [Folder]] = [:]
    public var sync: [SyncState] = []
    public var outbox: [PendingChange] = []
    /// The content of the files of messages kept only on this Mac (a send Exchange refused), by position.
    public var files: [Message.ID: [Data]] = [:]
}

/// What changed in the store since the last write. Messages are written one by one; sync positions,
/// folders and waiting changes, when set, replace what is stored.
public struct StoreChanges: Sendable {
    public var upserts: [Message] = []
    /// Changed messages still to be picked from a snapshot of all of them (`resolved()`): finding a few among
    /// 180,000 takes too long for the main thread, so it happens with the write.
    var snapshot: [Message] = []
    var snapshotIDs: Set<Message.ID> = []
    var storedAccounts: Set<UUID> = []
    public var removed: [Message.ID] = []
    public var sync: [SyncState]?
    public var folders: [UUID: [Folder]]?
    public var outbox: [PendingChange]?
    /// File content of messages kept only on this Mac; replaces what is stored for each of them.
    public var files: [Message.ID: [Data]] = [:]
    public init(upserts: [Message] = [], removed: [Message.ID] = [], sync: [SyncState]? = nil,
                folders: [UUID: [Folder]]? = nil, outbox: [PendingChange]? = nil, files: [Message.ID: [Data]] = [:]) {
        self.upserts = upserts; self.removed = removed; self.sync = sync; self.folders = folders; self.outbox = outbox
        self.files = files
    }
    public var isEmpty: Bool {
        upserts.isEmpty && snapshotIDs.isEmpty && removed.isEmpty && sync == nil && folders == nil && outbox == nil
            && files.isEmpty
    }

    /// With the changed messages picked from the snapshot into `upserts`.
    public func resolved() -> StoreChanges {
        guard !snapshotIDs.isEmpty else { return self }
        var c = self
        for i in snapshot.indices where snapshotIDs.contains(snapshot[i].id) && storedAccounts.contains(snapshot[i].accountID) {
            c.upserts.append(snapshot[i])
        }
        c.snapshot = []; c.snapshotIDs = []
        return c
    }

    /// IDs of every message this writes, picked or not.
    var upsertIDs: Set<Message.ID> { Set(upserts.map(\.id)).union(snapshotIDs) }
}

public struct DatabaseError: LocalizedError {
    public let errorDescription: String?
}

/// Server mail on disk, in SQLite: one row per message, so the Inbox loads without reading the rest and a
/// change writes only what changed. All calls run one after the other on a private queue (search on a second
/// one, with its own read-only connection); call them off the main thread, except on quit.
public final class MailDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "MailDatabase")
    private let url: URL
    /// Search reads on a connection of its own, so it never waits for a background write (WAL lets it read meanwhile).
    private var reader: OpaquePointer?
    private let readQueue = DispatchQueue(label: "MailDatabase.search")
    /// Most results a search returns, newest first.
    public static let searchLimit = 2000

    /// `~/Library/Application Support/MailReplica/Mail.sqlite`, next to the old `Cache.json`.
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(components: "MailReplica", "Mail.sqlite")
    }

    public init(url: URL) throws {
        self.url = url
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        // Created readable only by the user; SQLite gives its journal files the same permissions.
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        // On any error below, deinit closes the connection.
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw DatabaseError(errorDescription: "Couldn't open the mail database: \(String(cString: sqlite3_errmsg(db)))")
        }
        var isNew = true
        try query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'messages'") { _ in isNew = false }
        try exec("""
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS messages(
              id TEXT PRIMARY KEY, account TEXT NOT NULL, mailbox TEXT NOT NULL, remote TEXT, date REAL NOT NULL,
              read INTEGER NOT NULL, flag TEXT, from_name TEXT NOT NULL, from_email TEXT NOT NULL, to_list TEXT NOT NULL,
              cc_list TEXT NOT NULL, subject TEXT NOT NULL, body TEXT NOT NULL, category TEXT NOT NULL, bits INTEGER NOT NULL,
              attachments TEXT NOT NULL, preview TEXT, invite BLOB, html TEXT, is_invite INTEGER, html_checked INTEGER,
              conversation TEXT);
            CREATE INDEX IF NOT EXISTS messages_mailbox ON messages(account, mailbox);
            CREATE TABLE IF NOT EXISTS sync(account TEXT NOT NULL, mailbox TEXT NOT NULL, token TEXT, complete INTEGER NOT NULL,
              PRIMARY KEY(account, mailbox));
            CREATE TABLE IF NOT EXISTS folders(account TEXT NOT NULL, box TEXT NOT NULL, name TEXT NOT NULL, parent TEXT,
              position INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS outbox(position INTEGER PRIMARY KEY, change BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS files(message TEXT NOT NULL, position INTEGER NOT NULL, data BLOB NOT NULL,
              PRIMARY KEY(message, position));
            """)
        // From before conversations: every folder syncs again from the start, so the messages already here learn
        // their conversation. Known messages keep their ID, body and flag colour (`MailStore.merge`).
        var hasConversation = false
        try query("SELECT 1 FROM pragma_table_info('messages') WHERE name = 'conversation'") { _ in hasConversation = true }
        if !hasConversation {
            try exec("""
                BEGIN IMMEDIATE; ALTER TABLE messages ADD COLUMN conversation TEXT;
                UPDATE sync SET token = NULL, complete = 0; COMMIT;
                """)
        }
        // A new database gets the search index right away; an older one in `prepareSearch()`, after the Inbox has loaded.
        if isNew { try exec(Self.searchSchema + "PRAGMA user_version = \(Self.schemaVersion);") }
    }

    deinit {
        sqlite3_close(reader)
        sqlite3_close(db)
    }

    // MARK: Search

    /// 1: the full-text index `messages_fts`.
    private static let schemaVersion = 1

    private static let indexed = ["subject", "from_name", "from_email", "to_list", "cc_list", "preview", "body"]

    /// The full-text index over `messages`, kept exact by triggers in the same transaction as each write.
    /// A rewrite that changes no indexed text (read, flag, mailbox) leaves the index alone.
    /// The to/cc separators (U+001F, U+001E) are word breaks for the tokenizer.
    private static var searchSchema: String {
        let cols = indexed.joined(separator: ", ")
        func values(_ row: String) -> String { indexed.map { "\(row).\($0)" }.joined(separator: ", ") }
        return """
            CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(\(cols),
              content='messages', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2');
            CREATE TRIGGER IF NOT EXISTS messages_fts_insert AFTER INSERT ON messages BEGIN
              INSERT INTO messages_fts(rowid, \(cols)) VALUES(new.rowid, \(values("new")));
            END;
            CREATE TRIGGER IF NOT EXISTS messages_fts_delete AFTER DELETE ON messages BEGIN
              INSERT INTO messages_fts(messages_fts, rowid, \(cols)) VALUES('delete', old.rowid, \(values("old")));
            END;
            CREATE TRIGGER IF NOT EXISTS messages_fts_update AFTER UPDATE ON messages
            WHEN \(indexed.map { "old.\($0) IS NOT new.\($0)" }.joined(separator: " OR ")) BEGIN
              INSERT INTO messages_fts(messages_fts, rowid, \(cols)) VALUES('delete', old.rowid, \(values("old")));
              INSERT INTO messages_fts(rowid, \(cols)) VALUES(new.rowid, \(values("new")));
            END;
            CREATE INDEX IF NOT EXISTS messages_date ON messages(date DESC);
            """
    }

    /// Builds the search index of a database from before search (about 1.2 s at 180,000 messages), in one
    /// transaction. Returns false when there was nothing to do.
    @discardableResult
    public func prepareSearch() throws -> Bool {
        try queue.sync {
            guard try version() < Self.schemaVersion else { return false }
            try exec("BEGIN IMMEDIATE")
            do {
                try exec(Self.searchSchema + """
                    INSERT INTO messages_fts(messages_fts) VALUES('rebuild');
                    PRAGMA user_version = \(Self.schemaVersion);
                    COMMIT;
                    """)
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
            return true
        }
    }

    func schemaVersion() throws -> Int { try queue.sync { try version() } }

    private func version() throws -> Int {
        var v = 0
        try query("PRAGMA user_version") { v = $0.int(0) }
        return v
    }

    /// IDs of stored messages matching `query`, newest first. Every word must match the start of a word in
    /// any field. Trash and Junk are left out here, before the limit, so their hits can't crowd out the rest;
    /// the caller checks scope and mailbox again against memory (the database may lag it).
    public func search(_ query: String, accounts: Set<UUID>?, limit: Int = searchLimit) throws -> [Message.ID] {
        guard let match = Self.matchExpression(query), accounts?.isEmpty != true else { return [] }
        return try readQueue.sync {
            if reader == nil {
                guard sqlite3_open_v2(url.path, &reader, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                    defer { sqlite3_close(reader); reader = nil }
                    throw DatabaseError(errorDescription: "Couldn't open the mail database for search: "
                                        + String(cString: sqlite3_errmsg(reader)))
                }
            }
            let scope = accounts.map { a in " AND m.account IN (" + a.map { _ in "?" }.joined(separator: ",") + ")" } ?? ""
            var ids: [Message.ID] = []
            try self.query("""
                SELECT m.id FROM messages_fts f JOIN messages m ON m.rowid = f.rowid
                WHERE messages_fts MATCH ? AND m.mailbox NOT IN ('\(MailboxKind.trash.rawValue)', '\(MailboxKind.junk.rawValue)')\(scope)
                ORDER BY m.date DESC LIMIT \(max(limit, 0))
                """, [match] + (accounts ?? []).map(\.uuidString), on: reader) { r in
                if let id = UUID(uuidString: r.text(0)) { ids.append(id) }
            }
            return ids
        }
    }

    /// The user's words as an FTS5 query: each one quoted (so no input is FTS syntax) with a prefix star,
    /// all of them required. Words without a letter or digit match nothing and are left out.
    static func matchExpression(_ text: String) -> String? {
        let terms = text.split(whereSeparator: \.isWhitespace).filter { $0.contains { $0.isLetter || $0.isNumber } }
        guard !terms.isEmpty else { return nil }
        return terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " ")
    }

    /// For tests: holds a write transaction open on the write connection while `body` runs.
    func holdWriteTransaction(_ body: @escaping @Sendable () -> Void) {
        queue.async {
            try? self.exec("BEGIN IMMEDIATE")
            body()
            try? self.exec("ROLLBACK")
        }
    }

    /// Where an import builds the database; it gets its real name only once complete.
    public static func importingURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".importing")
    }

    /// The database file and SQLite's journal files next to it.
    static func removeFiles(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    // MARK: Reading

    public func meta() throws -> StoredMeta {
        try queue.sync {
            var m = StoredMeta()
            try query("SELECT account, box, name, parent FROM folders ORDER BY position") { r in
                guard let a = UUID(uuidString: r.text(0)) else { return }
                m.folders[a, default: []].append(Folder(box: MailboxKind(rawValue: r.text(1)), name: r.text(2),
                                                        parent: r.optionalText(3).map(MailboxKind.init(rawValue:))))
            }
            try query("SELECT account, mailbox, token, complete FROM sync") { r in
                guard let a = UUID(uuidString: r.text(0)) else { return }
                m.sync.append(SyncState(account: a, mailbox: MailboxKind(rawValue: r.text(1)), token: r.optionalText(2),
                                        complete: r.int(3) == 1))
            }
            let decoder = JSONDecoder()
            try query("SELECT change FROM outbox ORDER BY position") { r in
                if let p = try? decoder.decode(PendingChange.self, from: r.data(0)) { m.outbox.append(p) }
            }
            try query("SELECT message, data FROM files ORDER BY message, position") { r in
                if let id = UUID(uuidString: r.text(0)) { m.files[id, default: []].append(r.data(1)) }
            }
            return m
        }
    }

    /// All messages, or those of some mailboxes, or all but those.
    public func messages() throws -> [Message] { try messages(where: "", []) }

    public func messages(in boxes: [MailboxKey]) throws -> [Message] {
        boxes.isEmpty ? [] : try messages(where: "WHERE " + Self.match(boxes), boxes)
    }

    public func messages(notIn boxes: [MailboxKey]) throws -> [Message] {
        boxes.isEmpty ? try messages() : try messages(where: "WHERE NOT (" + Self.match(boxes) + ")", boxes)
    }

    private static func match(_ boxes: [MailboxKey]) -> String {
        boxes.map { _ in "(account = ? AND mailbox = ?)" }.joined(separator: " OR ")
    }

    private func messages(where clause: String, _ boxes: [MailboxKey]) throws -> [Message] {
        try queue.sync {
            var out: [Message] = []
            let args = boxes.flatMap { [$0.account.uuidString, $0.mailbox.rawValue] }
            try query("SELECT \(Self.columns) FROM messages \(clause)", args) { r in
                if let m = Self.message(r) { out.append(m) }
            }
            return out
        }
    }

    // MARK: Writing

    /// Writes one batch in one transaction: all of it or, on an error, none of it. Waits for earlier
    /// background writes, so it is also the write on quit.
    public func write(_ c: StoreChanges) throws {
        guard !c.isEmpty else { return }
        try queue.sync { try commit(c) }
    }

    /// Writes in the background, after the writes before it; then `done` is called, or `failed` on an error.
    public func writeInBackground(_ c: StoreChanges, done: @escaping @Sendable () -> Void = {},
                                  failed: @escaping @Sendable (Error) -> Void) {
        guard !c.isEmpty else { return }
        queue.async { do { try self.commit(c); done() } catch { failed(error) } }
    }

    private func commit(_ changes: StoreChanges) throws {
        let c = changes.resolved()
        try exec("BEGIN IMMEDIATE")
        do {
            if !c.upserts.isEmpty {
                let marks = Array(repeating: "?", count: Self.columnCount).joined(separator: ",")
                // An upsert, not INSERT OR REPLACE: REPLACE doesn't fire the delete trigger, which would leave
                // the old words in the search index.
                try prepared("INSERT INTO messages(\(Self.columns)) VALUES(\(marks)) ON CONFLICT(id) DO UPDATE SET \(Self.upsertSet)") { st in
                    for m in c.upserts { try Self.bind(m, st); try step(st) }
                }
            }
            if !c.removed.isEmpty {
                try prepared("DELETE FROM messages WHERE id = ?") { st in
                    for id in c.removed { st.bind(1, id.uuidString); try step(st) }
                }
                try prepared("DELETE FROM files WHERE message = ?") { st in
                    for id in c.removed { st.bind(1, id.uuidString); try step(st) }
                }
            }
            if !c.files.isEmpty {
                try prepared("DELETE FROM files WHERE message = ?") { st in
                    for id in c.files.keys { st.bind(1, id.uuidString); try step(st) }
                }
                try prepared("INSERT INTO files VALUES(?,?,?)") { st in
                    for (id, list) in c.files {
                        for (i, data) in list.enumerated() { st.bind(1, id.uuidString); st.bind(2, i); st.bind(3, data); try step(st) }
                    }
                }
            }
            if let sync = c.sync {
                try exec("DELETE FROM sync")
                try prepared("INSERT INTO sync VALUES(?,?,?,?)") { st in
                    for s in sync {
                        st.bind(1, s.account.uuidString); st.bind(2, s.mailbox.rawValue); st.bind(3, s.token)
                        st.bind(4, s.complete ? 1 : 0); try step(st)
                    }
                }
            }
            if let folders = c.folders {
                try exec("DELETE FROM folders")
                try prepared("INSERT INTO folders VALUES(?,?,?,?,?)") { st in
                    var position = 0
                    for (a, list) in folders {
                        for f in list {
                            st.bind(1, a.uuidString); st.bind(2, f.box.rawValue); st.bind(3, f.name)
                            st.bind(4, f.parent?.rawValue); st.bind(5, position); try step(st)
                            position += 1
                        }
                    }
                }
            }
            if let outbox = c.outbox {
                try exec("DELETE FROM outbox")
                let encoder = JSONEncoder()
                try prepared("INSERT INTO outbox VALUES(?,?)") { st in
                    for (i, p) in outbox.enumerated() { st.bind(1, i); st.bind(2, try encoder.encode(p)); try step(st) }
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public func count() throws -> Int {
        try queue.sync {
            var n = 0
            try query("SELECT count(*) FROM messages") { n = $0.int(0) }
            return n
        }
    }

    // MARK: Moving from Cache.json

    /// Moves the old JSON cache into a new database, once: loads it into `store` (decoding off the main
    /// thread), writes everything under a temporary name, checks the count, and only then gives the database
    /// its name and renames the cache to `Cache.json.imported`. Interrupted at any point, the next launch
    /// imports again. Returns nil when there is no cache to import. A cache that can't be decoded is renamed
    /// to `Cache.json.unreadable` (never deleted) and an empty database is created: mail comes back from the server.
    @MainActor
    public static func importCache(from cacheURL: URL = MailCache.defaultURL, into url: URL = defaultURL,
                                   store: MailStore) async throws -> MailDatabase? {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return nil }
        guard let cache = await Task.detached(priority: .userInitiated, operation: { MailCache.load(from: cacheURL) }).value else {
            var aside = cacheURL.appendingPathExtension("unreadable")
            var n = 2
            while FileManager.default.fileExists(atPath: aside.path) {
                aside = cacheURL.appendingPathExtension("unreadable-\(n)")
                n += 1
            }
            try FileManager.default.moveItem(at: cacheURL, to: aside)
            let db = try await Task.detached(priority: .userInitiated) { try MailDatabase(url: url) }.value
            store.status = "The old mail cache couldn't be read. It was kept as \(aside.lastPathComponent); "
                + "mail is downloaded again from the server."
            return db
        }
        store.restore(cache)
        // The cache predates conversations: as for a database from before them, every folder syncs once more from
        // the start, so the imported mail learns its conversation.
        store.forgetSyncPositions()
        let everything = store.storedState()
        let db: MailDatabase
        do {
            db = try await Task.detached(priority: .userInitiated) { () throws -> MailDatabase in
                let temp = importingURL(for: url)
                removeFiles(temp)  // a half-written one from an interrupted import
                do {
                    let building = try MailDatabase(url: temp)
                    try building.write(everything)
                    guard try building.count() == everything.upserts.count else {
                        throw DatabaseError(errorDescription: "The new mail database is incomplete")
                    }
                }  // closed here: SQLite folds its journal into the file
                // Never over an existing database: that one may hold newer mail than the cache.
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    throw DatabaseError(errorDescription: "A mail database already exists")
                }
                for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
                try FileManager.default.moveItem(at: temp, to: url)
                removeFiles(temp)
                return try MailDatabase(url: url)
            }.value
        } catch {
            removeFiles(importingURL(for: url))
            throw error
        }
        try FileManager.default.moveItem(at: cacheURL, to: cacheURL.appendingPathExtension("imported"))
        return db
    }

    // MARK: Rows

    private static let columns = "id, account, mailbox, remote, date, read, flag, from_name, from_email, to_list, cc_list, "
        + "subject, body, category, bits, attachments, preview, invite, html, is_invite, html_checked, conversation"
    private static let columnCount = 22
    private static let upsertSet = columns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0 != "id" }.map { "\($0) = excluded.\($0)" }.joined(separator: ", ")

    // Bits: VIP, has attachments, body loaded.
    private static let vip = 1, attach = 2, loaded = 4

    /// Contacts as "name␟email␞name␟email": control characters that don't occur in names or addresses.
    private static func contacts(_ list: [Contact]) -> String {
        list.map { $0.name + "\u{1F}" + $0.email }.joined(separator: "\u{1E}")
    }

    private static func contacts(_ s: String) -> [Contact] {
        s.isEmpty ? [] : s.split(separator: "\u{1E}", omittingEmptySubsequences: false).map { c in
            let f = c.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            return Contact(name: String(f[0]), email: f.count > 1 ? String(f[1]) : "")
        }
    }

    /// Attachments as "name␟size␟type␞…". Older rows hold names only.
    static func attachments(_ list: [Attachment]) -> String {
        list.map { [$0.name, $0.size.map(String.init) ?? "", $0.contentType ?? ""].joined(separator: "\u{1F}") }
            .joined(separator: "\u{1E}")
    }

    static func attachments(_ s: String) -> [Attachment] {
        s.isEmpty ? [] : s.components(separatedBy: "\u{1E}").map { a in
            let f = a.components(separatedBy: "\u{1F}")
            return Attachment(name: f[0], size: f.count > 1 ? Int(f[1]) : nil,
                              contentType: f.count > 2 && !f[2].isEmpty ? f[2] : nil)
        }
    }

    private static func bind(_ m: Message, _ st: Statement) throws {
        st.bind(1, m.id.uuidString); st.bind(2, m.accountID.uuidString); st.bind(3, m.mailbox.rawValue)
        st.bind(4, m.remoteID); st.bind(5, m.date.timeIntervalSinceReferenceDate); st.bind(6, m.isRead ? 1 : 0)
        st.bind(7, m.flag?.rawValue); st.bind(8, m.from.name); st.bind(9, m.from.email); st.bind(10, contacts(m.to))
        st.bind(11, contacts(m.cc)); st.bind(12, m.subject); st.bind(13, m.body); st.bind(14, m.category.rawValue)
        st.bind(15, (m.isVIP ? vip : 0) | (m.hasAttachments ? attach : 0) | (m.bodyLoaded ? loaded : 0))
        st.bind(16, attachments(m.attachments)); st.bind(17, m.serverPreview)
        st.bind(18, try m.invite.map { try JSONEncoder().encode($0) }); st.bind(19, m.html)
        st.bind(20, m.isInvite.map { $0 ? 1 : 0 }); st.bind(21, m.htmlChecked.map { $0 ? 1 : 0 })
        st.bind(22, m.conversationID)
    }

    private static func message(_ r: Statement) -> Message? {
        guard let id = UUID(uuidString: r.text(0)), let account = UUID(uuidString: r.text(1)) else { return nil }
        let bits = r.int(14), files = r.text(15)
        var m = Message(id: id, accountID: account, mailbox: MailboxKind(rawValue: r.text(2)),
                        from: Contact(name: r.text(7), email: r.text(8)), to: contacts(r.text(9)), cc: contacts(r.text(10)),
                        subject: r.text(11), body: r.text(12), date: Date(timeIntervalSinceReferenceDate: r.double(4)),
                        isRead: r.int(5) == 1, flag: r.optionalText(6).flatMap(FlagColor.init(rawValue:)),
                        category: MailCategory(rawValue: r.text(13)) ?? .primary, isVIP: bits & vip != 0,
                        attachments: attachments(files),
                        remoteID: r.optionalText(3), hasAttachments: bits & attach != 0, serverPreview: r.optionalText(16),
                        bodyLoaded: bits & loaded != 0)
        m.invite = r.isNull(17) ? nil : try? JSONDecoder().decode(Invite.self, from: r.data(17))
        m.isInvite = r.isNull(19) ? nil : r.int(19) == 1
        m.html = r.optionalText(18)
        m.htmlChecked = r.isNull(20) ? nil : r.int(20) == 1
        m.conversationID = r.optionalText(21)
        return m
    }

    // MARK: SQLite

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            defer { sqlite3_free(err) }
            throw DatabaseError(errorDescription: "Mail database: " + (err.map { String(cString: $0) } ?? "error"))
        }
    }

    private func prepared(_ sql: String, on connection: OpaquePointer? = nil, _ body: (Statement) throws -> Void) throws {
        let c = connection ?? db
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(c, sql, -1, &st, nil) == SQLITE_OK else { throw lastError(c) }
        defer { sqlite3_finalize(st) }
        try body(Statement(st))
    }

    private func step(_ st: Statement) throws {
        guard sqlite3_step(st.pointer) == SQLITE_DONE else { throw lastError() }
        sqlite3_reset(st.pointer)
        sqlite3_clear_bindings(st.pointer)
    }

    private func query(_ sql: String, _ args: [String] = [], on connection: OpaquePointer? = nil,
                       _ row: (Statement) throws -> Void) throws {
        try prepared(sql, on: connection) { st in
            for (i, a) in args.enumerated() { st.bind(Int32(i + 1), a) }
            while true {
                let rc = sqlite3_step(st.pointer)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw lastError(connection ?? db) }
                try row(st)
            }
        }
    }

    private func lastError(_ connection: OpaquePointer? = nil) -> DatabaseError {
        DatabaseError(errorDescription: "Mail database: " + String(cString: sqlite3_errmsg(connection ?? db)))
    }
}

/// A prepared statement: binding parameters (1-based) and reading columns (0-based).
struct Statement {
    let pointer: OpaquePointer?
    init(_ p: OpaquePointer?) { pointer = p }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func bind(_ i: Int32, _ v: String?) {
        if let v { sqlite3_bind_text(pointer, i, v, -1, Self.transient) } else { sqlite3_bind_null(pointer, i) }
    }
    func bind(_ i: Int32, _ v: Int?) {
        if let v { sqlite3_bind_int64(pointer, i, Int64(v)) } else { sqlite3_bind_null(pointer, i) }
    }
    func bind(_ i: Int32, _ v: Double) { sqlite3_bind_double(pointer, i, v) }
    func bind(_ i: Int32, _ v: Data?) {
        guard let v else { sqlite3_bind_null(pointer, i); return }
        _ = v.withUnsafeBytes { sqlite3_bind_blob(pointer, i, $0.baseAddress, Int32(v.count), Self.transient) }
    }
    func bind(_ i: Int, _ v: String?) { bind(Int32(i), v) }
    func bind(_ i: Int, _ v: Int?) { bind(Int32(i), v) }
    func bind(_ i: Int, _ v: Double) { bind(Int32(i), v) }
    func bind(_ i: Int, _ v: Data?) { bind(Int32(i), v) }

    func isNull(_ c: Int32) -> Bool { sqlite3_column_type(pointer, c) == SQLITE_NULL }
    func text(_ c: Int32) -> String { sqlite3_column_text(pointer, c).map { String(cString: $0) } ?? "" }
    func optionalText(_ c: Int32) -> String? { isNull(c) ? nil : text(c) }
    func int(_ c: Int32) -> Int { Int(sqlite3_column_int64(pointer, c)) }
    func double(_ c: Int32) -> Double { sqlite3_column_double(pointer, c) }
    func data(_ c: Int32) -> Data {
        guard let p = sqlite3_column_blob(pointer, c) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(pointer, c)))
    }
}
