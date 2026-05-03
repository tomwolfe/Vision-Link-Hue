import Foundation
import Network
import os
import simd
import CommonCrypto
#if canImport(Darwin)
import Darwin
#endif

/// Network client that manages all communication with the Philips Hue Bridge
/// using CLIP v2 API, mTLS with Trust-On-First-Use certificate pinning,
/// and Server-Sent Events (SSE) for real-time state updates.
///
/// Acts as the authenticated transport layer, composing `HueDiscoveryService`
/// for bridge discovery and `HueSpatialService` for spatial awareness operations.
@MainActor
final class HueClient: ObservableObject, HueClientProtocol {
    
    // MARK: - Published State
    
    @Published var bridgeIP: String?
    @Published var bridgePort: Int = 80
    @Published var apiKey: String?
    @Published var bridgeConfig: BridgeConfig?
    
    /// The authenticated username (API key) for bridge communication.
    var username: String? { apiKey }
    
    // MARK: - Private State
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "HueClient"
    )
    
    /// Cached certificate pin hash for the current bridge (TOFU).
    private var pinnedHash: Data?
    
    /// Whether we have already pinned a certificate for this bridge.
    private var isPinned: Bool { pinnedHash != nil }
    
    /// Network connection for REST API calls.
    private var urlSession: URLSession?
    
    /// Dedicated actor for SSE event stream management.
    /// Isolates high-frequency network events from the MainActor.
    private let eventStream = HueEventStreamActor()
    
    /// State stream publisher.
    weak var stateStream: HueStateStream?
    
    // MARK: - Composed Services
    
    /// Service for discovering Hue bridges on the local network.
    let discoveryService: HueDiscoveryService
    
    /// Service for spatial awareness and coordinate transformation.
    var spatialService: HueSpatialService?
    
    // MARK: - Initialization
    
    init(stateStream: HueStateStream) {
        self.stateStream = stateStream
        self.discoveryService = HueDiscoveryService()
        setupURLSession()
        self.spatialService = HueSpatialService(hueClient: self, stateStream: stateStream)
    }
    
    deinit {
        // Discovery service cleanup handled by its own lifecycle
    }
    
    // MARK: - Bridge Discovery
    
    /// Discover Hue bridges on the local network using mDNS.
    /// Delegates to `HueDiscoveryService`.
    func discoverBridges() async -> [BridgeInfo] {
        await discoveryService.discoverBridges(stateStream: stateStream)
    }
    
    // MARK: - Authentication
    
    /// Create a new developer session (API key) on the bridge.
    /// The user must press the link button on the bridge first.
    func createApiKey() async throws -> String {
        guard let ip = bridgeIP else {
            throw HueError.noBridgeConfigured
        }
        
        let url = URL(string: "https://\(ip)/api")!
        let requestBody = CreateApiKeyRequest(devicetype: "Vision-Link-Hue-\(UUID().uuidString.prefix(8))")
        
        let (data, response) = try await authenticatedRequest(url: url, method: "POST", body: requestBody)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw HueError.authenticationFailed
        }
        
        let apiKeyResponse = try JSONDecoder().decode(CreateApiKeyResponse.self, from: data)
        
        guard let username = apiKeyResponse.success?.username else {
            throw HueError.noUsernameReturned
        }
        
        self.apiKey = username
        return username
    }
    
    // MARK: - REST API Operations
    
    /// Get the current bridge state (lights, scenes, groups).
    func fetchState() async throws -> HueBridgeState {
        guard let username = apiKey else {
            throw HueError.noApiKey
        }
        
        guard let ip = bridgeIP else {
            throw HueError.noBridgeConfigured
        }
        
        let url = URL(string: "https://\(ip):\(bridgePort)/api/\(username)/resources")!
        
        let (data, _) = try await authenticatedRequest(url: url, method: "GET", body: nil as HueBridgeState?)
        
        return try JSONDecoder().decode(HueBridgeState.self, from: data)
    }
    
    /// Patch light state via CLIP v2 API.
    func patchLightState(resourceId: String, state: LightStatePatch) async throws {
        guard let username = apiKey else {
            throw HueError.noApiKey
        }
        
        guard let ip = bridgeIP else {
            throw HueError.noBridgeConfigured
        }
        
        let url = URL(string: "https://\(ip):\(bridgePort)/api/\(username)/resources/\(resourceId)/action")!
        
        _ = try await authenticatedRequest(url: url, method: "PUT", body: state)
    }
    
    /// Recall a scene via CLIP v2 API.
    func recallScene(groupId: String, sceneId: String) async throws {
        guard let username = apiKey else {
            throw HueError.noApiKey
        }
        
        guard let ip = bridgeIP else {
            throw HueError.noBridgeConfigured
        }
        
        let url = URL(string: "https://\(ip):\(bridgePort)/api/\(username)/groups/\(groupId)/action")!
        
        let patch = ScenePatch(on: true, scene: sceneId)
        
        _ = try await authenticatedRequest(url: url, method: "PUT", body: patch)
    }
    
    /// Set brightness for a light group.
    func setBrightness(groupId: String, brightness: Int, transitionDuration: Int = 4) async throws {
        try await patchLightState(
            resourceId: groupId,
            state: LightStatePatch(on: true, brightness: brightness, transitionDuration: transitionDuration)
        )
    }
    
    /// Set color temperature for a light group.
    func setColorTemperature(groupId: String, mireds: Int, transitionDuration: Int = 4) async throws {
        try await patchLightState(
            resourceId: groupId,
            state: LightStatePatch(on: true, ct: mireds, transitionDuration: transitionDuration)
        )
    }
    
    /// Set XY color for a light group.
    func setColorXY(resourceId: String, x: Double, y: Double, transitionDuration: Int = 4) async throws {
        try await patchLightState(
            resourceId: resourceId,
            state: LightStatePatch(on: true, xy: (x, y), transitionDuration: transitionDuration)
        )
    }
    
    /// Toggle power state for a light group.
    func togglePower(groupId: String, on: Bool) async throws {
        try await patchLightState(resourceId: groupId, state: LightStatePatch(on: on))
    }
    
    /// Toggle power state for an individual light resource.
    func togglePower(resourceId: String, on: Bool) async throws {
        try await patchLightState(resourceId: resourceId, state: LightStatePatch(on: on))
    }
    
    /// Set brightness for an individual light resource.
    func setBrightness(resourceId: String, brightness: Int, transitionDuration: Int = 4) async throws {
        try await patchLightState(
            resourceId: resourceId,
            state: LightStatePatch(on: true, brightness: brightness, transitionDuration: transitionDuration)
        )
    }
    
    /// Set color temperature for an individual light resource.
    func setColorTemperature(resourceId: String, mireds: Int, transitionDuration: Int = 4) async throws {
        try await patchLightState(
            resourceId: resourceId,
            state: LightStatePatch(on: true, ct: mireds, transitionDuration: transitionDuration)
        )
    }
    
    // MARK: - SpatialAware API (Spring 2026)
    
    /// Check if the connected bridge supports SpatialAware features.
    /// Delegates to `HueSpatialService`.
    var isSpatialAwareSupported: Bool { spatialService?.isSpatialAwareSupported ?? false }
    
    /// Verify firmware compatibility before attempting SpatialAware sync.
    /// Delegates to `HueSpatialService`.
    func verifySpatialAwareCompatibility() async throws -> BridgeSpatialInfo {
        guard let spatialService else {
            throw HueError.spatialServiceUnavailable
        }
        return try await spatialService.verifySpatialAwareCompatibility()
    }
    
    /// Map ARKit local space coordinates to Bridge Room Space coordinates.
    /// Delegates to `HueSpatialService`.
    func mapARKitToBridgeSpace(arKitPosition: SIMD3<Float>, arKitOrientation: simd_quatf, referencePoint: SIMD3<Float>?) -> (position: SpatialAwarePosition.Position3D, roomOffset: SpatialAwarePosition.RoomOffset?) {
        guard let spatialService else {
            return (
                position: SpatialAwarePosition.Position3D(x: 0, y: 0, z: 0),
                roomOffset: nil
            )
        }
        let result = spatialService.mapARKitToBridgeSpace(
            arKitPosition: arKitPosition,
            arKitOrientation: arKitOrientation,
            referencePoint: referencePoint
        )
        return (result.position, result.roomOffset)
    }
    
    /// Add a calibration point to the affine transformation solver.
    /// Delegates to `HueSpatialService`.
    func addCalibrationPoint(arKit: SIMD3<Float>, bridge: SIMD3<Float>) {
        spatialService?.addCalibrationPoint(arKit: arKit, bridge: bridge)
    }
    
    /// Clear all calibration points.
    /// Delegates to `HueSpatialService`.
    func clearCalibration() {
        spatialService?.clearCalibration()
    }
    
    /// Get the current calibration points for inspection.
    /// Delegates to `HueSpatialService`.
    func getCalibrationPoints() -> [(arKit: SIMD3<Float>, bridge: SIMD3<Float>)] {
        spatialService?.getCalibrationPoints() ?? []
    }
    
    /// Create a full SpatialAwarePosition from ARKit detection data.
    /// Delegates to `HueSpatialService`.
    func createSpatialAwarePosition(
        lightId: String,
        arKitPosition: SIMD3<Float>,
        arKitOrientation: simd_quatf,
        confidence: Double,
        fixtureType: String,
        materialLabel: String?,
        roomId: String?,
        areaId: String?,
        origin: SIMD3<Float>?
    ) -> SpatialAwarePosition {
        guard let spatialService else {
            return SpatialAwarePosition(
                id: lightId,
                position: SpatialAwarePosition.Position3D(x: 0, y: 0, z: 0),
                confidence: confidence,
                fixtureType: fixtureType,
                roomId: roomId,
                areaId: areaId,
                timestamp: Date(),
                orientation: nil,
                materialLabel: materialLabel,
                roomOffset: nil
            )
        }
        return spatialService.createSpatialAwarePosition(
            lightId: lightId,
            arKitPosition: arKitPosition,
            arKitOrientation: arKitOrientation,
            confidence: confidence,
            fixtureType: fixtureType,
            materialLabel: materialLabel,
            roomId: roomId,
            areaId: areaId,
            origin: origin
        )
    }
    
    /// Sync AR-detected fixture positions back to the Hue Bridge.
    /// Delegates to `HueSpatialService`.
    func syncSpatialAwareness(fixtures: [SpatialAwarePosition]) async throws {
        guard let spatialService else {
            throw HueError.spatialServiceUnavailable
        }
        try await spatialService.syncSpatialAwareness(fixtures: fixtures)
    }
    
    /// Sync a single fixture's spatial awareness data.
    /// Delegates to `HueSpatialService`.
    func syncSpatialAwareness(fixture: SpatialAwarePosition) async throws {
        guard let spatialService else {
            throw HueError.spatialServiceUnavailable
        }
        try await spatialService.syncSpatialAwareness(fixture: fixture)
    }
    
    /// Get current spatial awareness data from the bridge.
    /// Delegates to `HueSpatialService`.
    func fetchSpatialAwareness() async throws -> [SpatialAwarePosition] {
        guard let spatialService else {
            throw HueError.spatialServiceUnavailable
        }
        return try await spatialService.fetchSpatialAwareness()
    }
    
    /// Whether a valid 3+ point calibration has been established.
    /// Delegates to `HueSpatialService`.
    var isCalibrated: Bool { spatialService?.isCalibrated ?? false }
    
    // MARK: - SSE Event Stream
    
    /// Start the SSE connection to the bridge event stream using incremental streaming.
    func startEventStream() {
        guard let username = apiKey else {
            stateStream?.reportError(HueError.noApiKey, severity: .error, source: "HueClient.startEventStream")
            return
        }
        
        guard let ip = bridgeIP else {
            stateStream?.reportError(HueError.noBridgeConfigured, severity: .error, source: "HueClient.startEventStream")
            return
        }
        
        disconnect()
        
        let url = URL(string: "https://\(ip):\(bridgePort)/api/\(username)/eventstream/clip/v2")!
        let keychainKey = KeychainKeys.key(for: ip)
        
        stateStream?.setIsConnected(true)
        
        Task { [weak self] in
            guard let self else { return }
            
            let stateStream = self.stateStream
            await self.eventStream.setEventHandler { @Sendable update in
                stateStream?.applyUpdate(update)
            }
            
            await self.eventStream.setErrorHandler { @Sendable error in
                stateStream?.reportError(error, severity: .error, source: "HueClient.sse")
            }
            
            await self.eventStream.start(
                url: url,
                pinnedHash: pinnedHash,
                keychainKey: keychainKey
            ) { [weak self] trustedHash in
                Task { @MainActor [weak self] in
                    await self?.handleTOFUPin(for: trustedHash)
                }
            }
        }
        
        logger.info("SSE event stream started (actor-managed)")
    }
    
    // MARK: - Connection Management
    
    /// Connect to a specific bridge.
    func connect(to bridge: BridgeInfo) async {
        bridgeIP = bridge.ip
        bridgePort = bridge.port
        logger.info("Connecting to bridge: \(bridge.name) at \(bridge.ip):\(bridge.port)")
        
        setupURLSession()
    }
    
    /// Disconnect from the bridge.
    func disconnect() {
        Task { [eventStream] in
            await eventStream.disconnect()
        }
        stateStream?.setIsConnected(false)
        logger.info("Disconnected from bridge")
    }
    
    /// Reconnect to the bridge (re-authenticate and restart SSE).
    func reconnect() async {
        disconnect()
        
        if bridgeIP == nil {
            let bridges = await discoverBridges()
            if let first = bridges.first {
                await connect(to: first)
            } else {
                Task { [stateStream] in
                    await stateStream?.reportError(HueError.noBridgeConfigured, severity: .error, source: "HueClient.reconnect")
                }
                return
            }
        }
        
        startEventStream()
    }
    
    // MARK: - URL Session Setup
    
    private func setupURLSession() {
        let config = URLSessionConfiguration.default
        
        // Load pinned hash from Keychain for TOFU.
        if let ip = bridgeIP {
            let key = KeychainKeys.key(for: ip)
            Task {
                if let hash = try? await KeychainManager.shared.loadCertPin(from: key) {
                    self.pinnedHash = hash
                }
            }
        }
        
        urlSession = URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }
    
    // MARK: - Trust-On-First-Use Certificate Pinning
    
    /// Handle TOFU pinning: cache the trusted certificate hash on first successful handshake.
    private func handleTOFUPin(for trustedHash: Data) async {
        guard let ip = bridgeIP, !isPinned else { return }
        
        let keychainKey = KeychainKeys.key(for: ip)
        
        do {
            try await KeychainManager.shared.saveCertPin(to: keychainKey, hash: trustedHash)
            pinnedHash = trustedHash
            logger.info("Certificate pinned via TOFU for bridge at \(ip)")
        } catch {
            logger.error("Failed to save certificate pin to Keychain: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Authenticated Request Helper
    
    /// Perform an authenticated REST API request.
    /// Used internally by `HueSpatialService` for spatial-aware API calls.
    func authenticatedRequest<T: Codable>(
        url: URL,
        method: String,
        body: T?
    ) async throws -> (data: Data, response: URLResponse) {
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }
        
        let session = urlSession ?? URLSession.shared
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HueError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error (\(httpResponse.statusCode))"
            throw HueError.apiError(statusCode: httpResponse.statusCode, message: errorMsg)
        }
        
        return (data, response)
    }
}

