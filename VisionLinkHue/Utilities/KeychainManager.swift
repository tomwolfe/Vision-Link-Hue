import Foundation
import Security
import CommonCrypto

// MARK: - Keychain Keys

enum KeychainKeys {
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
final class KeychainManager: @unchecked Sendable {
    
    static let shared = KeychainManager()
    
    private let queue = DispatchQueue(label: "com.tomwolfe.visionlinkhue.keychain")
    
    /// Save a certificate pin hash to the Keychain.
    /// - Parameters:
    ///   - keychainKey: The account key for this bridge's pin.
    ///   - hash: The SHA-256 hash of the certificate's public key.
    /// - Throws: `KeychainError.addFailed` if the operation fails.
    func saveCertPin(to keychainKey: String, hash: Data) async throws {
        try await queue.sync {
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
    }
    
    /// Load a certificate pin hash from the Keychain.
    /// - Parameter keychainKey: The account key for this bridge's pin.
    /// - Returns: The stored hash, or `nil` if not found.
    func loadCertPin(from keychainKey: String) async throws -> Data? {
        try await queue.sync {
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
    }
    
    /// Delete a certificate pin hash from the Keychain.
    /// - Parameter keychainKey: The account key for this bridge's pin.
    func deleteCertPin(from keychainKey: String) async {
        await queue.sync {
            let query: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrService as String: KeychainKeys.service,
                kSecAttrAccount as String: keychainKey,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
    
    // MARK: - ECDSA Keychain Operations
    
    /// Save an ECDSA public key to the Keychain.
    /// - Parameters:
    ///   - publicKeyData: The raw public key bytes.
    ///   - keyID: The account key for this ECDSA key.
    func saveECDSAPublicKey(_ publicKeyData: Data, forKey keyID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrService as String: KeychainKeys.service,
            kSecAttrAccount as String: keyID,
            kSecValueData as String: publicKeyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        ]
        SecItemDelete(query as CFDictionary)
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw KeychainError.addFailed
        }
    }
    
    /// Load an ECDSA public key from the Keychain.
    /// - Parameter keyID: The account key for this ECDSA key.
    /// - Returns: The stored public key bytes, or `nil` if not found.
    func loadECDSAPublicKey(forKey keyID: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrService as String: KeychainKeys.service,
            kSecAttrAccount as String: keyID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }
    
    /// Delete an ECDSA public key from the Keychain.
    /// - Parameter keyID: The account key for this ECDSA key.
    func deleteECDSAPublicKey(forKey keyID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrService as String: KeychainKeys.service,
            kSecAttrAccount as String: keyID,
        ]
        SecItemDelete(query as CFDictionary)
    }
    
    // MARK: - Generic Keychain Operations
    
    /// Save an arbitrary Data item to the Keychain.
    /// - Parameters:
    ///   - data: The Data to store.
    ///   - forKey: The account key for this item.
    /// - Throws: `KeychainError.addFailed` if the operation fails.
    func setItem(_ data: Data, forKey key: String) async throws {
        try await queue.sync {
            let query: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrService as String: KeychainKeys.service,
                kSecAttrAccount as String: key,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            SecItemDelete(query as CFDictionary)
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
                throw KeychainError.addFailed
            }
        }
    }
    
    /// Load an arbitrary Data item from the Keychain.
    /// - Parameter key: The account key for this item.
    /// - Returns: The stored Data, or `nil` if not found.
    /// - Throws: `KeychainError.queryFailed` if the query fails unexpectedly.
    func getItem(forKey key: String) async throws -> Data? {
        try await queue.sync {
            let query: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrService as String: KeychainKeys.service,
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
                return nil
            }
            return result as? Data
        }
    }
    
    /// Delete an arbitrary Data item from the Keychain.
    /// - Parameter key: The account key for this item.
    func removeItem(forKey key: String) async {
        await queue.sync {
            let query: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrService as String: KeychainKeys.service,
                kSecAttrAccount as String: key,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}
