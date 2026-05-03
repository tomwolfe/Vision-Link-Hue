import Foundation
import Security
import os

/// Actor that manages certificate pin state with proper Swift concurrency isolation.
/// All mutable state (`pinnedHash`) is confined to the actor, eliminating the need
/// for `@unchecked Sendable` suppression.
actor CertificatePinStore {
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "CertificatePinning"
    )
    
    var pinnedHash: Data?
    let keychainKey: String?
    let tofuCallback: @Sendable (Data) async -> Void
    
    init(pinnedHash: Data?, keychainKey: String?, tofuCallback: @Sendable @escaping (Data) async -> Void) {
        self.pinnedHash = pinnedHash
        self.keychainKey = keychainKey
        self.tofuCallback = tofuCallback
    }
    
    /// Evaluate a certificate challenge against the pinned hash.
    /// Returns the disposition and credential, or nil for TOFU mode
    /// where the caller must handle the async TOFU flow.
    func evaluateChallenge(publicKeyHash: Data) async -> (URLSession.AuthChallengeDisposition, URLCredential?)? {
        if let pinnedHash {
            // Enforcement mode: compare against stored hash.
            if publicKeyHash == pinnedHash {
                return (.useCredential, nil)
            } else {
                logger.error("Certificate pin mismatch - expected \(pinnedHash.count) bytes, got \(publicKeyHash.count) bytes")
                return (.cancelAuthenticationChallenge, nil)
            }
        } else {
            // TOFU mode: trust on first use, return nil to signal caller
            // should proceed with async TOFU callback.
            return nil
        }
    }
    
    /// Save a newly trusted certificate hash via TOFU.
    func savePinnedHash(_ hash: Data) async {
        guard let keychainKey else { return }
        
        do {
            try await KeychainManager.shared.saveCertPin(to: keychainKey, hash: hash)
            self.pinnedHash = hash
            logger.info("Certificate pinned via TOFU for key \(keychainKey)")
        } catch {
            logger.error("Failed to save certificate pin to Keychain: \(error.localizedDescription)")
        }
        
        await tofuCallback(hash)
    }
}

/// `URLSessionDelegate` that bridges to `CertificatePinStore` actor for
/// thread-safe certificate pinning and TOFU management.
///
/// The delegate itself is stateless and only holds a reference to the actor.
/// All mutable state is isolated within the actor, satisfying Swift 6.1
/// strict concurrency without `@unchecked Sendable`.
final class CertificatePinningDelegate: NSObject, URLSessionDelegate {
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "CertificatePinning"
    )
    
    private let pinStore: CertificatePinStore
    
    init(pinnedHash: Data?, keychainKey: String? = nil, tofuCallback: @escaping @Sendable (Data) async -> Void) {
        self.pinStore = CertificatePinStore(
            pinnedHash: pinnedHash,
            keychainKey: keychainKey,
            tofuCallback: tofuCallback
        )
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
        
        Task { [weak self] in
            guard let self else { return }
            
            if let result = await self.pinStore.evaluateChallenge(publicKeyHash: hash) {
                completionHandler(result.0, result.1)
            } else {
                // TOFU mode: trust the certificate and save asynchronously.
                completionHandler(.useCredential, nil)
                await self.pinStore.savePinnedHash(hash)
            }
        }
    }
    
    /// Update the pinned hash via TOFU after external confirmation.
    func updatePinnedHash(_ hash: Data) {
        Task { [weak self] in
            await self?.pinStore.pinnedHash = hash
        }
    }
}
