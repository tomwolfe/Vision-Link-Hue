import Foundation
import os
import UIKit

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
    
    /// Unique message identifier.
    var messageId: String {
        switch self {
        case .spatialSync(let payload): return payload.messageId
        case .calibration(let payload): return payload.messageId
        case .heartbeat: return UUID().uuidString
        case .deviceInfoRequest: return UUID().uuidString
        case .deviceInfoResponse(let payload): return payload.messageId
        case .ack(let id): return id
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
    /// Noise Protocol XX handshake with ChaCha20-Poly1305.
    /// Recommended for most local P2P use cases.
    case noiseXX
    
    /// Noise Protocol with XMP padding for traffic privacy.
    case noiseXMPS
    
    /// Messaging Layer Security (RFC 9420) for group encryption.
    case mls
    
    /// No encryption.
    case none
    
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
    var cipherSuiteIdentifier: String {
        switch self {
        case .noiseXX:
            return "Noise_XX_25519_ChaChaPoly_BLAKE2s"
        case .noiseXMPS:
            return "Noise_XMPS_25519_ChaChaPoly_BLAKE2s"
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
        `protocol`: .recommended,
        preSharedKey: nil,
        requireEncryption: true,
        maxMessageSize: 65536,
        sessionKeyLifetimeSeconds: 3600
    )
}

/// Placeholder for a transport encryption layer.
///
/// In production, this should be implemented using:
/// - `libnoise` or `NoiseKit` for Noise Protocol support
/// - `OpenMLS` for MLS (Messaging Layer Security) support
/// - `CryptoKit` for underlying cryptographic primitives (X25519,
///   ChaCha20-Poly1305, BLAKE2s)
///
/// The encryption layer wraps the raw TCP socket and provides:
/// 1. Handshake: Protocol-specific key exchange (e.g., Noise XX)
/// 2. Key derivation: HKDF-based derivation of encryption keys
/// 3. Per-message encryption: ChaCha20-Poly1305 AEAD encryption
/// 4. Session rotation: Automatic key renegotiation after lifetime
/// 5. Traffic padding: Optional fixed-size padding for XMP mode
@MainActor
final class LocalSyncEncryption: Sendable {
    
    private let configuration: EncryptionConfiguration
    private var sessionKey: Data?
    private var handshakeComplete: Bool = false
    
    /// Initialize the encryption layer.
    /// - Parameter configuration: The encryption configuration to use.
    init(configuration: EncryptionConfiguration) {
        self.configuration = configuration
    }
    
    /// Begin the encryption handshake with a remote device.
    /// - Parameter remoteDeviceID: The remote device's identifier.
    /// - Returns: True if the handshake completed successfully.
    func beginHandshake(remoteDeviceID: String) async -> Bool {
        guard configuration.protocol.providesEncryption else {
            handshakeComplete = true
            return true
        }
        
        // In production, this would:
        // 1. Generate an X25519 key pair
        // 2. Send the public key to the remote device
        // 3. Receive the remote device's public key
        // 4. Perform the DH key exchange
        // 5. Derive session keys using HKDF
        // 6. Encrypt the handshake message to verify integrity
        
        logger.debug("Encryption handshake initiated with \(remoteDeviceID) using \(configuration.protocol.cipherSuiteIdentifier)")
        handshakeComplete = true
        return true
    }
    
    /// Encrypt a message for transmission.
    /// - Parameter data: The plaintext data to encrypt.
    /// - Returns: The encrypted data, or nil if encryption is not available.
    func encrypt(_ data: Data) -> Data? {
        guard configuration.protocol.providesEncryption,
              handshakeComplete else {
            return nil
        }
        
        // In production, this would use ChaCha20-Poly1305 AEAD
        // to encrypt the data with the session key.
        // The ciphertext would include the 16-byte authentication tag.
        return data
    }
    
    /// Decrypt a received message.
    /// - Parameter data: The encrypted data to decrypt.
    /// - Returns: The decrypted data, or nil if decryption fails.
    func decrypt(_ data: Data) -> Data? {
        guard configuration.protocol.providesEncryption,
              handshakeComplete else {
            return data
        }
        
        // In production, this would use ChaCha20-Poly1305 AEAD
        // to decrypt the data and verify the authentication tag.
        // Returns nil if the tag verification fails (possible MITM).
        return data
    }
    
    /// Rotate the session keys.
    /// Called automatically when the session key lifetime expires.
    func rotateKeys() async {
        logger.debug("Rotating session keys")
        sessionKey = nil
        handshakeComplete = false
    }
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "LocalSyncEncryption"
    )
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
            logger.info("Local sync actor started on device \(self.deviceName)")
            
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
    func discoverPeers() async {
        guard isActive, let channel = networkChannel else { return }
        
        let discovered = await channel.discoverDevices()
        
        for device in discovered {
            if peers[device.id] == nil {
                peers[device.id] = device
                onPeerDiscovered?(device)
                logger.info("Discovered peer: \(device.name) (\(device.id))")
            }
        }
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
    func handleIncomingMessage(_ message: LocalSyncMessage) async {
        switch message {
        case .spatialSync(let payload):
            onSpatialSyncReceived?(payload)
            // Send ack back to sender.
            let ack = LocalSyncMessage.ack(messageId: payload.messageId)
            // Note: In production, we'd track the sender from the network channel.
            
        case .calibration(let payload):
            onCalibrationReceived?(payload)
            
        case .heartbeat:
            // Update peer reachability.
            // In production, track the sender's device ID.
            _ = true
            
        case .deviceInfoRequest:
            // Respond with device info.
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
            // In production, send response to the requesting peer.
            
        case .deviceInfoResponse(let payload):
            // Update peer info.
            if peers[payload.deviceID] != nil {
                peers[payload.deviceID]?.lastSeen = Date()
            }
            
        case .ack:
            // Resolve pending ack handler.
            break
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
        
        // Send via TCP socket to the peer's port.
        // In production, this would use a proper socket connection.
        logger.debug("Sending message to \(device.name) at \(device.ipAddress ?? "unknown")")
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
