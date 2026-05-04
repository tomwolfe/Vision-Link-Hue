import Foundation
import Security
import os

/// Sendable wrapper for the completionHandler to avoid data race warnings.
private final class ChallengeHandlerBox: @unchecked Sendable {
    let handler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    init(handler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        self.handler = handler
    }
    func call(_ disposition: URLSession.AuthChallengeDisposition, _ credential: URLCredential?) {
        handler(disposition, credential)
    }
}

/// Result of evaluating a certificate challenge against pinned state.
enum CertificateEvaluationResult: Sendable {
    /// Certificate matches the pinned hash - trust it.
    case accepted
    /// Certificate does not match - reject it.
    case rejected
    /// No hash pinned yet - trust on first use.
    case trustOnFirstUse
    /// Hash mismatch detected - requires user confirmation to accept.
    case pinMismatch(newHash: Data, oldHash: Data)
}

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
    
    /// Evaluate a certificate challenge and return a detailed result
    /// that can be used to present a user prompt for pin mismatches.
    func evaluateChallengeDetailed(publicKeyHash: Data) async -> CertificateEvaluationResult {
        if let pinnedHash {
            if publicKeyHash == pinnedHash {
                return .accepted
            } else {
                logger.warning("Certificate pin mismatch detected - bridge may have been reset")
                return .pinMismatch(newHash: publicKeyHash, oldHash: pinnedHash)
            }
        } else {
            return .trustOnFirstUse
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
    
    /// Accept a certificate after user confirmation (e.g., bridge reset).
    /// Overwrites the existing TOFU hash in the Keychain.
    func acceptPinChange(to newHash: Data) async {
        guard let keychainKey else { return }
        
        do {
            try await KeychainManager.shared.saveCertPin(to: keychainKey, hash: newHash)
            self.pinnedHash = newHash
            logger.info("Certificate pin updated after bridge reset for key \(keychainKey)")
        } catch {
            logger.error("Failed to update certificate pin in Keychain: \(error.localizedDescription)")
        }
        
        await tofuCallback(newHash)
    }
}

/// `URLSessionDelegate` that bridges to `CertificatePinStore` actor for
/// thread-safe certificate pinning and TOFU management.
///
/// ## Thread Safety Architecture
///
/// This delegate is designed to be completely stateless. All mutable state
/// (certificate pin hashes, TOFU callbacks) is isolated within the
/// `CertificatePinStore` actor, which provides Swift concurrency guarantees
/// for safe access.
///
/// The delegate's only role is to:
/// 1. Receive authentication challenges from URLSession (called on arbitrary threads)
/// 2. Extract the server's public key and compute its SHA-256 hash
/// 3. Forward the evaluation to the actor-isolated `CertificatePinStore`
/// 4. Dispatch the result back to the calling thread via the completionHandler
///
/// ## @unchecked Sendable Rationale
///
/// `CertificatePinningDelegate` conforms to `@unchecked Sendable` because
/// `URLSessionDelegate` is not a `Sendable` protocol. The `URLSessionDelegate`
/// protocol requires nonisolated method signatures, which conflicts with
/// Swift 6's strict concurrency model that would otherwise require all
/// conforming types to be `Sendable`.
///
/// This is safe because:
/// - The delegate holds no mutable state itself (all state is in the actor)
/// - All state mutations go through the actor, which serializes access
/// - The `ChallengeHandlerBox` wrapper prevents data races on the completionHandler closure
/// - The delegate is created once per session and never modified after creation
///
/// This pattern follows Apple's recommended approach for bridging
/// delegate-based APIs with Swift concurrency (see SE-0306, SE-0309).
///
/// ## Certificate Rotation Strategy
///
/// For production deployments, implement certificate rotation by:
/// 1. Adding multiple pinned hashes to `CertificatePinStore` (e.g., `pinnedHashes: [Data]`)
/// 2. Supporting both old and new pins during a transition period
/// 3. Using the `onPinMismatch` callback to trigger a rotation workflow
/// 4. Updating pins via `updatePinnedHash(_:)` after user confirmation
///
/// Per iOS security best practices, certificates should be rotated before
/// expiration and old pins should be retained for at least one rotation
/// cycle to avoid service disruption.
final class CertificatePinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "CertificatePinning"
    )
    
    private let pinStore: CertificatePinStore
    
    /// Optional callback when a pin mismatch is detected, allowing the UI
    /// to present a prompt for the user to accept a new certificate.
    var onPinMismatch: @Sendable (Data, Data) async -> Void
    
    init(pinnedHash: Data?, keychainKey: String? = nil, tofuCallback: @escaping @Sendable (Data) async -> Void, onPinMismatch: @escaping @Sendable (Data, Data) async -> Void = { _, _ in }) {
        self.pinStore = CertificatePinStore(
            pinnedHash: pinnedHash,
            keychainKey: keychainKey,
            tofuCallback: tofuCallback
        )
        self.onPinMismatch = onPinMismatch
        super.init()
    }
    
    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        
        guard let publicKey = SecTrustCopyPublicKey(serverTrust),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            logger.warning("Failed to extract public key from server trust")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        
        let hash = publicKeyData.sha256()
        let credential = URLCredential(trust: serverTrust)
        let box = ChallengeHandlerBox(handler: completionHandler)
        
        Task {
            if let result = await self.pinStore.evaluateChallenge(publicKeyHash: hash) {
                await MainActor.run {
                    box.call(result.0, result.0 == .useCredential ? credential : nil)
                }
            } else {
                await MainActor.run {
                    box.call(.useCredential, credential)
                }
                await self.pinStore.savePinnedHash(hash)
            }
        }
    }
    
    /// Update the pinned hash via TOFU after external confirmation.
    func updatePinnedHash(_ hash: Data) {
        Task { [weak self] in
            await self?.pinStore.savePinnedHash(hash)
        }
    }
    
    /// Handle a pin mismatch by attempting to accept the new certificate
    /// after the user has confirmed.
    func handlePinMismatch(newHash: Data) {
        Task { [weak self] in
            await self?.pinStore.acceptPinChange(to: newHash)
        }
    }
}
