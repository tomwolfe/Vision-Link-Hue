import Foundation
import Network
import os
import simd
import CommonCrypto
import UIKit
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
@Observable
final class HueClient: HueClientProtocol, HueNetworkClientProtocol {
    
    // MARK: - State
    
    var bridgeIP: String?
    var bridgePort: Int = 443
    var apiKey: String?
    var bridgeConfig: BridgeConfig?
    
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
    
    /// Shared certificate pinning delegate for REST API calls.
    /// Ensures all REST calls use TOFU pinning, not just SSE.
    private var pinningDelegate: CertificatePinningDelegate?
    
    /// Callback for pin mismatch events, allowing the UI to prompt
    /// the user to accept a new certificate (e.g., after bridge reset).
    var onCertificatePinMismatch: @Sendable (Data, Data) async -> Void
    
    /// Dedicated actor for SSE event stream management.
    /// Isolates high-frequency network events from the MainActor.
    private let eventStream = HueEventStreamActor()
    
    /// Observer for app lifecycle notifications (background/foreground).
    /// Used to pause/resume the SSE stream based on app state.
    private var lifecycleObserver: NSObjectProtocol?
    
    /// Configure the SSE event stream behavior.
    func configureEventStream(_ configuration: HueEventStreamActor.Configuration) {
        Task { await self.eventStream.configure(configuration) }
    }
    
    /// Get the current SSE connection health metrics.
    func eventStreamHealthMetrics() async -> HueEventStreamActor.SSEConnectionHealthMetrics {
        await self.eventStream.healthMetrics()
    }
    
