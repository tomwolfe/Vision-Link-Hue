import Foundation
import CryptoKit
import Security
import os

/// Cryptographic signature validator for OTA configuration files.
/// Uses ECDSA P-256 signatures to verify the integrity and authenticity
/// of downloaded classification rules before they are applied to the
/// detection pipeline.
///
/// The public key is stored in the Keychain for persistence across app updates.
/// Signatures are verified before any JSON parsing occurs, preventing
/// injection of malicious classification rules.
enum ECDSASignatureValidator {
    
    private static let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "ECDSASignatureValidator"
    )
    
    private static let signatureKeychainPrefix = "com.tomwolfe.visionlinkhue.ecdsa.pub."
    
    /// The elliptic curve used for signature verification.
    /// P-256 provides 128-bit security and is supported by CryptoKit.
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
    /// - Parameters:
    ///   - payload: The raw configuration data that was signed.
    ///   - signature: The ECDSA signature to verify.
    ///   - keyID: Optional key identifier for multi-key rotation support.
    /// - Throws: `SignatureError` if verification fails.
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
        
        guard let signatureComponents = parseSignature(signature) else {
            throw SignatureError.invalidSignatureFormat
        }
        
        let signatureData = try createSignatureData(components: signatureComponents)
        let messageHash = Insecure.SHA1.hash(payload)
        
        guard publicKey.verifySignature(signatureData, for: messageHash) else {
            logger.warning("ECDSA signature verification failed for OTA config")
            throw SignatureError.signatureVerificationFailed
        }
        
        logger.info("ECDSA signature verified successfully for OTA config")
    }
    
    /// Verify a signature and decode JSON in a single safe operation.
    /// - Parameters:
    ///   - data: The raw JSON data with an attached signature.
    ///   - signature: The ECDSA signature to verify.
    ///   - keyID: Optional key identifier for multi-key rotation support.
    ///   - decoder: JSONDecoder to use for decoding.
    /// - Returns: The decoded configuration object.
    /// - Throws: `SignatureError` if verification fails, or any decoding error.
    static func verifyAndDecode<T: Decodable>(
        data: Data,
        signature: Data,
        keyID: String? = nil,
        using decoder: JSONDecoder = JSONDecoder()
    ) throws -> T {
        try verifySignature(payload: data, signature: signature, keyID: keyID)
        return try decoder.decode(T.self, from: data)
    }
    
    /// Store a public key in the Keychain for future signature verification.
    /// - Parameters:
    ///   - publicKey: The ECDSA public key to store.
    ///   - keyID: Optional key identifier. Defaults to "default".
    static func storePublicKey(_ publicKey: P256.ECDSAA.signature.VerificationKey, keyID: String = "default") throws {
        let keychainKey = signatureKeychainPrefix + keyID
        
        guard let publicKeyData = try? publicKey.rawRepresentation else {
            throw SignatureError.publicKeyNotFound
        }
        
        try KeychainManager.shared.saveECDSAPublicKey(publicKeyData, forKey: keychainKey)
        logger.info("ECDSA public key stored in Keychain for keyID: \(keyID)")
    }
    
    /// Load a stored public key from the Keychain.
    /// - Parameter keyID: Optional key identifier. Defaults to "default".
    /// - Returns: The verification key, or nil if not found.
    static func loadPublicKey(for keyID: String? = nil) throws -> P256.ECDSAA.signature.VerificationKey? {
        let keychainKey = signatureKeychainPrefix + (keyID ?? "default")
        
        guard let publicKeyData = try? KeychainManager.shared.loadECDSAPublicKey(forKey: keychainKey) else {
            return nil
        }
        
        return try P256.ECDSAA.signature.VerificationKey(rawRepresentation: publicKeyData)
    }
    
    /// Generate a new ECDSA key pair for signing OTA configs.
    /// Returns the private key (for signing) and public key (for verification).
    /// The public key is automatically stored in the Keychain.
    /// - Parameter keyID: Optional key identifier. Defaults to "default".
    /// - Returns: A tuple of (privateKey, publicKey).
    static func generateKeyPair(keyID: String = "default") throws -> (
        privateKey: P256.ECDSAA.signature.SigningPrivateKey,
        publicKey: P256.ECDSAA.signature.VerificationKey
    ) {
        let privateKey = P256.ECDSAA.signature.SigningPrivateKey.random()
        let publicKey = privateKey.publicKey
        
        try storePublicKey(publicKey, keyID: keyID)
        
        logger.info("ECDSA key pair generated for keyID: \(keyID)")
        return (privateKey, publicKey)
    }
    
    /// Sign a payload using an ECDSA private key.
    /// - Parameters:
    ///   - payload: The data to sign.
    ///   - privateKey: The private key for signing.
    /// - Returns: The raw signature bytes.
    static func sign(payload: Data, privateKey: P256.ECDSAA.signature.SigningPrivateKey) -> Data {
        let messageHash = Insecure.SHA1.hash(payload)
        let signature = privateKey.signature(for: messageHash)
        return signature.rawSignature
    }
    
    private static func parseSignature(_ signature: Data) -> (r: Scalar, s: Scalar)? {
        guard signature.count == 128 else { return nil }
        
        let rBytes = signature[0..<64]
        let sBytes = signature[64..<128]
        
        guard let rData = Data(rBytes), let sData = Data(sBytes) else { return nil }
        
        let r: P256.ECDSAA.signature.SigningScalar.Scalar
        let s: P256.ECDSAA.signature.SigningScalar.Scalar
        
        do {
            r = try .init(representation: rData)
        } catch {
            return nil
        }
        
        do {
            s = try .init(representation: sData)
        } catch {
            return nil
        }
        
        return (r, s)
    }
    
    private static func createSignatureData(components: (r: Scalar, s: Scalar)) throws -> Signature {
        let signature = P256.ECDSAA.signature.SigningSignature(r: components.r, s: components.s)
        return signature.rawSignature
    }
    
    private enum Scalar {
        case p256(P256.ECDSAA.signature.SigningScalar.Scalar)
        
        init(_ scalar: P256.ECDSAA.signature.SigningScalar.Scalar) {
            self = .p256(scalar)
        }
    }
}
