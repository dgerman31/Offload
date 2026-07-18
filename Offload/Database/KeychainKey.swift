import Foundation
import Security

/// Provisions and stores a random 256-bit key in the Keychain, protected by the Secure
/// Enclave and marked `WhenUnlockedThisDeviceOnly` (spec §6 / §2.1). The key is generated
/// once and reused; it is NEVER derived from the device passcode or any user input.
///
/// It's ready for optional SQLCipher (defense-in-depth) in a later increment. iOS Data
/// Protection already encrypts the sandbox at rest, so this is additive, not the baseline.
enum KeychainKey {
    enum KeychainError: Error { case unexpectedStatus(OSStatus) }

    private static let account = "com.danielgerman.offload.dbkey"

    /// Returns the existing key, generating and storing one on first use.
    static func loadOrCreate() throws -> Data {
        if let existing = try load() { return existing }
        let key = randomKey()
        try store(key)
        return key
    }

    static func load() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:   return item as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError.unexpectedStatus(status)
        }
    }

    private static func store(_ key: Data) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    private static func randomKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }
}
