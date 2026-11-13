import Foundation
import MailModel
import Security

/// An Exchange account as entered in the setup sheet. The password lives in the Keychain, not here.
public struct ExchangeAccount: Codable, Hashable, Sendable {
    public var id: UUID
    public var email: String
    /// `DOMAIN\user`, as in Outlook and iOS Mail.
    public var username: String
    /// Host (`anywhere.example.com`) or full EWS URL.
    public var server: String

    public init(id: UUID = UUID(), email: String, username: String, server: String) {
        self.id = id; self.email = email; self.username = username; self.server = server
    }

    /// The server field as typed or pasted: a host (with port), or a URL. Blanks and line breaks around it, a
    /// trailing `/` and the standard `/EWS/Exchange.asmx` are dropped; `http://` is upgraded to https, since the
    /// password must not travel in clear text. A path ending in `.asmx` is used as given. Nil for a blank field.
    public var ewsURL: URL? {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["https://", "http://"] where s.lowercased().hasPrefix(scheme) { s.removeFirst(scheme.count) }
        while s.hasSuffix("/") { s.removeLast() }
        let standard = "/EWS/Exchange.asmx"
        if s.lowercased().hasSuffix(standard.lowercased()) { s.removeLast(standard.count) }
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty, !s.hasPrefix("/"), s.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        let path = s.lowercased().hasSuffix(".asmx") && s.contains("/") ? "" : standard
        guard let url = URL(string: "https://\(s)\(path)"), url.host?.isEmpty == false else { return nil }
        return url
    }

    /// Named after its address, so two accounts can be told apart in the sidebar, titles and notices. The address
    /// is the email without blanks around it (pasted), so comparisons with it work (BUG-169).
    public var account: Account {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return Account(id: id, name: address.isEmpty ? "Exchange" : address, address: address, isServer: true)
    }

    /// The Keychain accounts its password may be stored under, first match wins: "user@host", so two accounts with
    /// the same username on different servers keep their own (BUG-252); then the username alone, as stored before.
    public var keychainAccounts: [String] {
        guard let host = ewsURL?.host?.lowercased() else { return [username] }
        return ["\(username)@\(host)", username]
    }

    public var password: String? { keychainAccounts.lazy.compactMap(Keychain.password(for:)).first }

    /// Stores the password under the first of `keychainAccounts`.
    public func setPassword(_ password: String) -> Bool { Keychain.setPassword(password, for: keychainAccounts[0]) }

    /// A backend for this account, or nil if the server is invalid or no password is stored.
    public func backend() -> EWSBackend? {
        guard let url = ewsURL, let pw = password else { return nil }
        return EWSBackend(client: EWSClient(url: url, username: username, password: pw))
    }

    // MARK: Persistence (UserDefaults)

    static let defaultsKey = "exchangeAccounts"

    public static func saved(_ defaults: UserDefaults = .standard) -> [ExchangeAccount] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([ExchangeAccount].self, from: data)) ?? []
    }

    public static func save(_ accounts: [ExchangeAccount], _ defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(accounts), forKey: defaultsKey)
    }
}

/// Generic-password items under service `MailReplica-EWS`, keyed by username.
public enum Keychain {
    public static let service = "MailReplica-EWS"

    public static func password(for user: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: user, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func setPassword(_ password: String, for user: String) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: user]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = Data(password.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
