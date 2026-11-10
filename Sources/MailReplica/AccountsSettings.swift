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
        if let cache = MailCache.load() { store.restore(cache) }
        return store
    }

    /// False while showing sample data; the disk cache is then neither read nor written.
    static var usesServer: Bool {
        !ExchangeAccount.saved().isEmpty && ProcessInfo.processInfo.environment["MAIL_SAMPLE_DATA"] == nil
    }

    private static var lastSave = (change: -1, at: Date.distantPast)

    /// Saves at most once a minute and only after a change. Encoding tens of thousands of messages takes
    /// a moment, so it happens off the main thread, except on quit (`now`).
    static func saveCache(_ store: MailStore, now: Bool = false) {
        guard usesServer else { return }
        guard now || (store.changeCount != lastSave.change && Date().timeIntervalSince(lastSave.at) > 60) else { return }
        lastSave = (store.changeCount, .now)
        let snapshot = store.cache()
        if now { try? snapshot.save(); return }
        Task.detached(priority: .utility) {
            do { try snapshot.save() } catch {
                await MainActor.run { store.status = "Couldn't save the mail cache: \(error.localizedDescription)" }
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
