import Foundation
import Network
import Security
import CommonCrypto
import os

// MARK: - Keychain Helpers

private enum KeychainKeys {
    static let service = "com.tomwolfe.visionlinkhue.certpins"
    static func key(for bridgeIP: String) -> String { "certpin_\(bridgeIP)" }
}

private enum KeychainError: Error, LocalizedError {
    case addFailed, queryFailed, accessFailed
    
    var errorDescription: String? {
        switch self {
        case .addFailed: return "Failed to add item to Keychain"
        case .queryFailed: return "Failed to query Keychain"
        case .accessFailed: return "Failed to access Keychain"
        }
    }
}

private func saveCertPin(to keychainKey: String, hash: Data) throws {
    let query: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrService as String: KeychainKeys.service,
        kSecAttrAccount as String: keychainKey,
        kSecValueData as String: hash,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    SecItemDelete(query as CFDictionary)
    guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
        throw KeychainError.addFailed
    }
}

private func loadCertPin(from keychainKey: String) throws -> Data? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrService as String: KeychainKeys.service,
        kSecAttrAccount as String: keychainKey,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
        return nil
    }
    return result as? Data
}

private func deleteCertPin(from keychainKey: String) {
    let query: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrService as String: KeychainKeys.service,
        kSecAttrAccount as String: keychainKey,
    ]
    SecItemDelete(query as CFDictionary)
}

/// Network client that manages all communication with the Philips Hue Bridge
/// using CLIP v2 API, mDNS discovery, mTLS with Trust-On-First-Use certificate
/// pinning, and Server-Sent Events (SSE) for real-time state updates.
final class HueClient: ObservableObject, Sendable {
    
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
    func discoverBridges() async -> [BridgeInfo] {
        return await withCheckedContinuation { continuation in
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            
            let browser = NWBrowser(
                for: .bonjour(type: "_hue._tcp", domain: nil),
                using: params
            )
            
            defer { browser.cancel() }
            
            var discoveredBridges: [BridgeInfo] = []
            
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
                case .cancelled:
                    self?.logger.info("mDNS browser cancelled")
                default:
                    break
                }
            }
            
            browser.browseResultsHandler = { [weak self] results, changes in
                guard changes == .add else { return }
                
                for result in results {
                    guard case .service(let service) = result.endpoint else { continue }
                    
                    let name = service.name
                    let port = UInt(service.port)
                    
                    for interface in result.interfaces {
                        let ip = interface.ipv4Address ?? interface.ipv6Address
                        if let ip {
                            let bridge = BridgeInfo(name: name, ip: ip.description, port: Int(port))
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
                
                continuation.resume(returning: discoveredBridges)
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
        
        let sessionDelegate = HueSessionDelegate(pinnedHash: pinnedHash) { [weak self] trustedHash in
            Task { @MainActor [weak self] in
                await self?.handleTOFUPin(for: trustedHash)
            }
        }
        
        let session = URLSession(configuration: .default, delegate: sessionDelegate, delegateQueue: nil)
        
        Task { [weak self] in
            do {
                let (bytes, response) = try await session.bytes(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    await self?.handleSSEDisconnect(error: HueError.invalidResponse)
                    return
                }
                
                await self?.streamSSEEvents(from: bytes)
                
            } catch {
                await self?.handleSSEDisconnect(error: error)
            }
        }
        
        sseTask = nil
        stateStream?.setIsConnected(true)
        logger.info("SSE event stream started (streaming)")
    }
    
    /// Stream SSE events incrementally from AsyncBytes.
    /// Buffers incomplete JSON objects across network chunk boundaries.
    private func streamSSEEvents(from bytes: AsyncBytes) async {
        var lineBuffer = ""
        var jsonBuffer = ""
        
        for await result in bytes.chunks(ofType: UInt8.self) {
            guard let chunk = String(data: Data(result), encoding: .utf8) else { continue }
            lineBuffer.append(chunk)
            
            let lines = lineBuffer.split(separator: "\n", omittingEmptySubsequences: false)
            
            for line in lines.dropLast() {
                let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                
                if trimmed.isEmpty {
                    processSSEEvent(buffer: &jsonBuffer)
                    continue
                }
                
                if trimmed.hasPrefix("data: ") {
                    let jsonFragment = String(trimmed.dropFirst(6))
                    jsonBuffer.append(jsonFragment)
                }
            }
            
            lineBuffer = String(lines.last ?? "")
        }
        
        processSSEEvent(buffer: &jsonBuffer)
    }
    
    /// Process a complete SSE event from the JSON buffer.
    private func processSSEEvent(buffer: inout String) {
        guard !buffer.isEmpty else { return }
        
        let json = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        
        if json == "ping" || json.isEmpty {
            return
        }
        
        do {
            let decoder = JSONDecoder()
            let update = try decoder.decode(ResourceUpdate.self, from: json.data(using: .utf8)!)
            
            if let lights = update.lights, !lights.isEmpty {
                logger.debug("Received \(lights.count) light update(s) via SSE")
            }
            
            Task {
                await stateStream?.applyUpdate(update)
            }
            
        } catch {
            logger.warning("Failed to parse SSE event: \(error.localizedDescription)")
            logger.debug("Raw event: \(json.prefix(200))")
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
        sseBuffer = ""
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
        
        // Load pinned hash from Keychain for TOFU
        if let ip = bridgeIP, let key = KeychainKeys.key(for: ip),
           let hash = try? loadCertPin(from: key) {
            pinnedHash = hash
        }
        
        let sessionDelegate = HueSessionDelegate(pinnedHash: pinnedHash) { [weak self] trustedHash in
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
            try saveCertPin(to: keychainKey, hash: trustedHash)
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

// MARK: - Session Delegate

/// Unified URLSession delegate handling certificate pinning and TOFU.
final class HueSessionDelegate: NSObject, Sendable, URLSessionDelegate {
    
    let pinnedHash: Data?
    let tofuCallback: (Data) async -> Void
    
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
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        
        guard let publicKey = SecTrustCopyPublicKey(secTrust),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        
        let hash = publicKeyData.sha256()
        
        if let pinnedHash {
            // Enforcement mode: compare against stored hash
            if hash == pinnedHash {
                completionHandler(.useCredential, nil)
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        } else {
            // TOFU mode: trust on first use, cache the hash
            Task {
                await tofuCallback(hash)
                completionHandler(.useCredential, nil)
            }
        }
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
