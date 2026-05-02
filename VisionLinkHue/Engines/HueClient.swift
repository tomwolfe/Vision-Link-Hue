import Foundation
import Network
import os

/// Network actor that manages all communication with the Philips Hue Bridge
/// using CLIP v2 API, mDNS discovery, mTLS with certificate pinning,
/// and Server-Sent Events (SSE) for real-time state updates.
@MainActor
final class HueClient: ObservableObject {
    
    // MARK: - Published State
    
    @Published var is_connected: Bool = false
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
    
    /// Certificate pinning: expected SHA-256 hash of the bridge's public key.
    /// In production, this would be configured per-bridge or discovered securely.
    private let expectedPublicKeyHash: Data? = nil // nil = skip pinning in dev
    
    /// Network connection for REST API calls.
    private var urlSession: URLSession?
    
    /// SSE connection task.
    private var sseTask: URLSessionDataTask?
    
    /// SSE reconnection timer.
    private var reconnectionTimer: Timer?
    
    /// SSE buffer for assembling fragmented JSON.
    private var sseBuffer = ""
    
    /// SSE reconnect delay (exponential backoff).
    private var reconnectDelay: TimeInterval = 1.0
    
    /// Maximum reconnect delay.
    private let maxReconnectDelay: TimeInterval = 30.0
    
    /// Minimum reconnect delay.
    private let minReconnectDelay: TimeInterval = 1.0
    
    /// Bridge discovery browser.
    private var browser: NWBrowser?
    
    /// State stream publisher.
    private var stateStream: HueStateStream?
    
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
    func discoverBridges() async -> [BridgeInfo] {
        await withCheckedContinuation { continuation in
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            
            let browser = NWBrowser(
                for: .bonjour(type: "_hue._tcp", domain: nil),
                using: params
            )
            
            browser.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    
                    switch newState {
                    case .ready:
                        self.logger.info("mDNS browser ready - discovering bridges")
                    case .failed(let error):
                        self.logger.error("mDNS browser failed: \(error.localizedDescription)")
                        self.lastError = "Discovery failed: \(error.localizedDescription)"
                    case .cancelled:
                        self.logger.info("mDNS browser cancelled")
                    default:
                        break
                    }
                }
            }
            
