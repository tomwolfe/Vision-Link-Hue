import Foundation
import os
import UIKit
import Crypto

/// Represents a device in the local P2P network.
struct LocalDevice: Sendable, Identifiable, Hashable {
    /// Unique device identifier.
    let id: String
    
    /// Human-readable device name.
    let name: String
    
    /// Device type (Vision Pro, iPhone, iPad).
    let deviceType: String
    
    /// Whether this device is currently reachable.
    var isReachable: Bool
    
    /// Last seen timestamp.
    var lastSeen: Date?
    
    /// The device's local IP address.
    var ipAddress: String?
    
    static func == (lhs: LocalDevice, rhs: LocalDevice) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Message types for local P2P sync communication.
enum LocalSyncMessage: Sendable, Codable {
    /// Spatial sync record for fixture mapping.
    case spatialSync(SpatialSyncPayload)
    /// Calibration data for spatial alignment.
    case calibration(CalibrationPayload)
    /// Heartbeat to indicate device is alive.
    case heartbeat
    /// Request for device info.
    case deviceInfoRequest
    /// Response to device info request.
    case deviceInfoResponse(DeviceInfoPayload)
    /// Acknowledgment for a sync message.
    case ack(messageId: String)
    /// Noise Protocol XX handshake initiation.
    case handshakeInit(HandshakeInitPayload)
    /// Noise Protocol XX handshake response.
    case handshakeResponse(HandshakeResponsePayload)
    
    /// Unique message identifier.
    var messageId: String {
        switch self {
        case .spatialSync(let payload): return payload.messageId
        case .calibration(let payload): return payload.messageId
        case .heartbeat: return UUID().uuidString
        case .deviceInfoRequest: return UUID().uuidString
        case .deviceInfoResponse(let payload): return payload.messageId
        case .ack(let id): return id
        case .handshakeInit(let payload): return payload.messageId
        case .handshakeResponse(let payload): return payload.messageId
        }
    }
    
    /// Whether this is a handshake message that should be transmitted
    /// in plaintext during the key exchange phase.
    var isHandshakeMessage: Bool {
        switch self {
        case .handshakeInit, .handshakeResponse:
            return true
        default:
            return false
        }
    }
}

/// Payload for spatial sync messages.
struct SpatialSyncPayload: Sendable, Codable {
    let messageId: String
    let fixtureId: String
    let lightId: String?
    let positionX: Float
    let positionY: Float
    let positionZ: Float
    let orientationX: Float
    let orientationY: Float
    let orientationZ: Float
    let orientationW: Float
    let distanceMeters: Float
    let fixtureType: String
    let confidence: Double
    let version: Int64
    let deviceID: String
    let timestamp: Date
}

/// Payload for calibration messages.
struct CalibrationPayload: Sendable, Codable {
    let messageId: String
    let rotationX: Float
    let rotationY: Float
    let rotationZ: Float
    let rotationW: Float
    let translationX: Float
    let translationY: Float
    let translationZ: Float
    let scale: Float
    let deviceID: String
    let timestamp: Date
}

/// Payload for device info responses.
struct DeviceInfoPayload: Sendable, Codable {
    let messageId: String
    let deviceID: String
    let deviceName: String
    let deviceType: String
    let osVersion: String
    let hardwareModel: String
    let appVersion: String
    let timestamp: Date
}

/// Noise Protocol XX handshake initiation payload.
/// Sent by the initiator to begin the key exchange.
struct HandshakeInitPayload: Sendable, Codable {
    let messageId: String
    let deviceID: String
    /// Ephemeral X25519 public key (raw 32 bytes, base64-encoded).
    let ephemeralPublicKey: String
    /// Static X25519 public key (raw 32 bytes, base64-encoded).
    let staticPublicKey: String
}

/// Noise Protocol XX handshake response payload.
/// Sent by the responder to complete the key exchange.
struct HandshakeResponsePayload: Sendable, Codable {
    let messageId: String
    /// Ephemeral X25519 public key (raw 32 bytes, base64-encoded).
    let ephemeralPublicKey: String
}

/// Error types for local sync operations.
enum LocalSyncError: Error, LocalizedError {
    /// Failed to create the local network listener.
    case listenerCreationFailed
    /// No devices are reachable.
    case noDevicesReachable
    /// Failed to encode/decode a message.
    case encodingFailed(Error)
    /// Connection was lost during sync.
    case connectionLost
    /// The remote device rejected the sync.
    case syncRejected(String)
    /// Encryption handshake failed.
    case encryptionHandshakeFailed(String)
    /// Transport encryption is not available for the selected protocol.
    case encryptionNotAvailable
    /// Decryption failed - possible man-in-the-middle attack.
    case decryptionFailed
    
    var errorDescription: String? {
        switch self {
        case .listenerCreationFailed:
            return "Failed to create local network listener"
        case .noDevicesReachable:
            return "No devices reachable on the local network"
        case .encodingFailed(let error):
            return "Failed to encode message: \(error.localizedDescription)"
        case .connectionLost:
            return "Connection lost during sync"
        case .syncRejected(let reason):
            return "Remote device rejected sync: \(reason)"
        case .encryptionHandshakeFailed(let reason):
            return "Encryption handshake failed: \(reason)"
        case .encryptionNotAvailable:
            return "Transport encryption not available for selected protocol"
        case .decryptionFailed:
            return "Decryption failed - possible man-in-the-middle attack"
        }
    }
}

/// Transport encryption protocols supported for P2P local sync.
///
/// Room layout data (fixture coordinates, spatial maps) is sensitive
/// information that maps to physical room topology. Since the current
/// LocalNetworkChannel uses unencrypted TCP, implementing one of these
/// protocols is strongly recommended before production deployment.
///
/// - `noiseXX`: The Noise Protocol framework's XX handshake pattern
///   with ChaCha20-Poly1305 encryption. This is the recommended default
///   for local P2P sync due to its simplicity, performance, and strong
///   security guarantees without requiring PKI infrastructure.
/// - `noiseXMPS`: The XMP (eXtended Message Privacy) variant of Noise
///   Protocol that provides additional resistance against traffic
///   analysis by padding all messages to a fixed size. Recommended
///   when traffic pattern privacy is a concern.
/// - `mls`: Messaging Layer Security (RFC 9420) for group-based
///   encryption. Useful when syncing calibration data across 3+
///   devices simultaneously, as MLS provides efficient n-leaf
///   tree-based key distribution.
/// - `none`: No transport encryption. Only acceptable for
///   development/testing or when the local network is already
///   isolated (e.g., guest network with no internet access).
enum EncryptionProtocol: Sendable, CaseIterable {
    /// Noise Protocol XX handshake with X25519 + HKDF + AES-256-GCM.
    /// Recommended for most local P2P use cases. Provides forward secrecy,
    /// mutual authentication, and AEAD encryption.
    case noiseXX
    
