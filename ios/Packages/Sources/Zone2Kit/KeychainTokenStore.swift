import Foundation
import Security

/// Tokens in the Keychain, readable after first unlock (background sync runs while locked).
/// The Mac overlay keeps its own item (`service`): it signs in separately from the phone.
public final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(account: String, service: String = "day.zone2.app.oauth") {
        self.account = account
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() -> TokenSet? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(TokenSet.self, from: data)
    }

    /// Replaces the item in place: delete-then-add would lose the tokens if the app is suspended
    /// or killed between the two calls (background wakes) — a sign-out with nothing on the server.
    public func save(_ tokens: TokenSet?) {
        guard let tokens else {
            SecItemDelete(query as CFDictionary)
            return
        }
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var q = query
            q.merge(attrs) { $1 }
            SecItemAdd(q as CFDictionary, nil)
        }
    }
}