            browser.browseResultsHandler = { [weak self] results, changes in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    
                    var bridges: [BridgeInfo] = []
                    
                    for result in results where changes == .add {
                        guard case .service(let service) = result.endpoint else { continue }
                        
                        let name = service.name
                        let port = UInt(service.port)
                        
                        // Extract IP from interface addresses
                        for interface in result.interfaces {
                            let ip = interface.ipv4Address ?? interface.ipv6Address
                            if let ip {
                                bridges.append(BridgeInfo(
                                    name: name,
                                    ip: ip.description,
                                    port: Int(port)
                                ))
                                self.logger.info("Found Hue bridge: \(name) at \(ip.description):\(port)")
                            }
                        }
                    }
                    
                    if bridges.isEmpty {
                        self.logger.warning("No Hue bridges discovered")
                        self.lastError = "No Hue bridges found on the network"
                    }
                    
                    continuation.resume(returning: bridges)
                }
            }
            
            self.browser = browser
            browser.start(queue: .main)
        }
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
        
        let (data, response) = try await authenticatedRequest(
            url: url,
            method: "POST",
            body: requestBody
        ) { [weak self] in
            self?.handleCertificateTrust($0)
        }
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw HueError.authenticationFailed
        }
        
        let apiKeyResponse = try JSONDecoder().decode(
            CreateApiKeyResponse.self,
            from: data
        )
        
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
        
        let (data, _) = try await authenticatedRequest(
            url: url,
            method: "GET",
            body: nil
        ) { [weak self] in
            self?.handleCertificateTrust($0)
        }
        
        return try JSONDecoder().decode(HueBridgeState.self, from: data)
    }
    
    /// Patch light state via CLIP v2 API.
    func patchLightState(
        resourceId: String,
        state: LightStatePatch
    ) async throws {
        guard let username = apiKey else {
            throw HueError.noApiKey
        }
        
        guard let ip = bridgeIP, let port = bridgePort else {
            throw HueError.noBridgeConfigured
        }
        
        let url = URL(string: "https://\(ip):\(port)/api/\(username)/resources/\(resourceId)/action")!
        
        _ = try await authenticatedRequest(
            url: url,
            method: "PUT",
            body: state
        ) { [weak self] in
            self?.handleCertificateTrust($0)
        }
    }
    
    /// Recall a scene via CLIP v2 API.
    func recallScene(
        groupId: String,
        sceneId: String
    ) async throws {
        guard let username = apiKey else {
            throw HueError.noApiKey
        }
        
        guard let ip = bridgeIP, let port = bridgePort else {
            throw HueError.noBridgeConfigured
        }
        
        let url = URL(string: "https://\(ip):\(port)/api/\(username)/groups/\(groupId)/action")!
        
        let patch = ScenePatch(on: true, scene: sceneId)
        
        _ = try await authenticatedRequest(
            url: url,
            method: "PUT",
            body: patch
        ) { [weak self] in
            self?.handleCertificateTrust($0)
        }
    }
    
    /// Set brightness for a light group.
    func setBrightness(
        groupId: String,
        brightness: Int,
        transitionDuration: Int = 4
    ) async throws {
        try await patchLightState(
            resourceId: groupId,
            state: LightStatePatch(
                on: true,
                brightness: brightness,
                transitionDuration: transitionDuration
            )
        )
    }
    
    /// Set color temperature for a light group.
    func setColorTemperature(
        groupId: String,
        mireds: Int,
        transitionDuration: Int = 4
    ) async throws {
        try await patchLightState(
            resourceId: groupId,
            state: LightStatePatch(
                on: true,
                ct: mireds,
                transitionDuration: transitionDuration
            )
        )
    }
    
    /// Set XY color for a light group.
    func setColorXY(
        groupId: String,
        x: Double,
        y: Double,
        transitionDuration: Int = 4
    ) async throws {
        try await patchLightState(
            resourceId: groupId,
            state: LightStatePatch(
                on: true,
                xy: (x, y),
                transitionDuration: transitionDuration
            )
        )
    }
    
    /// Toggle power state for a light group.
    func togglePower(groupId: String, on: Bool) async throws {
        try await patchLightState(
            resourceId: groupId,
            state: LightStatePatch(on: on)
        )
    }
    
    // MARK: - SSE Event Stream
    
    /// Start the SSE connection to the bridge event stream.
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
        request.timeoutInterval = 300 // 5 minute timeout
        
        let session = URLSession(configuration: .default, delegate: URLSessionDelegate(), delegateQueue: nil)
        
        sseTask = session.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                
                if let error {
                    self.logger.error("SSE stream error: \(error.localizedDescription)")
                    self.lastError = "Stream error: \(error.localizedDescription)"
                    self.scheduleReconnection()
                    return
                }
                
                guard let data = data, let text = String(data: data, encoding: .utf8) else {
                    self.scheduleReconnection()
                    return
                }
                
                self.processSSEData(text)
            }
        }
        
        sseTask?.resume()
        is_connected = true
        logger.info("SSE event stream started")
    }
    
    /// Process incoming SSE data. Handles reconnection events and JSON fragments.
    private func processSSEData(_ data: String) {
        let lines = data.components(separatedBy: "\n")
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Empty line signals end of an event
            if trimmed.isEmpty {
                processSSEEvent()
                continue
            }
            
            // Skip event type lines (not used for CLIP v2)
            if trimmed.hasPrefix("event:") {
                continue
            }
            
            // Data lines start with "data: "
            if trimmed.hasPrefix("data: ") {
                let jsonFragment = String(trimmed.dropFirst(6))
                sseBuffer.append(jsonFragment)
            }
        }
    }
    
    /// Process a complete SSE event from the buffer.
    private func processSSEEvent() {
        guard !sseBuffer.isEmpty else { return }
        
        let json = sseBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        sseBuffer = ""
        
        // Skip heartbeat ping events from Hue bridge
        if json == "ping" || json.isEmpty {
            return
        }
        
        // Try to parse as a JSON fragment
        do {
            let decoder = JSONDecoder()
            let update = try decoder.decode(ResourceUpdate.self, from: json.data(using: .utf8)!)
            
            if let lights = update.lights, !lights.isEmpty {
                logger.debug("Received \(lights.count) light update(s) via SSE")
            }
            
            stateStream?.applyUpdate(update)
            
        } catch {
            logger.warning("Failed to parse SSE event: \(error.localizedDescription)")
            logger.debug("Raw event: \(json.prefix(200))")
        }
    }
    
    /// Schedule an exponential backoff reconnection.
    private func scheduleReconnection() {
        disconnect()
        
        reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)
        
        reconnectionTimer?.invalidate()
        reconnectionTimer = Timer.scheduledTimer(withTimeInterval: reconnectDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.logger.info("Attempting SSE reconnection...")
                self.startEventStream()
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
        sseBuffer = ""
        reconnectDelay = minReconnectDelay
        is_connected = false
        logger.info("Disconnected from bridge")
    }
    
    /// Reconnect to the bridge (re-authenticate and restart SSE).
    func reconnect() async {
        disconnect()
        
        if bridgeIP == nil {
            // Try auto-discovery first
            let bridges = await discoverBridges()
            if let first = bridges.first {
                await connect(to: first)
            } else {
                lastError = "No bridge found for reconnection"
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
        
        // Disable standard certificate validation (we use pinning)
        let delegate = HueURLSessionDelegate(expectedHash: expectedPublicKeyHash)
        
        urlSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    
    // MARK: - Certificate Pinning
    
    private func handleCertificateTrust(_ challenge: URLAuthenticationChallenge) {
        guard let serverTrust = challenge.protectionSpace.serverTrust,
              let expectedHash = expectedPublicKeyHash else {
            // No pinning configured - accept system trust chain
            challenge.proceed(for: challenge)
            return
        }
        
        let secTrust = serverTrust.secTrust
        var error: CFError?
        
        if SecTrustEvaluateWithError(secTrust, &error) {
            // Validate against pinned hash
            if let publicKey = SecTrustCopyPublicKey(secTrust),
               let publicKeyData =SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
               let hash = publicKeyHash(publicKeyData) {
                
                if hash == expectedHash {
                    challenge.proceed(for: challenge)
                    logger.info("Certificate pinning verified")
                } else {
                    challenge.cancelAuthenticationChallenge(challenge)
                    logger.error("Certificate pinning failed - hash mismatch")
                    lastError = "Bridge certificate pinning failed"
                }
            } else {
                challenge.cancelAuthenticationChallenge(challenge)
                lastError = "Could not extract public key from certificate"
            }
        } else {
            challenge.cancelAuthenticationChallenge(challenge)
            lastError = "Server trust evaluation failed: \(error?.localizedDescription ?? "unknown")"
        }
    }
    
    private func publicKeyHash(_ publicKeyData: Data) -> Data? {
        let hash = publicKeyData.sha256()
        return hash
    }
    
    // MARK: - Authenticated Request Helper
    
    private func authenticatedRequest<T: Codable>(
        url: URL,
        method: String,
        body: Codable?,
        certificateHandler: ((URLAuthenticationChallenge) -> Void)? = nil
    ) async throws -> (data: Data, response: URLResponse) {
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }
        
        let session = urlSession ?? URLSession.shared
        
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let data, let httpResponse = response as? HTTPURLResponse else {
                    continuation.resume(throwing: HueError.invalidResponse)
                    return
                }
                
                guard (200...299).contains(httpResponse.statusCode) else {
                    let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error (\(httpResponse.statusCode))"
                    continuation.resume(throwing: HueError.apiError(statusCode: httpResponse.statusCode, message: errorMsg))
                    return
                }
                
                continuation.resume(returning: (data, response))
            }
            task.resume()
        }
    }
}

/// Bridge information discovered via mDNS.
struct BridgeInfo: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let ip: String
    let port: Int
}

/// Custom URLSession delegate for mTLS certificate pinning.
final class HueURLSessionDelegate: NSObject, URLSessionDelegate {
    
    private let expectedHash: Data?
    
    init(expectedHash: Data?) {
        self.expectedHash = expectedHash
        super.init()
    }
    
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, SecCertificate?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        
        // Default: use system trust evaluation
        if expectedHash == nil {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        
        // Certificate pinning mode
        let secTrust = serverTrust.secTrust
        var error: CFError?
        
        if SecTrustEvaluateWithError(secTrust, &error) {
            if let publicKey = SecTrustCopyPublicKey(secTrust),
               let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
               let hash = publicKeyData.sha256() {
                
                if hash == expectedHash {
                    completionHandler(.useCredential, nil)
                } else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
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
        }
    }
}
