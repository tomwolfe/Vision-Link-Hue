import Foundation
import CryptoKit
import Security
import CommonCrypto
import os

/// Cryptographic signature validator for OTA configuration files.
/// Uses ECDSA P-256 signatures to verify the integrity and authenticity
/// of downloaded classification rules before they are applied to the
/// detection pipeline.
///
/// The public key is stored in the Keychain for persistence across app updates.
/// Signatures are verified before any JSON parsing occurs, preventing
/// injection of malicious classification rules.
///
/// Includes schema version validation to protect against version rollback attacks
/// where a malicious actor provides an older, signed, but vulnerable ruleset.
enum ECDSASignatureValidator {
    
    private static let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "ECDSASignatureValidator"
    )
    
    private static let signatureKeychainPrefix = "com.tomwolfe.visionlinkhue.ecdsa.pub."
    
    /// The minimum acceptable schema version for OTA configuration files.
    private static let minimumSchemaVersion = "1.1.0"
    
    /// Default ECDSA P-256 public key for OTA config verification, embedded at compile time.
    private static let defaultPublicKeyData: Data? = {
        #if DEBUG
        return nil
        #else
        guard let keyString = ProcessInfo.processInfo.environment["ECDSA_DEFAULT_PUBLIC_KEY"] else {
            return nil
        }
        return Data(base64Encoded: keyString)
        #endif
    }()
    
    /// The elliptic curve used for signature verification.
    enum Curve: String {
        case p256 = "P-256"
    }
    
    /// Error types for signature validation failures.
    enum SignatureError: Error, LocalizedError {
        case noSignatureProvided
        case invalidSignatureFormat
        case publicKeyNotFound
        case signatureVerificationFailed
        case corruptedPayload
        case schemaVersionTooLow(current: String, minimum: String)
        case schemaVersionMissing
        
        var errorDescription: String? {
            switch self {
            case .noSignatureProvided:
                return "No signature provided for OTA config verification"
            case .invalidSignatureFormat:
                return "Signature data is not in the expected format"
            case .publicKeyNotFound:
                return "Public key not found in Keychain for signature verification"
            case .signatureVerificationFailed:
                return "ECDSA signature verification failed - config may have been tampered with"
            case .corruptedPayload:
                return "Configuration payload is corrupted or incomplete"
            case .schemaVersionTooLow(let current, let minimum):
                return "Schema version \(current) is below minimum \(minimum) — possible version rollback attack"
            case .schemaVersionMissing:
                return "Configuration payload missing schema version field"
            }
        }
    }
    
    /// Configuration signature that includes the raw signature bytes
    /// and optionally a key identifier for multi-key rotation support.
    struct ConfigSignature: Sendable {
        let signature: Data
        let keyID: String?
        
        init(signature: Data, keyID: String? = nil) {
            self.signature = signature
            self.keyID = keyID
        }
    }
    
    /// Verify an ECDSA signature against a payload using a stored public key.
    static func verifySignature(
        payload: Data,
        signature: Data,
        keyID: String? = nil
    ) throws {
        guard !signature.isEmpty else {
            throw SignatureError.noSignatureProvided
        }
        
        guard let publicKey = try loadPublicKey(for: keyID) else {
            throw SignatureError.publicKeyNotFound
        }
        
        var messageHash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        payload.withUnsafeBytes { ptr in
            CC_SHA1(ptr.baseAddress, UInt32(ptr.count), &messageHash)
        }
        let messageHashData = Data(messageHash)
        
        var error: Unmanaged<CFError>?
        let verified = SecKeyVerifySignature(
            publicKey,
            .ecdsaSignatureMessageX962SHA1,
            messageHashData as CFData,
            signature as CFData,
            &error
        )
        
        guard verified else {
            logger.warning("ECDSA signature verification failed for OTA config: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
            throw SignatureError.signatureVerificationFailed
        }
        
        logger.info("ECDSA signature verified successfully for OTA config")
    }
    
    /// Verify a signature and decode JSON in a single safe operation.
    static func verifyAndDecode<T: Decodable>(
        data: Data,
        signature: Data,
        keyID: String? = nil,
        using decoder: JSONDecoder = JSONDecoder()
    ) async throws -> T {
        try verifySignature(payload: data, signature: signature, keyID: keyID)
        return try decoder.decode(T.self, from: data)
    }
    
    /// Extract the schema version from a JSON payload.
    static func extractSchemaVersion(from payload: Data) -> String? {
        do {
            let json = try JSONSerialization.jsonObject(with: payload, options: []) as? [String: Any]
            return json?["version"] as? String
        } catch {
            logger.debug("Failed to extract schema version from payload: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Verify that the schema version in the payload meets the minimum required version.
    static func verifySchemaVersion(payload: Data) throws {
        guard let versionString = extractSchemaVersion(from: payload) else {
            throw SignatureError.schemaVersionMissing
        }
        
        guard let currentVersion = parseVersion(versionString),
              let minimumVersion = parseVersion(minimumSchemaVersion) else {
            throw SignatureError.schemaVersionMissing
        }
        
        if currentVersion < minimumVersion {
            logger.warning("Schema version \(versionString) below minimum \(minimumSchemaVersion) — rejecting to prevent version rollback attack")
            throw SignatureError.schemaVersionTooLow(current: versionString, minimum: minimumSchemaVersion)
        }
        
        logger.info("Schema version \(versionString) meets minimum requirement \(minimumSchemaVersion)")
    }
    
    /// Parse a semantic version string into comparable components.
    static func parseVersion(_ versionString: String) -> (major: Int, minor: Int, patch: Int)? {
        let components = versionString.split(separator: ".")
        guard components.count == 3,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2]) else {
            return nil
        }
        return (major, minor, patch)
    }
    
    /// Verify an ECDSA signature and schema version in a single safe operation.
    static func verifySignatureAndSchema(
        payload: Data,
        signature: Data,
        keyID: String? = nil
    ) async throws {
        try verifySignature(payload: payload, signature: signature, keyID: keyID)
        try verifySchemaVersion(payload: payload)
    }
    
    /// Seed the default public key into the Keychain if none exists yet.
    static func seedDefaultPublicKeyIfNeeded() throws {
        guard let defaultKeyData = defaultPublicKeyData else {
            logger.warning("No default public key configured — OTA signature verification will fail on fresh install")
            return
        }
        
        let keychainKey = signatureKeychainPrefix + "default"
        
        guard try KeychainManager.shared.loadECDSAPublicKey(forKey: keychainKey) == nil else {
            logger.info("ECDSA public key already exists in Keychain, skipping seed")
            return
        }
        
        try KeychainManager.shared.saveECDSAPublicKey(defaultKeyData, forKey: keychainKey)
        logger.info("ECDSA default public key seeded into Keychain for fresh install")
    }
    
    /// Store a public key in the Keychain for future signature verification.
    static func storePublicKey(_ publicKey: SecKey, keyID: String = "default") throws {
        let keychainKey = signatureKeychainPrefix + keyID
        
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw SignatureError.publicKeyNotFound
        }
        
        try KeychainManager.shared.saveECDSAPublicKey(publicKeyData, forKey: keychainKey)
        logger.info("ECDSA public key stored in Keychain for keyID: \(keyID)")
    }
    
    /// Load a stored public key from the Keychain.
    static func loadPublicKey(for keyID: String? = nil) throws -> SecKey? {
        let keychainKey = signatureKeychainPrefix + (keyID ?? "default")
        
        guard let publicKeyData = try KeychainManager.shared.loadECDSAPublicKey(forKey: keychainKey) else {
            return nil
        }
        
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        
        guard let secKey = SecKeyCreateWithData(publicKeyData as CFData, attributes as CFDictionary, nil) else {
            throw SignatureError.publicKeyNotFound
        }
        
        return secKey
    }
    
    /// Generate a new ECDSA key pair for signing OTA configs.
    static func generateKeyPair(keyID: String = "default") throws -> (
        privateKey: SecKey,
        publicKey: SecKey
    ) {
        let privateKey = try generatePrivateKey()
        let publicKey = try extractPublicKey(from: privateKey)
        
        try storePublicKey(publicKey, keyID: keyID)
        
        logger.info("ECDSA key pair generated for keyID: \(keyID)")
        return (privateKey, publicKey)
    }
    
    /// Sign a payload using an ECDSA private key.
    static func sign(payload: Data, privateKey: SecKey) throws -> Data {
        var messageHash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        payload.withUnsafeBytes { ptr in
            CC_SHA1(ptr.baseAddress, UInt32(ptr.count), &messageHash)
        }
        let messageHashData = Data(messageHash)
        var error: Unmanaged<CFError>?
        
        guard let signature = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA1, messageHashData as CFData, &error) else {
            throw SignatureError.signatureVerificationFailed
        }
        
        return signature as Data
    }
    
    // MARK: - Private Helpers
    
    private static func generatePrivateKey() throws -> SecKey {
        let privateKey = P256.Signing.PrivateKey()
        
        let data = try privateKey.rawRepresentation
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        
        guard let secKey = SecKeyCreateWithData(data as CFData, attributes as CFDictionary, nil) else {
            throw SignatureError.publicKeyNotFound
        }
        
        return secKey
    }
    
    private static func extractPublicKey(from privateKey: SecKey) throws -> SecKey {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw SignatureError.publicKeyNotFound
        }
        
        return publicKey
    }
}
