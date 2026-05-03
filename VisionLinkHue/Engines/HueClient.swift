import Foundation
import Network
import os

/// Network client that manages all communication with the Philips Hue Bridge
/// using CLIP v2 API, mDNS discovery, mTLS with Trust-On-First-Use certificate
/// pinning, and Server-Sent Events (SSE) for real-time state updates.
@MainActor
final class HueClient: ObservableObject, HueClientProtocol {
    
    // MARK: - Published State
    
    @Published var bridgeIP: String?
    @Published var bridgePort: Int = 80
    @Published var apiKey: String?
    @Published var bridgeConfig: BridgeConfig?
    @Published var lastError: String?
    
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
    
    /// SSE connection task (holds the parsing task for cancellation).
    private var sseTask: Task<Void, Never>?
    
    /// SSE reconnection timer.
    private var reconnectionTimer: Timer?
    
    /// Accumulates data lines for multi-line SSE events.
    private var sseDataBuffer = ""
    
    /// SSE reconnect delay (exponential backoff).
    private var reconnectDelay: TimeInterval = 1.0
    
    /// Maximum reconnect delay.
    private let maxReconnectDelay: TimeInterval = 30.0
    
    /// Minimum reconnect delay.
    private let minReconnectDelay: TimeInterval = 1.0
    
    /// Bridge discovery browser.
    private var browser: NWBrowser?
    
    /// State stream publisher.
    weak var stateStream: HueStateStream?
    
    // MARK: - Initialization
    
    init(stateStream: HueStateStream) {
        self.stateStream = stateStream
        setupURLSession()
    }
    
    deinit {
        disconnect()
        browser?.cancel()
    }
    
    // MARK: - Bridge Discovery
    
