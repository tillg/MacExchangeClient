import EWS
import MailModel
import SwiftUI

@MainActor
enum AppSetup {
    /// Exchange accounts if any are configured, otherwise the sample data. `MAIL_SAMPLE_DATA=1` forces samples.
    static func makeStore() -> MailStore {
        guard usesServer else { return SampleData.store() }
        let store = MailStore(accounts: [], messages: [])
        for a in ExchangeAccount.saved() { connect(a, to: store) }
        store.saveBeforeSending = { [weak store] in if let store { await saveAndWait(store) } }
        return store
    }

    /// The mail database; nil with sample data, or when it couldn't be opened (nothing is saved then).
    private static var database: MailDatabase?
    /// Stored mail is loaded once per launch, whichever viewer window asks first (BUG-219).
    private static var loadStarted = false
    /// A viewer window's poll loop is running (`MailReplicaApp.pollForMail`).
    static var isPolling = false

    /// Loads stored mail in stages: the Inboxes first (shown at once), the rest in the background. The first
    /// launch after the update moves `Cache.json` into the database.
    static func loadMail(into store: MailStore) async {
        guard usesServer, !loadStarted else { return }
        loadStarted = true
        store.progress = SyncProgress(text: "Loading Mail…", fraction: nil)
        do {
            if !FileManager.default.fileExists(atPath: MailDatabase.defaultURL.path) {
                store.progress = SyncProgress(text: "Updating Mail Storage…", fraction: nil)
                if let db = try await MailDatabase.importCache(store: store) {
                    database = db
                    enableSearch(store, db)  // a new database has its search index already
                    store.progress = nil
                    return
                }
            }
            let first = store.accounts.map { MailboxKey(account: $0.id, mailbox: .inbox) }
            let (db, meta, inboxes) = try await Task.detached(priority: .userInitiated) {
                let db = try MailDatabase(url: MailDatabase.defaultURL)
                return (db, try db.meta(), try db.messages(in: first))
            }.value
            database = db
            if let aside = db.setAside {
                store.status = "The mail database couldn't be read. It was kept as \(aside.lastPathComponent); "
                    + "mail is downloaded again from the server."
            }
            store.restore(meta)
            store.restore(inboxes, boxes: first)
            // The rest arrives while the Inbox is already usable and checked with the server.
            Task {
                do {
                    let rest = try await Task.detached(priority: .userInitiated) { try db.messages(notIn: first) }.value
                    store.finishLoading(rest)
                } catch {
                    failedToLoad(store, error)
                }
                if store.progress?.fraction == nil { store.progress = nil }
                // Builds the search index of an older database, once; search scans memory until then.
                guard database != nil else { return }
                do {
                    try await Task.detached(priority: .utility) { try db.prepareSearch() }.value
                    if database != nil { enableSearch(store, db) }
                } catch {
                    store.status = "Couldn't build the search index: \(error.localizedDescription)"
                }
            }
        } catch {
            failedToLoad(store, error)
            if store.progress?.fraction == nil { store.progress = nil }
        }
    }

    /// Mail can't be loaded: work on without saving, so mail missing in memory isn't written twice to disk.
    private static func failedToLoad(_ store: MailStore, _ error: Error) {
        database = nil
        store.searcher = nil
        store.status = "Couldn't load mail from disk: \(error.localizedDescription). Changes aren't saved until relaunch."
        if store.isLoading { store.finishLoading([]) }
    }

    /// Search asks the database's index from now on.
    private static func enableSearch(_ store: MailStore, _ db: MailDatabase) {
        store.searcher = { query, accounts in try db.search(query, accounts: accounts) }
    }

    /// False while showing sample data; nothing is then read from or written to disk.
    static var usesServer: Bool {
        !ExchangeAccount.saved().isEmpty && ProcessInfo.processInfo.environment["MAIL_SAMPLE_DATA"] == nil
    }

