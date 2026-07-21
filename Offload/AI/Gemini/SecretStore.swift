import Foundation
import Security

/// Keychain-backed storage for the one secret the app holds: the user's Gemini API key.
///
/// The key never touches UserDefaults or the database — it lives in the Keychain, encrypted at
/// rest and gated by the device passcode, and it never leaves the phone except to Google's own
/// endpoint. For a personal, single-user app this is the right model: your key, your device.
enum SecretStore {
    private static let service = "com.danielgerman.offload.secrets"
    static let geminiKeyAccount = "gemini.apiKey"

    @discardableResult
    static func set(_ value: String?, account: String) -> Bool {
        // Delete any existing value first, so this is a clean upsert.
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)

        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return true }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let string = String(data: data, encoding: .utf8),
              !string.isEmpty
        else { return nil }
        return string
    }

    // MARK: Gemini convenience

    static var geminiKey: String? {
        get { get(account: geminiKeyAccount) }
        set { set(newValue, account: geminiKeyAccount) }
    }

    static var hasGeminiKey: Bool { geminiKey != nil }
}
