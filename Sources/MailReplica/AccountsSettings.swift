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
        return store
    }

    /// The mail database; nil with sample data, or when it couldn't be opened (nothing is saved then).
    private static var database: MailDatabase?

    /// Loads stored mail in stages: the Inboxes first (shown at once), the rest in the background. The first
    /// launch after the update moves `Cache.json` into the database.
    static func loadMail(into store: MailStore) async {
        guard usesServer else { return }
        store.progress = SyncProgress(text: "Loading Mail…", fraction: nil)
        do {
            if !FileManager.default.fileExists(atPath: MailDatabase.defaultURL.path) {
                store.progress = SyncProgress(text: "Updating Mail Storage…", fraction: nil)
                if let db = try await MailDatabase.importCache(store: store) {
                    database = db
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
            }
        } catch {
            failedToLoad(store, error)
            if store.progress?.fraction == nil { store.progress = nil }
        }
    }

    /// Mail can't be loaded: work on without saving, so mail missing in memory isn't written twice to disk.
    private static func failedToLoad(_ store: MailStore, _ error: Error) {
        database = nil
        store.status = "Couldn't load mail from disk: \(error.localizedDescription). Changes aren't saved until relaunch."
        if store.isLoading { store.finishLoading([]) }
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
        db.writeInBackground(changes) { error in
            Task { @MainActor in
                store.retry(changes)
                store.status = "Couldn't save mail: \(error.localizedDescription)"
            }
        }
    }

    static func connect(_ a: ExchangeAccount, to store: MailStore) {
        if let backend = a.backend() {
            store.add(a.account, backend: backend)
        } else {
            store.accounts.append(a.account)
            store.status = "No password in the Keychain for \(a.username)"
        }
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
        let account = ExchangeAccount(email: email, username: username, server: server)
        guard let url = account.ewsURL else { message = "Invalid server"; return }
        guard let pw = password.isEmpty ? Keychain.password(for: username) : password else {
            message = "Enter the password"; return
        }
        message = "Connecting…"
        do {
            _ = try await EWSBackend(client: EWSClient(url: url, username: username, password: pw)).folders()
        } catch {
            message = error.localizedDescription
            return
        }
        if !password.isEmpty, !Keychain.setPassword(password, for: username) {
            message = "Couldn't save the password in the Keychain"; return
        }
        saved.append(account)
        ExchangeAccount.save(saved)
        store.removeLocalAccounts()
        AppSetup.connect(account, to: store)
        password = ""
        message = "Signed in"
        await store.refresh()
    }
}