    /// Register app lifecycle observers to pause/resume SSE stream.
    /// Called once at app launch to handle background/foreground transitions.
    func registerLifecycleObservers() {
        let notificationCenter = NotificationCenter.default
        
        lifecycleObserver = notificationCenter.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.eventStream.pause()
            }
        }
        
        notificationCenter.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.eventStream.resume()
                // Restart event stream if it was connected when paused
                if let self, await self.apiKey != nil, await self.bridgeIP != nil {
                    await self.startEventStream()
                }
            }
        }
    }
    
    /// State stream publisher.
    weak var stateStream: HueStateStream?
    
    // MARK: - Composed Services
    
    /// Service for discovering Hue bridges on the local network.
    let discoveryService: HueDiscoveryService
    
    /// Service for spatial awareness and coordinate transformation.
    var spatialService: HueSpatialService?
    
    /// Service for Matter/Thread fallback lighting control.
    var matterService: MatterBridgeService?
    
    // MARK: - Initialization
    
    init(stateStream: HueStateStream) {
        self.stateStream = stateStream
        self.discoveryService = HueDiscoveryService()
        self.spatialService = HueSpatialService(stateStream: stateStream)
        self.matterService = MatterBridgeService(hueClient: self)
        self.onCertificatePinMismatch = { _, _ in }
        setupURLSession()
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
        
        guard let url = URL(string: "https://\(ip)/api") else {
            throw HueError.invalidURL
        }
        let requestBody = CreateApiKeyRequest(devicetype: "Vision-Link-Hue-\(UUID().uuidString.prefix(8))")
        
        let (data, response) = try await authenticatedRequest(url: url, method: "POST", body: requestBody)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw HueError.authenticationFailed
        }
        
        let apiKeyResponse = try JSONDecoder.hueDecoder.decode(CreateApiKeyResponse.self, from: data)
        
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
        
        guard let url = URL(string: "https://\(ip):\(bridgePort)/api/\(username)/resources") else {
            throw HueError.invalidURL
        }
        
        let (data, _) = try await authenticatedRequest(url: url, method: "GET")
        
        return try JSONDecoder.hueDecoder.decode(HueBridgeState.self, from: data)
    }
    
    /// Patch light state via CLIP v2 API.
    func patchLightState(resourceId: String, state: LightStatePatch) async throws {
        guard let username = apiKey else {
            throw HueError.noApiKey
        }
        
        guard let ip = bridgeIP else {
            throw HueError.noBridgeConfigured
        }
        
        guard let url = URL(string: "https://\(ip):\(bridgePort)/api/\(username)/resources/\(resourceId)/action") else {
            throw HueError.invalidURL
        }
        
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
        
        guard let url = URL(string: "https://\(ip):\(bridgePort)/api/\(username)/groups/\(groupId)/action") else {
            throw HueError.invalidURL
        }
        
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
    func createSpatialAwarePosition(context: DetectionContext) -> SpatialAwarePosition {
        guard let spatialService else {
            return SpatialAwarePosition(
                id: context.lightId,
                position: SpatialAwarePosition.Position3D(x: 0, y: 0, z: 0),
                confidence: context.confidence,
                fixtureType: context.fixtureType,
                roomId: context.roomId,
                areaId: context.areaId,
                timestamp: Date(),
                orientation: nil,
                materialLabel: context.materialLabel,
                roomOffset: nil
            )
        }
        return spatialService.createSpatialAwarePosition(context: context)
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
    
    // MARK: - Matter Fallback
    
    var isMatterFallbackAvailable: Bool {
        matterService?.hasReachableDevices ?? false
    }
    
    var preferredControlPath: ControlPath {
        matterService?.preferredControlPath(hueBridgeAvailable: bridgeIP != nil) ?? .none
    }
    
    func fetchMatterDevices() async throws -> MatterBridgeState {
        guard let matterService else {
            throw MatterError.homeKitNotAvailable
        }
        return try await matterService.fetchDevices()
    }
    
    func setMatterPower(deviceId: String, on: Bool) async throws {
        guard let matterService else {
            throw MatterError.homeKitNotAvailable
        }
        try await matterService.toggle(deviceId: deviceId, on: on)
    }
    
    func setMatterBrightness(deviceId: String, brightness: Int, transitionDuration: Int = 4) async throws {
        guard let matterService else {
            throw MatterError.homeKitNotAvailable
        }
        try await matterService.setBrightness(Double(brightness), deviceId: deviceId, transitionDuration: TimeInterval(transitionDuration))
    }
    
    func setMatterColorTemperature(deviceId: String, mireds: Int, transitionDuration: Int = 4) async throws {
        guard let matterService else {
            throw MatterError.homeKitNotAvailable
        }
        try await matterService.setColorTemperature(Double(mireds), deviceId: deviceId, transitionDuration: TimeInterval(transitionDuration))
    }
    
    func setMatterColorXY(deviceId: String, x: Double, y: Double, transitionDuration: Int = 4) async throws {
        guard let matterService else {
            throw MatterError.homeKitNotAvailable
        }
        try await matterService.setColorX(x, y, deviceId: deviceId, transitionDuration: TimeInterval(transitionDuration))
    }
    
    func patchMatterLight(deviceId: String, patch: MatterLightStatePatch) async throws {
        guard let matterService else {
            throw MatterError.homeKitNotAvailable
        }
        try await matterService.patch(deviceId: deviceId, patch: patch)
    }
    
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
        
        guard let url = URL(string: "https://\(ip):\(bridgePort)/api/\(username)/eventstream/clip/v2") else {
            stateStream?.reportError(HueError.invalidURL, severity: .error, source: "HueClient.startEventStream")
            return
        }
        let keychainKey = KeychainKeys.key(for: ip)
        
        stateStream?.setIsConnected(true)
        
        Task { [weak self] in
            guard let self else { return }
            
            await self.eventStream.setEventHandler { [weak self] update in
                Task { @MainActor [weak self] in
                    self?.stateStream?.applyUpdate(update)
                }
            }
            
            await self.eventStream.setErrorHandler { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.stateStream?.reportError(error, severity: .error, source: "HueClient.sse")
                }
            }
            
            await self.eventStream.start(
                url: url,
                pinnedHash: pinnedHash,
                keychainKey: keychainKey
            ) { [weak self] trustedHash in
                Task { @MainActor [weak self] in
                    await self?.handleTOFUPin(for: trustedHash)
                }
            } onPinMismatch: { [weak self] newHash, oldHash in
                Task { @MainActor [weak self] in
                    await self?.onCertificatePinMismatch(newHash, oldHash)
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
    /// If the bridge IP is lost, reports a critical error to prompt the
    /// user to manually select a bridge rather than auto-connecting to
    /// the first mDNS result in multi-bridge environments.
    func reconnect() async {
        disconnect()
        
        if bridgeIP == nil {
            let bridges = await discoverBridges()
            
            if bridges.isEmpty {
                Task { [stateStream] in
                    await stateStream?.reportError(HueError.noBridgeConfigured, severity: .error, source: "HueClient.reconnect")
                }
                return
            }
            
            if bridges.count > 1 {
                let noBridgeError = NSError(
                    domain: "HueClient",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Bridge connection lost. Multiple bridges detected (\(bridges.count)). Please select a bridge to reconnect."
                    ]
                )
                Task { [stateStream] in
                    await stateStream?.reportError(noBridgeError, severity: .critical, source: "HueClient.reconnect")
                }
                return
            }
            
            await connect(to: bridges.first!)
        }
        
        startEventStream()
    }
    
    // MARK: - URL Session Setup
    
    private func setupURLSession() {
        let config = URLSessionConfiguration.default
        let currentPinnedHash = pinnedHash
        let currentBridgeIP = bridgeIP
        
        // Load pinned hash from Keychain for TOFU.
        if let ip = currentBridgeIP {
            let key = KeychainKeys.key(for: ip)
            Task {
                if let hash = try? await KeychainManager.shared.loadCertPin(from: key) {
                    self.pinnedHash = hash
                }
            }
        }
        
        // Create a shared certificate pinning delegate for all REST calls.
        // This ensures REST API calls use the same TOFU pinning as the SSE stream.
        let keychainKey = currentBridgeIP.map { KeychainKeys.key(for: $0) }
        pinningDelegate = CertificatePinningDelegate(
            pinnedHash: currentPinnedHash,
            keychainKey: keychainKey
        ) { [weak self] trustedHash in
            Task { @MainActor [weak self] in
                await self?.handleTOFUPin(for: trustedHash)
            }
        } onPinMismatch: { [weak self] newHash, oldHash in
            if let self {
                Task { @MainActor [weak self] in
                    await self?.onCertificatePinMismatch(newHash, oldHash)
                }
            }
        }
        
        urlSession = URLSession(configuration: config, delegate: pinningDelegate, delegateQueue: nil)
    }
    
    // MARK: - Trust-On-First-Use Certificate Pinning
    
    /// Handle TOFU pinning: cache the trusted certificate hash on first successful handshake.
    private func handleTOFUPin(for trustedHash: Data) async {
        guard let ip = bridgeIP, !isPinned else { return }
        
        let keychainKey = KeychainKeys.key(for: ip)
        
        do {
            try await KeychainManager.shared.saveCertPin(to: keychainKey, hash: trustedHash)
            pinnedHash = trustedHash
            pinningDelegate?.updatePinnedHash(trustedHash)
            logger.info("Certificate pinned via TOFU for bridge at \(ip)")
        } catch {
            logger.error("Failed to save certificate pin to Keychain: \(error.localizedDescription)")
        }
    }
    
    // MARK: - HueNetworkClientProtocol Conformance
    
    func get(url: URL) async throws -> (data: Data, response: URLResponse) {
        try await authenticatedRequest(url: url, method: "GET")
    }
    
    func put<T: Codable>(url: URL, body: T) async throws -> (data: Data, response: URLResponse) {
        try await authenticatedRequest(url: url, method: "PUT", body: body)
    }
    
    func post<T: Codable>(url: URL, body: T) async throws -> (data: Data, response: URLResponse) {
        try await authenticatedRequest(url: url, method: "POST", body: body)
    }
    
    // MARK: - Authenticated Request Helper
    
    /// Transient error status codes that warrant automatic retry.
    private static let retryableStatusCodes: Set<Int> = [408, 500, 502, 503, 504]
    
    /// Maximum number of retry attempts for transient failures.
    private static let maxRetries = 2
    
    /// Base delay between retries in seconds.
    private static let retryBaseDelay: TimeInterval = 0.5
    
    /// Perform an authenticated REST API request with a JSON body.
    /// Used internally by `HueSpatialService` for spatial-aware API calls.
    func authenticatedRequest<T: Codable>(
        url: URL,
        method: String,
        body: T
    ) async throws -> (data: Data, response: URLResponse) {
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder.hueEncoder.encode(body)
        
        let session = urlSession ?? URLSession.shared
        
        let (data, response) = try await authenticatedRequestWithRetry(session: session, request: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HueError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error (\(httpResponse.statusCode))"
            throw HueError.apiError(statusCode: httpResponse.statusCode, message: errorMsg)
        }
        
        return (data, response)
    }
    
    /// Perform an authenticated REST API request without a body.
    func authenticatedRequest(
        url: URL,
        method: String
    ) async throws -> (data: Data, response: URLResponse) {
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let session = urlSession ?? URLSession.shared
        
        let (data, response) = try await authenticatedRequestWithRetry(session: session, request: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HueError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error (\(httpResponse.statusCode))"
            throw HueError.apiError(statusCode: httpResponse.statusCode, message: errorMsg)
        }
        
        return (data, response)
    }
    
    /// Perform a request with automatic retry for transient network failures.
    private func authenticatedRequestWithRetry(
        session: URLSession,
        request: URLRequest
    ) async throws -> (data: Data, response: URLResponse) {
        var lastError: any Error = HueError.invalidResponse
        
        for attempt in 0...Self.maxRetries {
            do {
                let (data, response) = try await session.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw HueError.invalidResponse
                }
                
                if Self.retryableStatusCodes.contains(httpResponse.statusCode) {
                    lastError = HueError.apiError(statusCode: httpResponse.statusCode, message: "Transient server error on attempt \(attempt + 1)")
                    if attempt < Self.maxRetries {
                        let jitterDelay = Self.retryBaseDelay * pow(2.0, Double(attempt)) + Double.random(in: 0...0.2)
                        logger.debug("Retryable status \(httpResponse.statusCode) on attempt \(attempt + 1), retrying in \(String(format: "%.2f", jitterDelay))s")
                        try? await Task.sleep(for: .seconds(jitterDelay))
                    } else {
                        let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error (\(httpResponse.statusCode))"
                        throw HueError.apiError(statusCode: httpResponse.statusCode, message: errorMsg)
                    }
                } else {
                    return (data, response)
                }
            } catch {
                lastError = error
                
                // Check if it's a URL session timeout error
                let nsError = error as NSError
                let isURLErrorTimeout = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
                let isURLErrorCancelled = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
                
                if isURLErrorTimeout && attempt < Self.maxRetries {
                    let jitterDelay = Self.retryBaseDelay * pow(2.0, Double(attempt)) + Double.random(in: 0...0.2)
                    logger.debug("Timeout on attempt \(attempt + 1), retrying in \(String(format: "%.2f", jitterDelay))s")
                    try? await Task.sleep(for: .seconds(jitterDelay))
                } else if isURLErrorCancelled {
                    throw error
                } else {
                    throw error
                }
            }
        }
        
        throw lastError
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
    case matterFallbackUnavailable
    case matterControlFailed(deviceId: String, error: String)
    
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
        case .matterFallbackUnavailable:
            return "Matter fallback is not available"
        case .matterControlFailed(let deviceId, let error):
            return "Matter control failed for device \(deviceId): \(error)"
        }
    }
}

/// Error details from SpatialAware sync failures.
struct SpatialAwareSyncError: Sendable {
    let code: String
    let message: String
}