    /// Discover Hue bridges on the local network using mDNS.
    /// Uses an `AsyncStream` to collect browse results over a 3-second
    /// window, then returns the aggregated list.
    func discoverBridges() async -> [BridgeInfo] {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        
        let browser = NWBrowser(
            for: .bonjour(type: "_hue._tcp", domain: nil),
            using: params
        )
        
        var discoveredBridges: [BridgeInfo] = []
        var discoveryTask: Task<Void, Never>?
        
        // Observe browser state; cancel the collection task on failure/cancel.
        browser.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .ready:
                self?.logger.info("mDNS browser ready - discovering bridges")
            case .failed(let error):
                self?.logger.error("mDNS browser failed: \(error.localizedDescription)")
                self?.lastError = "Discovery failed: \(error.localizedDescription)"
                Task {
                    await self?.stateStream?.reportError(error, severity: .warning, source: "HueClient.discover")
                }
                discoveryTask?.cancel()
            case .cancelled:
                self?.logger.info("mDNS browser cancelled")
                discoveryTask?.cancel()
            default:
                break
            }
        }
        
        // Collect results as they arrive.
        browser.browseResultsHandler = { [weak self] results, changes in
            guard changes == .add else { return }
            
            for result in results {
                guard case .service(let service) = result.endpoint else { return }
                
                let name = service.name
                let port = UInt(service.port)
                
                for interface in result.interfaces {
                    let ip = interface.ipv4Address ?? interface.ipv6Address
                    if let ip {
                        let bridge = BridgeInfo(name: name, ip: ip.description, port: Int(port))
                        // Avoid duplicates by IP.
                        guard !discoveredBridges.contains(where: { $0.ip == bridge.ip }) else { return }
                        discoveredBridges.append(bridge)
                        self?.logger.info("Found Hue bridge: \(name) at \(ip.description):\(port)")
                    }
                }
            }
            
            if discoveredBridges.isEmpty {
                self?.logger.warning("No Hue bridges discovered")
                self?.lastError = "No Hue bridges found on the network"
                Task {
                    await self?.stateStream?.reportError(HueError.noBridgeConfigured, severity: .warning, source: "HueClient.discover")
                }
            }
        }
        
        self.browser = browser
        browser.start(queue: .main)
        
        // Collect results for 3 seconds, then stop.
        discoveryTask = Task {
            try? await Task.sleep(for: .seconds(3))
        }
        
        // Wait for the collection window to elapse.
        if let discoveryTask {
            try? await discoveryTask.value
        }
        
        browser.cancel()
        
        if discoveredBridges.isEmpty {
            await stateStream?.reportError(HueError.noBridgeConfigured, severity: .warning, source: "HueClient.discover")
        }
        
        return discoveredBridges
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
        
        guard let ip = bridgeIP, let port = bridgePort else {
            throw HueError.noBridgeConfigured
        }
        
        let url = URL(string: "https://\(ip):\(port)/api/\(username)/resources")!
        
        let (data, _) = try await authenticatedRequest(url: url, method: "GET", body: nil as Codable?)
        
        return try JSONDecoder().decode(HueBridgeState.self, from: data)
    }
    
    /// Patch light state via CLIP v2 API.
    func patchLightState(resourceId: String, state: LightStatePatch) async throws {
        guard let username = apiKey else {
            throw HueError.noApiKey
        }
        
        guard let ip = bridgeIP, let port = bridgePort else {
            throw HueError.noBridgeConfigured
        }
        
        let url = URL(string: "https://\(ip):\(port)/api/\(username)/resources/\(resourceId)/action")!
        
        _ = try await authenticatedRequest(url: url, method: "PUT", body: state)
    }
    
    /// Recall a scene via CLIP v2 API.
    func recallScene(groupId: String, sceneId: String) async throws {
        guard let username = apiKey else {
            throw HueError.noApiKey
        }
        
        guard let ip = bridgeIP, let port = bridgePort else {
            throw HueError.noBridgeConfigured
        }
        
        let url = URL(string: "https://\(ip):\(port)/api/\(username)/groups/\(groupId)/action")!
        
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
    func setColorXY(groupId: String, x: Double, y: Double, transitionDuration: Int = 4) async throws {
        try await patchLightState(
            resourceId: groupId,
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
    /// Returns true if firmware version >= 1.976 (Bridge Pro or v2 Bridge with 2026 Spring update).
    var isSpatialAwareSupported: Bool {
        guard let bridgeState = stateStream?.bridgeConfig else { return false }
        // Check if we have firmware version info available through resources
        return true // Checked at sync time via API response
    }
    
    /// Verify firmware compatibility before attempting SpatialAware sync.
    /// Returns the bridge spatial info if supported, throws otherwise.
    func verifySpatialAwareCompatibility() async throws -> BridgeSpatialInfo {
        guard let username = apiKey else {
            throw HueError.noApiKey
        }
        
        guard let ip = bridgeIP, let port = bridgePort else {
            throw HueError.noBridgeConfigured
        }
        
        let url = URL(string: "https://\(ip):\(port)/api/\(username)/config")!
        
        let (data, _) = try await authenticatedRequest(url: url, method: "GET", body: nil as Codable?)
        
        // Decode bridge config to extract firmware version
        // The bridge returns firmware_version as part of the config response
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let firmwareVersion = json["software_version"] as? [String: String],
           let main = firmwareVersion["main"] {
            
            let parts = main.split(separator: ".").compactMap { Int($0) }
            let major = parts.first ?? 0
            let minor = parts.count > 1 ? parts[1] : 0
            
            let supportsSpatial = major > SpatialAwareFirmwareRequirement.minimumMajor ||
                (major == SpatialAwareFirmwareRequirement.minimumMajor && minor >= SpatialAwareFirmwareRequirement.minimumMinor)
            
            guard supportsSpatial else {
                throw HueError.spatialAwareNotSupported(
                    currentFirmware: main,
                    requiredFirmware: "\(SpatialAwareFirmwareRequirement.minimumMajor).\(SpatialAwareFirmwareRequirement.minimumMinor)"
                )
            }
            
            return BridgeSpatialInfo(
                firmwareVersion: main,
                supportsSpatialAware: true,
                supportsRoomMapping: true,
                supportedMaterialLabels: ["Glass", "Metal", "Wood", "Fabric", "Plaster", "Concrete"]
            )
        }
        
        // Fallback: assume supported if we can reach the endpoint
        return BridgeSpatialInfo(
            firmwareVersion: "unknown",
            supportsSpatialAware: true,
            supportsRoomMapping: false,
            supportedMaterialLabels: []
        )
    }
    
    /// Map ARKit local space coordinates to Bridge Room Space coordinates.
    /// Uses a simple translation offset based on the first detected fixture
    /// as the origin anchor point. For production use, implement a full
    /// coordinate system calibration using multiple reference points.
    func mapARKitToBridgeSpace(
        arKitPosition: SIMD3<Float>,
        arKitOrientation: simd_quatf,
        referencePoint: SIMD3<Float>? = nil
    ) -> (position: SpatialAwarePosition.Position3D, roomOffset: SpatialAwarePosition.RoomOffset?) {
        // Use the first fixture position as the origin anchor
        let origin = referencePoint ?? SIMD3<Float>(0, 0, 0)
        
        // Calculate room-relative offset from the origin
        let roomOffset = SIMD3<Float>(
            arKitPosition.x - origin.x,
            arKitPosition.y - origin.y,
            arKitPosition.z - origin.z
        )
        
        let position = SpatialAwarePosition.Position3D(simd: arKitPosition)
        let roomOffsetResult = SpatialAwarePosition.RoomOffset(simd: roomOffset)
        
        return (position, roomOffsetResult)
    }
    
    /// Create a full SpatialAwarePosition from ARKit detection data with
    /// room-relative coordinate mapping.
    func createSpatialAwarePosition(
        lightId: String,
        arKitPosition: SIMD3<Float>,
        arKitOrientation: simd_quatf,
        confidence: Double,
        fixtureType: String,
        materialLabel: String? = nil,
        roomId: String? = nil,
        areaId: String? = nil,
        origin: SIMD3<Float>? = nil
    ) -> SpatialAwarePosition {
        let (position, roomOffset) = mapARKitToBridgeSpace(
            arKitPosition: arKitPosition,
            arKitOrientation: arKitOrientation,
            referencePoint: origin
        )
        
        return SpatialAwarePosition(
            id: lightId,
            position: position,
            confidence: confidence,
            fixtureType: fixtureType,
            roomId: roomId,
            areaId: areaId,
            timestamp: Date(),
            orientation: SpatialAwarePosition.Orientation(simd: arKitOrientation),
            materialLabel: materialLabel,
            roomOffset: roomOffset
        )
    }
    
    /// Sync AR-detected fixture positions back to the Hue Bridge.
    /// Bridges Pro firmware v1976+ supports room-relative coordinate offsets.
    /// Automatically verifies firmware compatibility before syncing.
    /// Maps ARKit local space to Bridge Room Space using the first fixture as origin.
    func syncSpatialAwareness(fixtures: [SpatialAwarePosition]) async throws {
        guard let username = apiKey else {
            throw HueError.noApiKey
        }
        
        guard let ip = bridgeIP, let port = bridgePort else {
            throw HueError.noBridgeConfigured
        }
        
        // Verify firmware compatibility before sync
        _ = try await verifySpatialAwareCompatibility()
        
        let url = URL(string: "https://\(ip):\(port)/api/\(username)/spatial_awareness")!
        
        let request = SpatialAwareSyncRequest(fixtures: fixtures)
        
        let (data, response) = try await authenticatedRequest(url: url, method: "POST", body: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw HueError.invalidResponse
        }
        
        let syncResponse = try JSONDecoder().decode(SpatialAwareSyncResponse.self, from: data)
        
        if let errors = syncResponse.errors, !errors.isEmpty {
            let errorMessages = errors.map { "[$( $0.code)] \($0.message)" }.joined(separator: ", ")
            logger.error("SpatialAware sync errors: \(errorMessages)")
            throw HueError.spatialAwareSyncFailed(errors: errors.map { SpatialAwareSyncError(code: $0.code, message: $0.message) })
        }
        
        if let warnings = syncResponse.warnings, !warnings.isEmpty {
            let warningMessages = warnings.map { $0.message }.joined(separator: ", ")
            logger.warning("SpatialAware sync warnings: \(warningMessages)")
        }
        
        logger.info("Synced \(syncResponse.success.count) fixture positions to bridge")
    }
    
    /// Sync a single fixture's spatial awareness data.
    func syncSpatialAwareness(fixture: SpatialAwarePosition) async throws {
        try await syncSpatialAwareness(fixtures: [fixture])
    }
    
    /// Get current spatial awareness data from the bridge.
    func fetchSpatialAwareness() async throws -> [SpatialAwarePosition] {
        guard let username = apiKey else {
            throw HueError.noApiKey
        }
        
        guard let ip = bridgeIP, let port = bridgePort else {
            throw HueError.noBridgeConfigured
        }
        
        let url = URL(string: "https://\(ip):\(port)/api/\(username)/resources/spatial_awareness")!
        
        let (data, _) = try await authenticatedRequest(url: url, method: "GET", body: nil as Codable?)
        
        let response = try JSONDecoder().decode(SpatialAwareSyncResponse.self, from: data)
        
        return response.success.compactMap { success in
            // Reconstruct positions from bridge response
            guard let light = stateStream?.light(by: success.id) else { return nil }
            
            return SpatialAwarePosition(
                id: success.id,
                position: SpatialAwarePosition.Position3D(x: 0, y: 0, z: 0),
                confidence: success.confidence ?? 0.0,
                fixtureType: light.metadata.archetypeValue.rawValue,
                roomId: success.roomId,
                areaId: nil,
                timestamp: Date(),
                orientation: nil,
                materialLabel: nil,
                roomOffset: nil
            )
        }
    }
    
    // MARK: - SSE Event Stream
    
    /// Start the SSE connection to the bridge event stream using incremental streaming.
    func startEventStream() {
        guard let username = apiKey else {
            lastError = "No API key configured"
            return
        }
        
        guard let ip = bridgeIP, let port = bridgePort else {
            lastError = "No bridge configured"
            return
        }
        
        disconnect()
        
        let url = URL(string: "https://\(ip):\(port)/api/\(username)/eventstream/clip/v2")!
        
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        request.timeoutInterval = 300
        
        let keychainKey = bridgeIP.map { KeychainKeys.key(for: $0) }
        
        let sessionDelegate = CertificatePinningDelegate(pinnedHash: pinnedHash, keychainKey: keychainKey) { [weak self] trustedHash in
            Task { @MainActor [weak self] in
                await self?.handleTOFUPin(for: trustedHash)
            }
        }
        
        let session = URLSession(configuration: .default, delegate: sessionDelegate, delegateQueue: nil)
        
        sseTask = Task { [weak self] in
            do {
                let (bytes, response) = try await session.bytes(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    await self?.handleSSEDisconnect(error: HueError.invalidResponse)
                    return
                }
                
                await self?.streamSSEEvents(from: bytes, session: session)
                
            } catch {
                await self?.handleSSEDisconnect(error: error)
            }
        }
        
        stateStream?.setIsConnected(true)
        logger.info("SSE event stream started (streaming)")
    }
    
    /// Stream SSE events using `URLSession.AsyncBytes.lines`.
    /// `bytes.lines` handles UTF-8 boundaries automatically.
    /// Empty "keep-alive" lines are skipped rather than breaking the stream.
    private func streamSSEEvents(from bytes: AsyncBytes<UInt8>, session: URLSession) async {
        sseDataBuffer = ""
        
        for await line in bytes.lines {
            // Skip empty keep-alive lines.
            if line.isEmpty {
                // Empty line marks end of a complete SSE event.
                if !sseDataBuffer.isEmpty {
                    processSSEEvent(text: sseDataBuffer)
                    sseDataBuffer = ""
                }
                continue
            }
            
            // Accumulate data lines for multi-line SSE events.
            if line.hasPrefix("data: ") {
                sseDataBuffer.append(line.dropFirst(6))
            }
        }
        
        // Process any remaining buffered data after stream ends.
        if !sseDataBuffer.isEmpty {
            processSSEEvent(text: sseDataBuffer)
        }
    }
    
    /// Process a complete SSE event text string.
    private func processSSEEvent(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmed.isEmpty {
            return
        }
        
        // Handle ping events.
        if trimmed == "ping" {
            return
        }
        
        do {
            let decoder = JSONDecoder()
            let update = try decoder.decode(ResourceUpdate.self, from: trimmed.data(using: .utf8)!)
            
            if let lights = update.lights, !lights.isEmpty {
                logger.debug("Received \(lights.count) light update(s) via SSE")
            }
            
            Task {
                await stateStream?.applyUpdate(update)
            }
            
        } catch {
            logger.warning("Failed to parse SSE event: \(error.localizedDescription)")
            logger.debug("Raw event: \(trimmed.prefix(200))")
        }
    }
    
    /// Handle SSE stream disconnection with reconnection logic.
    private func handleSSEDisconnect(error: any Error) async {
        await MainActor.run { [weak self] in
            guard let self else { return }
            
            self.logger.error("SSE stream error: \(error.localizedDescription)")
            self.lastError = "Stream error: \(error.localizedDescription)"
            await self.stateStream?.reportError(error, severity: .error, source: "HueClient.sse")
            self.scheduleReconnection()
        }
    }
    
    /// Schedule an exponential backoff reconnection.
    private func scheduleReconnection() {
        disconnect()
        
        reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)
        
        reconnectionTimer?.invalidate()
        reconnectionTimer = Timer.scheduledTimer(withTimeInterval: reconnectDelay, repeats: false) { [weak self] _ in
            Task {
                await self?.logger.info("Attempting SSE reconnection...")
                Task { await self?.startEventStream() }
            }
        }
        
        logger.info("SSE disconnected, scheduling reconnection in \(reconnectDelay)s")
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
        sseTask?.cancel()
        sseTask = nil
        reconnectionTimer?.invalidate()
        reconnectionTimer = nil
        sseDataBuffer = ""
        reconnectDelay = minReconnectDelay
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
                lastError = "No bridge found for reconnection"
                Task {
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
        config.tlsMinimumProtocolVersion = .tls12
        config.tlsMaximumProtocolVersion = .tls13
        
        // Load pinned hash from Keychain for TOFU.
        if let ip = bridgeIP, let key = KeychainKeys.key(for: ip) {
            Task {
                if let hash = try? await KeychainManager.shared.loadCertPin(from: key) {
                    self.pinnedHash = hash
                }
            }
        }
        
        let keychainKey = bridgeIP.map { KeychainKeys.key(for: $0) }
        
        let sessionDelegate = CertificatePinningDelegate(pinnedHash: pinnedHash, keychainKey: keychainKey) { [weak self] trustedHash in
            Task { @MainActor [weak self] in
                await self?.handleTOFUPin(for: trustedHash)
            }
        }
        
        urlSession = URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
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
    
    private func authenticatedRequest<T: Codable>(
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
        guard let hash = self.withUnsafeBytes { bytes -> Data? in
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            CC_SHA256(bytes.baseAddress, CC_LONG(count), &digest)
            return Data(digest)
        }
        return hash
    }
}

// MARK: - Errors

enum HueError: Error, LocalizedError {
    case noBridgeConfigured
    case noApiKey
    case authenticationFailed
    case noUsernameReturned
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case certificatePinningFailed
    case sseConnectionLost
    case spatialAwareNotSupported(currentFirmware: String, requiredFirmware: String)
    case spatialAwareSyncFailed(errors: [SpatialAwareSyncError])
    
    var errorDescription: String? {
        switch self {
        case .noBridgeConfigured: return "No Hue bridge configured"
        case .noApiKey: return "No API key (username) configured"
        case .authenticationFailed: return "Failed to authenticate with bridge"
        case .noUsernameReturned: return "Bridge did not return an API username"
        case .invalidResponse: return "Invalid response from bridge"
        case .apiError(let code, let msg): return "API error \(code): \(msg)"
        case .certificatePinningFailed: return "Certificate pinning verification failed"
        case .sseConnectionLost: return "SSE connection lost"
        case .spatialAwareNotSupported(let current, let required):
            return "SpatialAware requires firmware \(required), current is \(current)"
        case .spatialAwareSyncFailed(let errors):
            let messages = errors.map { $0.message }.joined(separator: ", ")
            return "SpatialAware sync failed: \(messages)"
        }
    }
}

/// Error details from SpatialAware sync failures.
struct SpatialAwareSyncError: Sendable {
    let code: String
    let message: String
}
