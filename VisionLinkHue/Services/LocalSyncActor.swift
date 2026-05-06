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
        }
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
    func start() async throws {
        guard !isActive else { return }
        
        do {
            networkChannel = try await LocalNetworkChannel.create(
                serviceType: "_visionlinkhue-sync._tcp",
                deviceID: deviceID,
                deviceName: deviceName
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
    
    /// Initialize the network channel.
    /// - Parameters:
    ///   - serviceType: The mDNS service type to browse.
    ///   - deviceID: Unique identifier for this device.
    ///   - deviceName: Human-readable device name.
    init(serviceType: String, deviceID: String, deviceName: String) {
        self.serviceType = serviceType
        self.deviceID = deviceID
        self.deviceName = deviceName
    }
    
    /// Create and initialize a network channel.
    static func create(serviceType: String, deviceID: String, deviceName: String) async throws -> LocalNetworkChannel {
        let channel = LocalNetworkChannel(
            serviceType: serviceType,
            deviceID: deviceID,
            deviceName: deviceName
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