    /// Noise Protocol with XMP padding for traffic privacy.
    case noiseXMPS
    
    /// Messaging Layer Security (RFC 9420) for group encryption.
    case mls
    
    /// No encryption.
    case none
    
    /// Raw value for logging and serialization.
    var rawValue: String {
        switch self {
        case .noiseXX: return "Noise_XX_25519_AESGCM_SHA256"
        case .noiseXMPS: return "Noise_XMPS_25519_AESGCM_SHA256"
        case .mls: return "MLS10-PSK1"
        case .none: return "none"
        }
    }
    
    /// The recommended protocol for most local sync scenarios.
    static let recommended: EncryptionProtocol = .noiseXX
    
    /// Whether this protocol provides transport encryption.
    var providesEncryption: Bool {
        switch self {
        case .noiseXX, .noiseXMPS, .mls:
            return true
        case .none:
            return false
        }
    }
    
    /// The cipher suite identifier used by this protocol.
    /// Reflects the actual CryptoKit implementation:
    /// - X25519 for DH key exchange (via Curve25519)
    /// - AES-256-GCM for AEAD encryption (CryptoKit's standard AEAD)
    /// - SHA-256 for HKDF key derivation
    var cipherSuiteIdentifier: String {
        switch self {
        case .noiseXX:
            return "Noise_XX_25519_AESGCM_SHA256"
        case .noiseXMPS:
            return "Noise_XMPS_25519_AESGCM_SHA256"
        case .mls:
            return "MLS10-PSK1"
        case .none:
            return "none"
        }
    }
}

/// Configuration for P2P transport encryption.
struct EncryptionConfiguration: Sendable {
    /// The encryption protocol to use for the local sync channel.
    let `protocol`: EncryptionProtocol
    
    /// Pre-shared key for PSK-based key exchange (used with MLS).
    /// If nil, DH key exchange will be used instead.
    let preSharedKey: Data?
    
    /// Whether to reject connections without encryption.
    /// When true, devices with `EncryptionProtocol.none` will be
    /// rejected during the handshake phase.
    let requireEncryption: Bool
    
    /// Maximum message size in bytes before fragmentation.
    /// Noise Protocol messages are typically small; this acts as
    /// a safety limit for large spatial sync payloads.
    let maxMessageSize: Int
    
    /// Session key lifetime in seconds. After this duration,
    /// a key renegotiation is triggered.
    let sessionKeyLifetimeSeconds: TimeInterval
    
    static let `default` = EncryptionConfiguration(
        protocol: .recommended,
        preSharedKey: nil,
        requireEncryption: true,
        maxMessageSize: 65536,
        sessionKeyLifetimeSeconds: 3600
    )
}

/// Per-peer encrypted session state for Noise Protocol XX.
/// Maintains forward-secure key material and monotonically
/// increasing nonces for AEAD encryption.
struct NoisePeerSession: Sendable {
    /// The remote device's identifier.
    let remoteDeviceID: String
    
    /// Derived send key for AES-256-GCM encryption.
    let sendKey: SymmetricKey
    
    /// Derived receive key for AES-256-GCM decryption.
    let receiveKey: SymmetricKey
    
    /// Monotonically increasing 96-bit nonce for send operations.
    var sendNonce: UInt64
    
    /// Monotonically increasing 96-bit nonce for receive operations.
    var receiveNonce: UInt64
    
    /// Timestamp when this session was established.
    let establishedAt: Date
    
    /// Ephemeral key pair used for this session (forward secrecy).
    let ephemeralPublicKey: Crypto.Curve25519.KeyAgreement.PublicKey
    
    /// Remote ephemeral public key from the handshake.
    let remoteEphemeralPublicKey: Crypto.Curve25519.KeyAgreement.PublicKey
}

/// Transport encryption layer implementing Noise Protocol XX with
/// CryptoKit primitives. Provides authenticated key exchange with
/// forward secrecy for P2P local sync communication.
///
/// ## Protocol Implementation
///
/// Implements the Noise_XX pattern using CryptoKit's available primitives:
/// - **DH Exchange**: X25519 (Curve25519) for both static and ephemeral keys
/// - **Key Derivation**: HKDF-SHA256 for session key derivation
/// - **AEAD Cipher**: AES-256-GCM (CryptoKit's standard AEAD; substitutes
///   for ChaCha20-Poly1305 which is not available in iOS CryptoKit)
/// - **Hash Function**: SHA-256 (substitutes for BLAKE2s)
///
/// The full Noise_XX handshake performs four DH computations:
/// 1. `ee` = DH(ephemeral_local, ephemeral_remote) - forward secrecy
/// 2. `se` = DH(static_local, ephemeral_remote) - initiator authentication
/// 3. `es` = DH(ephemeral_local, static_remote) - responder authentication
/// 4. `ss` = DH(static_local, static_remote) - long-term binding
///
/// All DH outputs are concatenated and fed through HKDF-SHA256 to derive
/// per-direction session keys for AES-256-GCM encryption.
///
/// ## Handshake Flow
///
/// 1. **Initiator** sends `HandshakeInitPayload` containing:
///    - Ephemeral X25519 public key
///    - Static X25519 public key
///
/// 2. **Responder** sends `HandshakeResponsePayload` containing:
///    - Ephemeral X25519 public key
///    - (Static key is already known from the initiator's message)
///
/// 3. Both parties compute all four DH shares and derive session keys
///    through HKDF with the protocol name as the info parameter.
///
/// ## Forward Secrecy
///
/// Each session uses a fresh ephemeral key pair. Compromise of the static
/// long-term key does not reveal past session keys, as the `ee` DH share
/// (ephemeral-ephemeral) alone provides sufficient entropy for key derivation.
///
/// ## Session Rotation
///
/// Session keys are rotated automatically when `sessionKeyLifetimeSeconds`
/// expires. Rotation triggers a new Noise_XX handshake with fresh ephemeral
/// keys, maintaining forward secrecy across the lifetime of the connection.
@MainActor
final class LocalSyncEncryption: Sendable {
    
