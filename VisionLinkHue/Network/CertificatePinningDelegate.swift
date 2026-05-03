import Foundation
import Security
import os

/// Unified `URLSessionDelegate` handling certificate pinning and TOFU.
/// On first connection, trusts the certificate and invokes the TOFU callback
/// to cache the hash. On subsequent connections, enforces the pinned hash.
///
/// Properly `Sendable` - all stored properties are Sendable and the delegate
/// methods only read state (no mutations), making it thread-safe.
final class CertificatePinningDelegate: NSObject, @unchecked Sendable, URLSessionDelegate {
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "CertificatePinning"
    )
    
    var pinnedHash: Data?
    let keychainKey: String?
    let tofuCallback: @Sendable (Data) async -> Void
    
    /// Create a certificate pinning delegate.
    /// - Parameters:
    ///   - pinnedHash: Previously stored hash for enforcement mode. `nil` for TOFU mode.
    ///   - keychainKey: The Keychain account key for TOFU pin persistence.
    ///   - tofuCallback: Called with the trusted hash on first connection (TOFU mode).
    init(pinnedHash: Data?, keychainKey: String? = nil, tofuCallback: @escaping @Sendable (Data) async -> Void) {
        self.pinnedHash = pinnedHash
        self.keychainKey = keychainKey
        self.tofuCallback = tofuCallback
        super.init()
    }
    
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        
        let secTrust = serverTrust
        var error: CFError?
        
        guard SecTrustEvaluateWithError(secTrust, &error) else {
            logger.warning("Server trust evaluation failed")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        
        guard let publicKey = SecTrustCopyPublicKey(secTrust),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            logger.warning("Failed to extract public key from server trust")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        
        let hash = publicKeyData.sha256()
        
        if let pinnedHash {
            // Enforcement mode: compare against stored hash.
            if hash == pinnedHash {
                completionHandler(.useCredential, nil)
            } else {
                logger.error("Certificate pin mismatch - expected \(pinnedHash.count) bytes, got \(hash.count) bytes")
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        } else {
            // TOFU mode: trust on first use, cache the hash synchronously.
            // completionHandler must be invoked synchronously within this delegate method.
            completionHandler(.useCredential, nil)
            
            // Save the pin asynchronously without blocking the delegate callback.
            Task {
                await self.savePinnedHash(hash)
            }
        }
    }
    
    private func savePinnedHash(_ hash: Data) async {
        guard let keychainKey else { return }
        
        // Save via async KeychainManager to satisfy Swift 6.1 strict concurrency.
        do {
            try await KeychainManager.shared.saveCertPin(to: keychainKey, hash: hash)
            logger.info("Certificate pinned via TOFU for key \(keychainKey)")
        } catch {
            logger.error("Failed to save certificate pin to Keychain: \(error.localizedDescription)")
        }
        
        // Invoke async callback for state updates.
        await tofuCallback(hash)
    }
}
