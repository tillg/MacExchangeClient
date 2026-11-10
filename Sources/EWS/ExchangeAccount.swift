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

    public var ewsURL: URL? {
        let s = server.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("https://") { return URL(string: s) }
        return URL(string: "https://\(s)/EWS/Exchange.asmx")
    }

    public var account: Account { Account(id: id, name: "Exchange", address: email) }

    /// A backend for this account, or nil if the server is invalid or no password is stored.
    public func backend() -> EWSBackend? {
        guard let url = ewsURL, let pw = Keychain.password(for: username) else { return nil }
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