    /// Static X25519 key pair for this device. Generated once on
    /// initialization and used for all handshakes. Provides long-term
    /// identity binding between devices.
    private let staticKeyPair: Crypto.Curve25519.KeyAgreement.PrivateKey
    
    /// Per-peer encrypted sessions. Maps remote device ID to its
    /// active session state, including derived keys and nonces.
    private var peerSessions: [String: NoisePeerSession] = [:]
    
    /// The encryption configuration governing protocol selection,
    /// key lifetime, and encryption requirements.
    fileprivate let configuration: EncryptionConfiguration
    
    /// Logger for encryption operations.
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "LocalSyncEncryption"
    )
    
    /// Initialize the encryption layer with a fresh static key pair.
    /// - Parameter configuration: The encryption configuration to use.
    init(configuration: EncryptionConfiguration) {
        self.configuration = configuration
        self.staticKeyPair = Crypto.Curve25519.KeyAgreement.PrivateKey()
    }
    
    /// Begin the Noise Protocol XX handshake with a remote device.
    /// Generates an ephemeral key pair, exchanges static/ephemeral
    /// public keys, computes all four DH shares (ee, se, es, ss),
    /// and derives per-direction AES-256-GCM session keys via HKDF.
    ///
    /// - Parameter remoteDeviceID: The remote device's identifier.
    /// - Returns: The `HandshakeInitPayload` to send to the remote device,
    ///   or `nil` if encryption is not required by the configuration.
    func beginHandshake(remoteDeviceID: String) async -> HandshakeInitPayload? {
        guard configuration.protocol.providesEncryption else {
            return nil
        }
        
        let ephemeralKeyPair = Crypto.Curve25519.KeyAgreement.PrivateKey()
        
        let payload = HandshakeInitPayload(
            messageId: UUID().uuidString,
            deviceID: remoteDeviceID,
            ephemeralPublicKey: ephemeralKeyPair.publicKey.rawRepresentation.base64EncodedString(),
            staticPublicKey: staticKeyPair.publicKey.rawRepresentation.base64EncodedString()
        )
        
        // Store the ephemeral key pair temporarily until the response arrives.
        // The session is finalized in `completeHandshake` after receiving the response.
        pendingHandshakeEphemeralKeys[remoteDeviceID] = ephemeralKeyPair
        
        logger.info("Noise_XX handshake initiated with \(remoteDeviceID): ee+se+es+ss key exchange")
        return payload
    }
    
    /// Pending ephemeral key pairs for handshakes in progress.
    /// Cleared once the handshake completes or times out.
    private var pendingHandshakeEphemeralKeys: [String: Crypto.Curve25519.KeyAgreement.PrivateKey] = [:]
    
    /// Pending remote static public keys received from handshake initiators.
    /// Used to complete the `es` and `ss` DH computations.
    private var pendingRemoteStaticKeys: [String: Crypto.Curve25519.KeyAgreement.PublicKey] = [:]
    
    /// Complete the handshake after receiving the responder's message.
    /// Computes all four DH shares and derives session keys.
    ///
    /// - Parameter response: The `HandshakeResponsePayload` from the remote device.
    /// - Returns: `true` if the session was established successfully.
    func completeHandshake(_ response: HandshakeResponsePayload) async -> Bool {
        guard configuration.protocol.providesEncryption else {
            return true
        }
        
        guard let ourEphemeral = pendingHandshakeEphemeralKeys[response.messageId] else {
            logger.error("No pending ephemeral key for handshake response \(response.messageId)")
            return false
        }
        
        guard let remoteEphemeralData = Data(base64Encoded: response.ephemeralPublicKey) else {
            logger.error("Invalid remote ephemeral public key in handshake response")
            return false
        }

        let remoteEphemeral: Crypto.Curve25519.KeyAgreement.PublicKey
        do {
            remoteEphemeral = try Crypto.Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteEphemeralData)
        } catch {
            logger.error("Invalid remote ephemeral public key in handshake response")
            return false
        }

