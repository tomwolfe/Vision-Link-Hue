import Foundation
import Security
import os

/// Unified `URLSessionDelegate` handling certificate pinning and TOFU.
/// On first connection, trusts the certificate and invokes the TOFU callback
/// to cache the hash. On subsequent connections, enforces the pinned hash.
final class CertificatePinningDelegate: NSObject, @unchecked Sendable, URLSessionDelegate {
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "CertificatePinning"
    )
    
    let pinnedHash: Data?
    let tofuCallback: (Data) async -> Void
    
    /// Create a certificate pinning delegate.
    /// - Parameters:
    ///   - pinnedHash: Previously stored hash for enforcement mode. `nil` for TOFU mode.
    ///   - tofuCallback: Called with the trusted hash on first connection (TOFU mode).
    init(pinnedHash: Data?, tofuCallback: @escaping (Data) async -> Void) {
        self.pinnedHash = pinnedHash
        self.tofuCallback = tofuCallback
        super.init()
    }
    
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, SecCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        
        let secTrust = serverTrust.secTrust
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
            // TOFU mode: trust on first use, cache the hash.
            Task {
                await tofuCallback(hash)
                completionHandler(.useCredential, nil)
            }
        }
    }
}
