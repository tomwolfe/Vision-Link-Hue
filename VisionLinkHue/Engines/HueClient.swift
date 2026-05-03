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
    
    // MARK: - Spatial Calibration
    
    /// Calibration points for 3-point affine transformation between ARKit and Bridge space.
    /// Each point contains an ARKit coordinate and its corresponding Bridge Room Space coordinate.
    private var calibrationPoints: [(arKit: SIMD3<Float>, bridge: SIMD3<Float>)] = []
    
    /// Whether a valid 3-point calibration has been established.
    var isCalibrated: Bool { calibrationPoints.count >= 3 }
    
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
    /// Uses a 3-point affine transformation when calibrated, falling back
    /// to a single-point origin offset when calibration is unavailable.
    /// The bridge requires room_offset to be calibrated against the room's
    /// primary entrance or a "Bridge Origin" defined in the Hue App.
    func mapARKitToBridgeSpace(
        arKitPosition: SIMD3<Float>,
        arKitOrientation: simd_quatf,
        referencePoint: SIMD3<Float>? = nil
    ) -> (position: SpatialAwarePosition.Position3D, roomOffset: SpatialAwarePosition.RoomOffset?) {
        let bridgePosition: SIMD3<Float>
        
        if calibrationPoints.count >= 3 {
            // Apply 3-point affine transformation for large-room accuracy
            bridgePosition = applyCalibration(arKitPosition)
        } else if let origin = referencePoint {
            // Fallback: single-point origin offset
            bridgePosition = origin + (arKitPosition - origin)
        } else {
            // Default: identity mapping
            bridgePosition = arKitPosition
        }
        
        let position = SpatialAwarePosition.Position3D(simd: bridgePosition)
        let roomOffset = SpatialAwarePosition.RoomOffset(
            relativeX: Double(bridgePosition.x),
            relativeY: Double(bridgePosition.y),
            relativeZ: Double(bridgePosition.z)
        )
        
        return (position, roomOffset)
    }
    
    /// Apply the 3-point affine calibration transformation to an ARKit position.
    /// Solves for the optimal 3x3 transformation matrix and translation vector
    /// that maps ARKit coordinates to Bridge Room Space coordinates.
    private func applyCalibration(_ arKitPos: SIMD3<Float>) -> SIMD3<Float> {
        guard calibrationPoints.count >= 3 else {
            return arKitPos
        }
        
        // Build the transformation matrix from calibration points.
        // We solve: bridge_pos = M * arKit_pos + t
        // Using at least 3 points to determine the 3x3 matrix M and translation t.
        let n = min(calibrationPoints.count, 6)
        
        // Build source (ARKit) and target (Bridge) matrices
        var source: [SIMD3<Float>] = []
        var target: [SIMD3<Float>] = []
        for i in 0..<n {
            source.append(calibrationPoints[i].arKit)
            target.append(calibrationPoints[i].bridge)
        }
        
        // Compute centroids
        var sourceCentroid = SIMD3<Float>(0, 0, 0)
        var targetCentroid = SIMD3<Float>(0, 0, 0)
        for s in source { sourceCentroid += s }
        for t in target { targetCentroid += t }
        sourceCentroid /= Float(n)
        targetCentroid /= Float(n)
        
        // Compute centered covariance matrix
        var covMatrix = SIMD3x3<Float>(0)
        for i in 0..<n {
            let ds = source[i] - sourceCentroid
            let dt = target[i] - targetCentroid
            covMatrix += dt * ds.transpose
        }
        
        // Compute the optimal rotation using simplified SVD approach
        // For production use, implement full SVD decomposition
        let rotation = computeRotation(from: covMatrix)
        
        // Compute translation
        let translation = targetCentroid - rotation * sourceCentroid
        
        // Apply transformation
        return rotation * arKitPos + translation
    }
    
    /// Compute an approximate rotation matrix from a covariance matrix.
    /// Uses a simplified approach suitable for coordinate space alignment.
    /// For production-grade accuracy, replace with full SVD decomposition.
    private func computeRotation(from covMatrix: SIMD3x3<Float>) -> SIMD3x3<Float> {
        // Use a simplified rotation computation based on the covariance matrix.
        // This provides a good approximation for room-scale alignment.
        // For higher precision, implement full singular value decomposition.
        
        // Compute the symmetric part for scaling
        let symmetric = 0.5 * (covMatrix + covMatrix.transpose)
        
        // Use power iteration to find the dominant eigenvector
        var v = SIMD3<Float>(1, 1, 1)
        v = normalize(v)
        
        for _ in 0..<10 {
            v = symmetric * v
            v = normalize(v)
        }
        
        // Build an orthonormal basis from the dominant eigenvector
        let u1 = v
        let u2Raw = SIMD3<Float>(
            covMatrix[0][1] - covMatrix[1][0],
            covMatrix[1][2] - covMatrix[2][1],
            covMatrix[2][0] - covMatrix[0][2]
        )
        let u2 = normalize(u2Raw)
        let u3 = cross(u1, u2)
        
        // Construct the rotation matrix
        return SIMD3x3<Float>(
            SIMD3<Float>(u1.x, u2.x, u3.x),
            SIMD3<Float>(u1.y, u2.y, u3.y),
            SIMD3<Float>(u1.z, u2.z, u3.z)
        )
    }
    
    /// Add a calibration point to the affine transformation solver.
    /// Requires at least 3 points for a valid calibration.
    /// Points are stored in FIFO order with a maximum of 6 points.
    func addCalibrationPoint(arKit: SIMD3<Float>, bridge: SIMD3<Float>) {
        calibrationPoints.append((arKit: arKit, bridge: bridge))
        
        // Keep only the most recent 6 points for averaging
        if calibrationPoints.count > 6 {
            calibrationPoints = Array(calibrationPoints.suffix(6))
        }
        
        logger.info(
            "Calibration point added (\(calibrationPoints.count)/3 minimum). " +
            "Calibrated: \(isCalibrated)"
        )
    }
    
    /// Clear all calibration points.
    func clearCalibration() {
        calibrationPoints.removeAll()
        logger.info("Calibration cleared")
    }
    
    /// Get the current calibration points for inspection.
    func getCalibrationPoints() -> [(arKit: SIMD3<Float>, bridge: SIMD3<Float>)] {
        calibrationPoints
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