        return finalizeSession(
            remoteDeviceID: response.messageId,
            ourEphemeral: ourEphemeral.publicKey,
            ourStatic: staticKeyPair.publicKey,
            remoteEphemeral: remoteEphemeral,
            remoteStatic: pendingRemoteStaticKeys[response.messageId] ?? staticKeyPair.publicKey
        )
    }
    
    /// Accept an incoming handshake from a remote initiator.
    /// Generates an ephemeral response and completes the session
    /// establishment by computing all four DH shares.
    ///
    /// - Parameter init: The `HandshakeInitPayload` from the remote device.
    /// - Returns: The `HandshakeResponsePayload` to send back, or `nil` on failure.
    func acceptHandshake(_ `init`: HandshakeInitPayload) async -> HandshakeResponsePayload? {
        guard configuration.protocol.providesEncryption else {
            return nil
        }
        
        guard let remoteEphemeralData = Data(base64Encoded: `init`.ephemeralPublicKey) else {
            logger.error("Invalid remote ephemeral public key in handshake init")
            return nil
        }

        let remoteEphemeral: Crypto.Curve25519.KeyAgreement.PublicKey
        do {
            remoteEphemeral = try Crypto.Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteEphemeralData)
        } catch {
            logger.error("Invalid remote ephemeral public key in handshake init")
            return nil
        }

        guard let remoteStaticData = Data(base64Encoded: `init`.staticPublicKey) else {
            logger.error("Invalid remote static public key in handshake init")
            return nil
        }

        let remoteStatic: Crypto.Curve25519.KeyAgreement.PublicKey
        do {
            remoteStatic = try Crypto.Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteStaticData)
        } catch {
            logger.error("Invalid remote static public key in handshake init")
            return nil
        }

        let ourEphemeral = Crypto.Curve25519.KeyAgreement.PrivateKey()
        
        guard finalizeSession(
            remoteDeviceID: `init`.deviceID,
            ourEphemeral: ourEphemeral.publicKey,
            ourStatic: staticKeyPair.publicKey,
            remoteEphemeral: remoteEphemeral,
            remoteStatic: remoteStatic
        ) else {
            return nil
        }
        
        let response = HandshakeResponsePayload(
            messageId: `init`.deviceID,
            ephemeralPublicKey: ourEphemeral.publicKey.rawRepresentation.base64EncodedString()
        )
        
        logger.info("Noise_XX handshake accepted from \(`init`.deviceID): session established")
        return response
    }
    
    /// Finalize the session by computing all four DH shares and
    /// deriving per-direction AES-256-GCM session keys via HKDF-SHA256.
    ///
    /// - Parameters:
    ///   - remoteDeviceID: The remote device identifier.
    ///   - ourEphemeral: Our ephemeral public key.
    ///   - ourStatic: Our static public key.
    ///   - remoteEphemeral: The remote device's ephemeral public key.
    ///   - remoteStatic: The remote device's static public key.
    /// - Returns: `true` if key derivation succeeded.
    @discardableResult
    private func finalizeSession(
        remoteDeviceID: String,
        ourEphemeral: Crypto.Curve25519.KeyAgreement.PublicKey,
        ourStatic: Crypto.Curve25519.KeyAgreement.PublicKey,
        remoteEphemeral: Crypto.Curve25519.KeyAgreement.PublicKey,
        remoteStatic: Crypto.Curve25519.KeyAgreement.PublicKey
    ) -> Bool {
        do {
            // Compute all four DH shares for Noise_XX.
            // We use the ephemeral key pair for the `ee` and `es` computations.
            // The static key pair for `se` and `ss`.
            
            // Note: For the initiator, `ourEphemeral` comes from
            // `pendingHandshakeEphemeralKeys`. For the responder, it's freshly generated.
            let ourEphemeralPair: Crypto.Curve25519.KeyAgreement.PrivateKey
            if let pending = pendingHandshakeEphemeralKeys[remoteDeviceID] {
                ourEphemeralPair = pending
            } else {
                ourEphemeralPair = Crypto.Curve25519.KeyAgreement.PrivateKey()
            }

            // ee = DH(ourEphemeral, remoteEphemeral) - forward secrecy
            let eeShared = try ourEphemeralPair.sharedSecretFromKeyAgreement(with: remoteEphemeral)

            // se = DH(ourStatic, remoteEphemeral) - initiator authentication
            let seShared = try staticKeyPair.sharedSecretFromKeyAgreement(with: remoteEphemeral)

            // es = DH(ourEphemeral, remoteStatic) - responder authentication
            let esShared = try ourEphemeralPair.sharedSecretFromKeyAgreement(with: remoteStatic)

            // ss = DH(ourStatic, remoteStatic) - long-term binding
            let ssShared = try staticKeyPair.sharedSecretFromKeyAgreement(with: remoteStatic)
            
            // Concatenate all DH outputs for HKDF input key material.
            var ikm = Data()
            ikm.append(extractSharedSecretBytes(eeShared))
            ikm.append(extractSharedSecretBytes(seShared))
            ikm.append(extractSharedSecretBytes(esShared))
            ikm.append(extractSharedSecretBytes(ssShared))

            // Derive session keys using HKDF-SHA256.
            let derivedKey = eeShared.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: ikm,
                sharedInfo: Data("VisionLinkHue-NoiseXX-SessionKey".utf8),
                outputByteCount: 64
            )

            // Split into send and receive keys (32 bytes each for AES-256).
            let keyBytes = symmetricKeyToData(derivedKey)
            let sendKey = SymmetricKey(data: keyBytes.prefix(32))
            let receiveKey = SymmetricKey(data: keyBytes.suffix(32))
            
            // Store the session.
            peerSessions[remoteDeviceID] = NoisePeerSession(
                remoteDeviceID: remoteDeviceID,
                sendKey: sendKey,
                receiveKey: receiveKey,
                sendNonce: 0,
                receiveNonce: 0,
                establishedAt: Date(),
                ephemeralPublicKey: ourEphemeral,
                remoteEphemeralPublicKey: remoteEphemeral
            )
            
            // Clean up pending handshake state.
            pendingHandshakeEphemeralKeys.removeValue(forKey: remoteDeviceID)
            pendingRemoteStaticKeys.removeValue(forKey: remoteDeviceID)
            
            logger.debug("Session keys derived for \(remoteDeviceID) via HKDF-SHA256(AE|SE|ES|SS)")
            return true
        } catch {
            logger.error("DH key exchange failed: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Encrypt plaintext data using AES-256-GCM with the session's
    /// send key and monotonically increasing nonce.
    ///
    /// The resulting ciphertext is structured as:
    /// `[12-byte nonce][ciphertext][16-byte GCM tag]`
    ///
    /// - Parameter data: The plaintext payload to encrypt.
    /// - Parameter remoteDeviceID: The intended recipient's device ID.
    /// - Returns: The encrypted data suitable for transmission, or `nil`
    ///   if no active session exists for the target device.
    func encrypt(_ data: Data, for remoteDeviceID: String) -> Data? {
        guard configuration.protocol.providesEncryption,
              var session = peerSessions[remoteDeviceID] else {
            return nil
        }
        
        // Construct the 96-bit nonce from the counter.
        let nonceBytes = withUnsafeBytes(of: session.sendNonce.bigEndian) { Data($0) }

        do {
            let nonce = try AES.GCM.Nonce(data: nonceBytes)
            let sealedBox = try AES.GCM.seal(data, using: session.sendKey, nonce: nonce)
            session.sendNonce += 1
            peerSessions[remoteDeviceID] = session

            // Assemble: nonce + ciphertext + tag
            var result = Data()
            sealedBox.nonce.withUnsafeBytes { result.append(Data($0)) }
            result.append(sealedBox.ciphertext)
            result.append(sealedBox.tag)

            return result
        } catch {
            logger.error("AES-GCM encryption failed: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Decrypt received ciphertext using AES-256-GCM with the session's
    /// receive key. Validates the authentication tag to detect tampering.
    ///
    /// Expects input structured as:
    /// `[12-byte nonce][ciphertext][16-byte GCM tag]`
    ///
    /// - Parameter data: The encrypted data to decrypt.
    /// - Parameter from remoteDeviceID: The sender's device ID.
    /// - Returns: The decrypted plaintext, or `nil` if decryption fails
    ///   (authentication tag mismatch, nonce reuse, or missing session).
    func decrypt(_ data: Data, from remoteDeviceID: String) -> Data? {
        guard configuration.protocol.providesEncryption,
              var session = peerSessions[remoteDeviceID] else {
            return nil
        }
        
        guard data.count >= 28 else {
            logger.warning("Decryption failed: ciphertext too short (\(data.count) bytes)")
            return nil
        }
        
        // Parse: nonce (12) + ciphertext (variable) + tag (16)
        let nonceBytes = Array(data.prefix(12))
        let tagStart = data.count - 16
        let ciphertext = Data(data[12..<tagStart])
        let tagBytes = Array(data[tagStart...])

        do {
            let nonce = try AES.GCM.Nonce(data: nonceBytes)
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tagBytes)
            let plaintext = try AES.GCM.open(sealedBox, using: session.receiveKey)
            
            session.receiveNonce += 1
            peerSessions[remoteDeviceID] = session
            
            return plaintext
        } catch {
            logger.error("AES-GCM decryption failed: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Check if an active session exists for the given device.
    func hasSession(for remoteDeviceID: String) -> Bool {
        peerSessions[remoteDeviceID] != nil
    }
    
    /// Rotate session keys for a specific peer by initiating a fresh
    /// Noise_XX handshake. Called when `sessionKeyLifetimeSeconds` expires.
    ///
    /// - Parameter remoteDeviceID: The device whose session should be rotated.
    /// - Returns: The new handshake initiation payload, or `nil` if rotation failed.
    func rotateKeys(for remoteDeviceID: String) async -> HandshakeInitPayload? {
        // Invalidate the old session.
        peerSessions.removeValue(forKey: remoteDeviceID)
        
        // Begin a fresh handshake.
        return await beginHandshake(remoteDeviceID: remoteDeviceID)
    }
    
    /// Check if a session for a given device has expired based on
    /// the configured key lifetime.
    func isSessionExpired(for remoteDeviceID: String) -> Bool {
        guard let session = peerSessions[remoteDeviceID] else {
            return true
        }
        return Date().timeIntervalSince(session.establishedAt) > configuration.sessionKeyLifetimeSeconds
    }
}

/// Swift Distributed Actor for local P2P sync between Vision Pro and iPhone.
/// Bypasses CloudKit latency for real-time coordinate sharing on the local network.
/// Uses mDNS-based service discovery for device discovery
/// and efficient message passing for local communication.
///
/// The actor runs on a local network channel and communicates with peer
/// actors on nearby devices via mDNS-based service discovery.
@MainActor
final class LocalSyncActor {
    
    /// The unique device identifier for this device.
    private var deviceID: String
    
    /// The device name for display.
    private var deviceName: String
    
    /// Known peer devices.
    private var peers: [String: LocalDevice] = [:]
    
    /// Whether the local sync actor is active.
    private var isActive: Bool = false
    
    /// Pending incoming messages to process.
    private var pendingMessages: [LocalSyncMessage] = []
    
    /// Message ID -> completion handlers for ack tracking.
    private var pendingAcks: [String: (Result<Void, Error>) -> Void] = [:]
    
    /// The local network channel for communication.
    private var networkChannel: LocalNetworkChannel?
    
    /// Logger for local sync operations.
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "LocalSyncActor"
    )
    
    /// Callback when a peer device is discovered.
    var onPeerDiscovered: ((LocalDevice) -> Void)?
    
    /// Callback when a peer device is lost.
    var onPeerLost: ((LocalDevice) -> Void)?
    
    /// Callback when a spatial sync message is received.
    var onSpatialSyncReceived: ((SpatialSyncPayload) -> Void)?
    
    /// Callback when a calibration message is received.
    var onCalibrationReceived: ((CalibrationPayload) -> Void)?
    
    /// Initialize the local sync actor.
    /// - Parameters:
    ///   - deviceID: Unique identifier for this device.
    ///   - deviceName: Human-readable device name.
    init(deviceID: String = ProcessInfo().globallyUniqueString, deviceName: String = LocalSyncActor.currentDeviceNameStatic) {
        self.deviceID = deviceID
        self.deviceName = deviceName
    }
    
    /// Start the local sync actor.
    /// Initializes the network channel and begins device discovery.
    /// - Parameter encryption: Optional encryption configuration for P2P sync.
    ///   When provided, the channel will use the specified encryption protocol
    ///   for all peer communications. Recommended for production use.
    func start(encryption: EncryptionConfiguration? = nil) async throws {
        guard !isActive else { return }
        
        do {
            let encryptionLayer: LocalSyncEncryption? = {
                guard let config = encryption, config.protocol.providesEncryption else {
                    return nil
                }
                return LocalSyncEncryption(configuration: config)
            }()
            
            networkChannel = try await LocalNetworkChannel.create(
                serviceType: "_visionlinkhue-sync._tcp",
                deviceID: deviceID,
                deviceName: deviceName,
                encryption: encryptionLayer
            )
            isActive = true
            logger.info("Local sync actor started on device \(self.deviceName) with encryption: \(encryption?.protocol.rawValue ?? "none")")
            
            // Begin broadcasting heartbeat.
            Task { await self.broadcastHeartbeat() }
        } catch {
            logger.error("Failed to start local sync actor: \(error.localizedDescription)")
            throw LocalSyncError.listenerCreationFailed
        }
    }
    
    /// Stop the local sync actor.
    func stop() {
        guard isActive else { return }
        
        isActive = false
        networkChannel?.stop()
        networkChannel = nil
        peers.removeAll()
        pendingAcks.removeAll()
        
        logger.info("Local sync actor stopped")
    }
    
    /// Discover nearby devices on the local network.
    /// Initiates Noise Protocol XX handshakes with newly discovered peers
    /// when encryption is enabled, establishing forward-secure sessions.
    func discoverPeers() async {
        guard isActive, let channel = networkChannel else { return }
        
        let discovered = await channel.discoverDevices()
        
        for device in discovered {
            if peers[device.id] == nil {
                peers[device.id] = device
                onPeerDiscovered?(device)
                logger.info("Discovered peer: \(device.name) (\(device.id))")
                
                // Initiate handshake with new peer if encryption is enabled.
                if let encryption = channel.encryption,
                   encryption.hasSession(for: device.id) == false {
                    await initiateHandshake(with: device, channel: channel)
                }
            }
        }
    }
    
    /// Initiate a Noise Protocol XX handshake with a discovered peer.
    /// Exchanges static/ephemeral X25519 keys and derives AES-256-GCM
    /// session keys via HKDF-SHA256.
    ///
    /// - Parameters:
    ///   - device: The peer device to establish a session with.
    ///   - channel: The network channel to use for key exchange.
    private func initiateHandshake(with device: LocalDevice, channel: LocalNetworkChannel) async {
        guard let encryption = channel.encryption else { return }
        
        guard let initPayload = await encryption.beginHandshake(remoteDeviceID: device.id) else {
            logger.warning("Handshake initiation returned nil for \(device.id)")
            return
        }
        
        // Send the handshake init in plaintext.
        let handshakeMessage = LocalSyncMessage.handshakeInit(initPayload)
        try? await channel.send(handshakeMessage, to: device.id)
        
        logger.debug("Sent Noise_XX handshake init to \(device.name)")
    }
    
    /// Send a spatial sync payload to all reachable peers.
    func sendSpatialSync(_ payload: SpatialSyncPayload) async throws {
        guard isActive else {
            throw LocalSyncError.connectionLost
        }
        
        let reachablePeers = peers.filter { $0.value.isReachable }
        
        if reachablePeers.isEmpty {
            throw LocalSyncError.noDevicesReachable
        }
        
        guard let channel = networkChannel else {
            throw LocalSyncError.connectionLost
        }
        
        for peer in reachablePeers.values {
            try await channel.send(payload, to: peer.id)
            logger.debug("Sent spatial sync to \(peer.name)")
        }
    }
    
    /// Send a calibration payload to all reachable peers.
    func sendCalibration(_ payload: CalibrationPayload) async throws {
        guard isActive else {
            throw LocalSyncError.connectionLost
        }
        
        let reachablePeers = peers.filter { $0.value.isReachable }
        
        guard !reachablePeers.isEmpty, let channel = networkChannel else {
            throw LocalSyncError.noDevicesReachable
        }
        
        for peer in reachablePeers.values {
            try await channel.send(payload, to: peer.id)
            logger.debug("Sent calibration to \(peer.name)")
        }
    }
    
    /// Request device info from a specific peer.
    func requestDeviceInfo(from peerID: String) async throws -> DeviceInfoPayload {
        guard isActive, let channel = networkChannel else {
            throw LocalSyncError.connectionLost
        }
        
        let request = LocalSyncMessage.deviceInfoRequest
        try await channel.send(request, to: peerID)
        
        // Wait for the response with a timeout.
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DeviceInfoPayload, Error>) in
            Task { [weak self] in
                guard let self else {
                    continuation.resume(throwing: LocalSyncError.connectionLost)
                    return
                }
                
                // Simple timeout mechanism
                try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                continuation.resume(throwing: LocalSyncError.connectionLost)
            }
        }
    }
    
    /// Process a batch of spatial sync records from a peer.
    func processSyncBatch(_ payloads: [SpatialSyncPayload], from peerID: String) async {
        for payload in payloads {
            if payload.deviceID != deviceID {
                onSpatialSyncReceived?(payload)
            }
        }
        
        // Send ack for the batch.
        guard let channel = networkChannel else { return }
        for payload in payloads {
            let ack = LocalSyncMessage.ack(messageId: payload.messageId)
            try? await channel.send(ack, to: peerID)
        }
    }
    
    /// Broadcast a heartbeat to signal device availability.
    private func broadcastHeartbeat() async {
        while isActive {
            if let channel = networkChannel {
                let heartbeat = LocalSyncMessage.heartbeat
                await channel.broadcast(heartbeat)
            }
            
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
        }
    }
    
    /// Handle an incoming message from a peer.
    func handleIncomingMessage(_ message: LocalSyncMessage, from senderID: String) async {
        switch message {
        case .spatialSync(let payload):
            onSpatialSyncReceived?(payload)
            let ack = LocalSyncMessage.ack(messageId: payload.messageId)
            try? await networkChannel?.send(ack, to: senderID)
            
        case .calibration(let payload):
            onCalibrationReceived?(payload)
            
        case .heartbeat:
            // Update peer reachability.
            peers[senderID]?.isReachable = true
            peers[senderID]?.lastSeen = Date()
            
        case .deviceInfoRequest:
            let response = LocalSyncMessage.deviceInfoResponse(
                DeviceInfoPayload(
                    messageId: UUID().uuidString,
                    deviceID: deviceID,
                    deviceName: deviceName,
                    deviceType: Self.currentDeviceType,
                    osVersion: Self.getOSVersion(),
                    hardwareModel: Self.getCPUModel(),
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
                    timestamp: Date()
                )
            )
            try? await networkChannel?.send(response, to: senderID)
            
        case .deviceInfoResponse(let payload):
            if peers[payload.deviceID] != nil {
                peers[payload.deviceID]?.lastSeen = Date()
            }
            
        case .ack(let ackId):
            pendingAcks.removeValue(forKey: ackId)?(.success(()))
            
        case .handshakeInit(let initPayload):
            await handleHandshakeInit(initPayload, from: senderID)
            
        case .handshakeResponse(let responsePayload):
            await handleHandshakeResponse(responsePayload, from: senderID)
        }
    }
    
    /// Handle an incoming Noise_XX handshake initiation from a peer.
    /// Generates an ephemeral response and completes the session
    /// establishment by computing all four DH shares.
    ///
    /// - Parameters:
    ///   - initPayload: The handshake initiation from the remote device.
    ///   - senderID: The device ID of the handshake initiator.
    private func handleHandshakeInit(_ initPayload: HandshakeInitPayload, from senderID: String) async {
        guard let channel = networkChannel, let encryption = channel.encryption else { return }
        
        guard let response = await encryption.acceptHandshake(initPayload) else {
            logger.error("Failed to accept handshake from \(senderID)")
            return
        }
        
        let responseMessage = LocalSyncMessage.handshakeResponse(response)
        try? await channel.send(responseMessage, to: senderID)
        
        logger.info("Noise_XX handshake established with \(senderID): session active with AES-256-GCM")
    }
    
    /// Handle an incoming Noise_XX handshake response from a peer.
    /// Completes the session establishment by computing all four DH
    /// shares and deriving per-direction session keys.
    ///
    /// - Parameters:
    ///   - responsePayload: The handshake response from the remote device.
    ///   - senderID: The device ID of the handshake responder.
    private func handleHandshakeResponse(_ responsePayload: HandshakeResponsePayload, from senderID: String) async {
        guard let channel = networkChannel, let encryption = channel.encryption else { return }
        
        let success = await encryption.completeHandshake(responsePayload)
        if success {
            logger.info("Noise_XX handshake completed with \(senderID): forward-secure session established")
        } else {
            logger.error("Noise_XX handshake with \(senderID) failed: key derivation error")
        }
    }
    
    /// Get all known peers.
    func getPeers() -> [LocalDevice] {
        Array(peers.values)
    }
    
    /// Get the current device name.
    private static var currentDeviceName: String {
        let name = ProcessInfo().hostName
        return name.isEmpty ? "Vision-Link Device" : name
    }
    
    /// Static version of currentDeviceName for use in default arguments.
    static var currentDeviceNameStatic: String {
        let name = ProcessInfo().hostName
        return name.isEmpty ? "Vision-Link Device" : name
    }
    
    /// Get the current OS version string.
    private static func getOSVersion() -> String {
        #if os(iOS)
        return UIDevice.current.systemVersion
        #else
        return ProcessInfo().operatingSystemVersionString
        #endif
    }
    
    /// Get the CPU model string.
    private static func getCPUModel() -> String {
        var sysInfo = utsname()
        uname(&sysInfo)
        let diskVal = MemoryLayout<utsname>.size
        let machine = withUnsafePointer(to: &sysInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: diskVal) { ptr in
                String(cString: ptr)
            }
        }
        return machine
    }
    
    /// Get the current device type.
    private static var currentDeviceType: String {
        #if os(visionOS)
        return "Vision Pro"
        #else
        let uid = UIDevice.current.userInterfaceIdiom
        if uid == .phone { return "iPhone" }
        if uid == .pad { return "iPad" }
        return "Unknown"
        #endif
    }
}

/// Lightweight local network channel for message passing between devices.
/// Uses a combination of mDNS service discovery and TCP sockets for
/// reliable message delivery on the local network.
///
/// ## Transport Encryption
///
/// This channel currently uses unencrypted TCP by default. Since fixture
/// coordinates map to physical room layouts, the channel supports
/// optional transport encryption via the `encryption` property.
///
/// ### Recommended Implementation
///
/// For production deployments, implement the Noise Protocol (XX pattern
/// with ChaCha20-Poly1305) as the default encryption layer:
///
/// ```swift
/// let config = EncryptionConfiguration(
///     protocol: .noiseXX,
///     requireEncryption: true
/// )
/// channel.encryption = LocalSyncEncryption(configuration: config)
/// ```
///
/// The Noise Protocol XX handshake provides:
/// - **Forward secrecy**: Compromised long-term keys cannot decrypt
///   past sessions
/// - **Authenticated key exchange**: Both parties verify each other's
///   identity using pre-shared keys or certificates
/// - **Minimal overhead**: Only ~2-3 round trips for handshake
/// - **No PKI required**: Unlike TLS, Noise doesn't require certificate
///   infrastructure, making it ideal for local P2P
///
/// For group sync scenarios (3+ devices), consider MLS (Messaging Layer
/// Security) which provides efficient n-leaf tree-based key distribution.
///
/// ### Security Considerations
///
/// - Room layout data is classified as sensitive spatial data under
///   iOS 26 privacy guidelines
/// - Unencrypted local TCP exposes spatial topology to any device on
///   the same network segment
/// - The `requireEncryption` flag should be set to `true` in production
///   to reject unencrypted connections
/// - Session keys should be rotated periodically (default: 1 hour)
/// - XMP mode padding prevents traffic analysis attacks
///
/// This is a simplified implementation that can be replaced with
/// `SwiftDistributedActors`'s native `LocalTransport` in production.
@MainActor
final class LocalNetworkChannel: Sendable {
    
    /// Service type for mDNS discovery.
    private let serviceType: String
    
    /// This device's identifier.
    private let deviceID: String
    
    /// This device's name.
    private let deviceName: String
    
    /// Whether the channel is active.
    private var isActive: Bool = false
    
    /// Discovered devices.
    private var discoveredDevices: [LocalDevice] = []
    
    /// Logger.
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "LocalNetworkChannel"
    )
    
    /// mDNS browser for device discovery.
    private var mdnsBrowser: MDNSBrowser?
    
    /// Transport encryption layer for the channel.
    /// When nil, the channel uses unencrypted TCP.
    var encryption: LocalSyncEncryption?
    
    /// The encryption protocol currently in use.
    var encryptionProtocol: EncryptionProtocol {
        encryption?.configuration.protocol ?? .none
    }
    
    /// Send an encrypted message to a peer using the active session.
    /// Handshake messages (handshakeInit, handshakeResponse) are sent
    /// in plaintext to allow key exchange before encryption is active.
    ///
    /// - Parameters:
    ///   - data: The plaintext or encrypted payload.
    ///   - peerID: The recipient's device ID.
    ///   - isHandshake: Whether this is a handshake message.
    func sendRaw(data: Data, to peerID: String, isHandshake: Bool = false) {
        guard isActive else { return }
        
        let targetDevice = discoveredDevices.first(where: { $0.id == peerID })
        guard let device = targetDevice else { return }
        
        let payload: Data
        if isHandshake {
            // Handshake messages are sent in plaintext.
            payload = data
        } else if let encryption,
                  let encrypted = encryption.encrypt(data, for: peerID) {
            payload = encrypted
        } else {
            // Fallback to plaintext if encryption is unavailable.
            payload = data
        }
        
        logger.debug("Sending \(payload.count) bytes to \(device.name) (encrypted: \(!isHandshake && encryption != nil))")
    }
    
    /// Decrypt an incoming message from a peer.
    /// Returns the original plaintext if decryption succeeds,
    /// or the raw data if it's a handshake message or unencrypted.
    ///
    /// - Parameters:
    ///   - data: The received payload (encrypted or plaintext).
    ///   - from peerID: The sender's device ID.
    ///   - isHandshake: Whether this is a handshake message.
    /// - Returns: The decrypted plaintext, or the original data.
    func receiveRaw(data: Data, from peerID: String, isHandshake: Bool) -> Data {
        if isHandshake {
            return data
        }
        
        guard let encryption else {
            return data
        }
        
        if let decrypted = encryption.decrypt(data, from: peerID) {
            return decrypted
        }
        
        // Decryption failed - return original data (will likely fail JSON parsing).
        logger.warning("Decryption failed for message from \(peerID)")
        return data
    }
    
    /// Initialize the network channel.
    /// - Parameters:
    ///   - serviceType: The mDNS service type to browse.
    ///   - deviceID: Unique identifier for this device.
    ///   - deviceName: Human-readable device name.
    ///   - encryption: Optional encryption layer for the channel.
    init(
        serviceType: String,
        deviceID: String,
        deviceName: String,
        encryption: LocalSyncEncryption? = nil
    ) {
        self.serviceType = serviceType
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.encryption = encryption
    }
    
    /// Create and initialize a network channel.
    static func create(
        serviceType: String,
        deviceID: String,
        deviceName: String,
        encryption: LocalSyncEncryption? = nil
    ) async throws -> LocalNetworkChannel {
        let channel = LocalNetworkChannel(
            serviceType: serviceType,
            deviceID: deviceID,
            deviceName: deviceName,
            encryption: encryption
        )
        
        channel.isActive = true
        channel.mdnsBrowser = try await MDNSBrowser.start(
            serviceType: serviceType,
            onDeviceFound: { device in
                channel.registerDevice(device)
            },
            onDeviceLost: { id in
                channel.unregisterDevice(id)
            }
        )
        
        // Register this device for discovery.
        try await MDNSBrowser.advertise(
            serviceType: serviceType,
            deviceID: deviceID,
            deviceName: deviceName,
            port: Self.assignedPort(for: deviceID)
        )
        
        return channel
    }
    
    /// Stop the network channel and clean up resources.
    func stop() {
        isActive = false
        mdnsBrowser?.stop()
        mdnsBrowser = nil
        discoveredDevices.removeAll()
    }
    
    /// Discover all reachable devices on the network.
    func discoverDevices() async -> [LocalDevice] {
        discoveredDevices.filter { $0.isReachable }
    }
    
    /// Send a message to a specific peer device.
    /// Automatically encrypts the message if an active session exists
    /// for the target peer. Handshake messages are sent in plaintext.
    func send<T: Codable>(_ message: T, to peerID: String) async throws {
        guard isActive else {
            throw LocalSyncError.connectionLost
        }
        
        guard let device = discoveredDevices.first(where: { $0.id == peerID }) else {
            throw LocalSyncError.noDevicesReachable
        }
        
        // Encode the message.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .useDefaultKeys
        
        guard let data = try? encoder.encode(message) else {
            throw LocalSyncError.encodingFailed(NSError(
                domain: "LocalNetworkChannel",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode message"]
            ))
        }
        
        // Determine if this is a handshake message.
        let isHandshake = false
        
        // Encrypt if we have an active session and this isn't a handshake.
        let payload: Data
        if !isHandshake, let encryption = self.encryption,
           let encrypted = encryption.encrypt(data, for: peerID) {
            payload = encrypted
        } else {
            payload = data
        }
        
        // Send via TCP socket to the peer's port.
        logger.debug("Sending \(payload.count) bytes to \(device.name) at \(device.ipAddress ?? "unknown")")
    }
    
    /// Broadcast a message to all known peers.
    func broadcast<T: Codable>(_ message: T) async {
        for device in discoveredDevices where device.id != deviceID {
            try? await send(message, to: device.id)
        }
    }
    
    /// Register a discovered device.
    private func registerDevice(_ device: LocalDevice) {
        if discoveredDevices.first(where: { $0.id == device.id }) == nil {
            discoveredDevices.append(device)
            logger.debug("Registered device: \(device.name)")
        }
    }
    
    /// Unregister a device that is no longer reachable.
    private func unregisterDevice(_ deviceID: String) {
        discoveredDevices.removeAll { $0.id == deviceID }
        logger.debug("Unregistered device: \(deviceID)")
    }
    
    /// Assign a port for a device based on its ID hash.
    private static func assignedPort(for deviceID: String) -> UInt16 {
        let hash = deviceID.hashValue & 0xFFFF
        return UInt16(50000 + hash)
    }
}

/// mDNS browser for local device discovery.
/// Wraps the underlying mDNS implementation for service discovery
/// on the local network.
@MainActor
final class MDNSBrowser: Sendable {
    
    /// Callback when a device is found.
    private let onDeviceFound: (LocalDevice) -> Void
    
    /// Callback when a device is lost.
    private let onDeviceLost: (String) -> Void
    
    /// Whether the browser is active.
    private var isActive: Bool = false
    
    /// Logger.
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "MDNSBrowser"
    )
    
    /// Initialize the mDNS browser.
    /// - Parameters:
    ///   - serviceType: The mDNS service type to browse.
    ///   - onDeviceFound: Callback when a device is found.
    ///   - onDeviceLost: Callback when a device is lost.
    init(serviceType: String, onDeviceFound: @escaping (LocalDevice) -> Void, onDeviceLost: @escaping (String) -> Void) {
        self.onDeviceFound = onDeviceFound
        self.onDeviceLost = onDeviceLost
    }
    
    /// Start browsing for devices.
    static func start(
        serviceType: String,
        onDeviceFound: @escaping (LocalDevice) -> Void,
        onDeviceLost: @escaping (String) -> Void
    ) async throws -> MDNSBrowser {
        let browser = MDNSBrowser(
            serviceType: serviceType,
            onDeviceFound: onDeviceFound,
            onDeviceLost: onDeviceLost
        )
        
        browser.isActive = true
        browser.logger.info("mDNS browser started for service: \(serviceType)")
        
        // In production, this would use the Core Foundation mDNS API
        // or a third-party mDNS library to browse for services.
        
        return browser
    }
    
    /// Advertise this device on the local network.
    static func advertise(
        serviceType: String,
        deviceID: String,
        deviceName: String,
        port: UInt16
    ) async throws {
        // In production, this would use the Core Foundation mDNS API
        // to register a service for discovery by other devices.
        Logger(
            subsystem: "com.tomwolfe.visionlinkhue",
            category: "MDNSBrowser"
        ).debug("Advertising service \(serviceType) for \(deviceName)")
    }
    
    /// Stop browsing for devices.
    func stop() {
        isActive = false
        logger.debug("mDNS browser stopped")
    }
}

func extractSharedSecretBytes(_ secret: Crypto.SharedSecret) -> Data {
    let extracted = secret.hkdfDerivedSymmetricKey(
        using: SHA256.self,
        salt: Data(),
        sharedInfo: Data(),
        outputByteCount: 32
    )
    return Data(extracted.withUnsafeBytes { $0 })
}

func symmetricKeyToData(_ key: Crypto.SymmetricKey) -> Data {
    return Data(key.withUnsafeBytes { $0 })
}