    /// Writes what changed since the last call, in the background; on quit (`now`) before returning.
    static func saveChanges(_ store: MailStore, now: Bool = false) {
        guard let db = database else { return }
        let changes = store.takeChanges()
        if now { try? db.write(changes); return }
        db.writeInBackground(changes, done: {
            // The index now has what arrived since the last save.
            Task { @MainActor in store.searchAgain() }
        }) { error in
            Task { @MainActor in
                store.retry(changes)
                store.status = "Couldn't save mail: \(error.localizedDescription)"
            }
        }
    }

    /// Without a password in the Keychain the account is still an Exchange account: its mail and drafts stay,
    /// and its changes wait until it is signed in again.
    /// Writes what changed and returns once it is on disk: before a send goes out, so its in-flight mark is saved.
    static func saveAndWait(_ store: MailStore) async {
        guard let db = database else { return }
        let changes = store.takeChanges()
        guard !changes.isEmpty else { return }  // writeInBackground calls neither closure then
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            db.writeInBackground(changes, done: { done.resume() }) { error in
                Task { @MainActor in
                    store.retry(changes)
                    store.status = "Couldn't save mail: \(error.localizedDescription)"
                }
                done.resume()
            }
        }
    }

    static func connect(_ a: ExchangeAccount, to store: MailStore) {
        let backend = a.backend()
        store.add(a.account, backend: backend)
        if backend == nil { store.status = "Password needed for \(a.email). Sign in again in Settings ▸ Accounts." }
    }
}

/// Settings ▸ Accounts: sign in to an Exchange server, like Mail's account setup.
struct AccountsSettings: View {
    @Environment(MailStore.self) private var store
    @State private var email = ""
    @State private var username = ""
    @State private var password = ""
    @State private var server = ""
    @State private var message: String?
    @State private var busy = false
    @State private var saved = ExchangeAccount.saved()

    var body: some View {
        Form {
            if !saved.isEmpty {
                Section("Accounts") {
                    ForEach(saved, id: \.id) { a in
                        LabeledContent(a.email, value: a.server)
                    }
                }
            }
            Section("Add Exchange Account") {
                TextField("Email", text: $email, prompt: Text("name@example.com"))
                TextField("Username", text: $username, prompt: Text("DOMAIN\\user"))
                SecureField("Password", text: $password, prompt: Text("Leave empty to use the Keychain"))
                TextField("Server", text: $server, prompt: Text("mail.example.com"))
                HStack {
                    if let message { Text(message).foregroundStyle(.secondary).lineLimit(3) }
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button("Sign In") { Task { await signIn() } }
                        .disabled(busy || email.isEmpty || username.isEmpty || server.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    /// Checks the credentials against the server before saving anything.
    private func signIn() async {
        busy = true
        defer { busy = false }
        // Signing in again (e.g. to enter a missing password) keeps the account and its mail.
        let typed = ExchangeAccount(email: email, username: username, server: server)
        let account = saved.first {
            // Usernames (DOMAIN\\user) compare without case, as Windows does (BUG-242).
            $0.email.caseInsensitiveCompare(email) == .orderedSame && $0.username.caseInsensitiveCompare(username) == .orderedSame
                && $0.ewsURL == typed.ewsURL
        } ?? typed
        guard let url = account.ewsURL else { message = "Invalid server"; return }
        guard let pw = password.isEmpty ? account.password : password else {
            message = "Enter the password"; return
        }
        message = "Connecting…"
        do {
            _ = try await EWSBackend(client: EWSClient(url: url, username: username, password: pw)).folders()
        } catch {
            message = error.localizedDescription
            return
        }
        if !password.isEmpty, !account.setPassword(password) {
            message = "Couldn't save the password in the Keychain"; return
        }
        if !saved.contains(account) { saved.append(account) }
        ExchangeAccount.save(saved)
        store.removeLocalAccounts()
        AppSetup.connect(account, to: store)
        password = ""
        message = "Signed in"
        await store.refresh()
    }
}
