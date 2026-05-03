import Foundation
import Security
import CommonCrypto

// MARK: - Keychain Keys

private enum KeychainKeys {
    static let service = "com.tomwolfe.visionlinkhue.certpins"
    static func key(for bridgeIP: String) -> String { "certpin_\(bridgeIP)" }
}

// MARK: - Keychain Errors

enum KeychainError: Error, LocalizedError {
    case addFailed, queryFailed, accessFailed
    
    var errorDescription: String? {
        switch self {
        case .addFailed: return "Failed to add item to Keychain"
        case .queryFailed: return "Failed to query Keychain"
        case .accessFailed: return "Failed to access Keychain"
        }
    }
}

// MARK: - Keychain Actor

/// Async-safe Keychain manager for certificate pin hashes used in
/// Trust-On-First-Use (TOFU) pinning.
/// All operations are async to avoid blocking the calling thread,
/// satisfying Swift 6.1 strict-concurrency requirements.
actor KeychainManager {
    
    static let shared = KeychainManager()
    
    /// Save a certificate pin hash to the Keychain.
    /// - Parameters:
    ///   - keychainKey: The account key for this bridge's pin.
    ///   - hash: The SHA-256 hash of the certificate's public key.
    /// - Throws: `KeychainError.addFailed` if the operation fails.
    func saveCertPin(to keychainKey: String, hash: Data) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrService as String: KeychainKeys.service,
            kSecAttrAccount as String: keychainKey,
            kSecValueData as String: hash,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(query as CFDictionary)
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw KeychainError.addFailed
        }
    }
    
    /// Load a certificate pin hash from the Keychain.
    /// - Parameter keychainKey: The account key for this bridge's pin.
    /// - Returns: The stored hash, or `nil` if not found.
    func loadCertPin(from keychainKey: String) async throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrService as String: KeychainKeys.service,
            kSecAttrAccount as String: keychainKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }
    
    /// Delete a certificate pin hash from the Keychain.
    /// - Parameter keychainKey: The account key for this bridge's pin.
    func deleteCertPin(from keychainKey: String) async {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrService as String: KeychainKeys.service,
            kSecAttrAccount as String: keychainKey,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