// MARK: - Bridge Info

/// Bridge information discovered via mDNS.
struct BridgeInfo: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let ip: String
    let port: Int
}

// MARK: - Data SHA-256 Extension

extension Data {
    func sha256() -> Data {
        self.withUnsafeBytes { bytes in
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            CC_SHA256(bytes.baseAddress, CC_LONG(bytes.count), &digest)
            return Data(digest)
        }
    }
}

// MARK: - Errors

enum HueError: Error, LocalizedError {
    case noBridgeConfigured
    case noApiKey
    case authenticationFailed
    case noUsernameReturned
    case invalidResponse
    case invalidURL
    case apiError(statusCode: Int, message: String)
    case certificatePinningFailed
    case sseConnectionLost
    case spatialAwareNotSupported(currentFirmware: String, requiredFirmware: String)
    case spatialAwareSyncFailed(errors: [SpatialAwareSyncError])
    case spatialServiceUnavailable
    
    var errorDescription: String? {
        switch self {
        case .noBridgeConfigured: return "No Hue bridge configured"
        case .noApiKey: return "No API key (username) configured"
        case .authenticationFailed: return "Failed to authenticate with bridge"
        case .noUsernameReturned: return "Bridge did not return an API username"
        case .invalidResponse: return "Invalid response from bridge"
        case .invalidURL: return "Failed to construct a valid URL"
        case .apiError(let code, let msg): return "API error \(code): \(msg)"
        case .certificatePinningFailed: return "Certificate pinning verification failed"
        case .sseConnectionLost: return "SSE connection lost"
        case .spatialAwareNotSupported(let current, let required):
            return "SpatialAware requires firmware \(required), current is \(current)"
        case .spatialAwareSyncFailed(let errors):
            let messages = errors.map { $0.message }.joined(separator: ", ")
            return "SpatialAware sync failed: \(messages)"
        case .spatialServiceUnavailable:
            return "Spatial service is not available"
        }
    }
}

/// Error details from SpatialAware sync failures.
struct SpatialAwareSyncError: Sendable {
    let code: String
    let message: String
}
