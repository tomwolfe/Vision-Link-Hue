import Foundation
import os

/// Actor that manages the Server-Sent Events (SSE) connection to the
/// Philips Hue Bridge event stream. Isolates high-frequency network
/// events from the MainActor `HueClient` to prevent blocking.
///
/// Manages the full SSE lifecycle: connection, parsing, reconnection
/// with exponential backoff, and state machine transitions between
/// connected/disconnected/reconnecting/degraded states.
actor HueEventStreamActor {
    
    // MARK: - Public State
    
    /// Current SSE connection state.
    var state: SSEReconnectionState = .idle
    
    /// Whether the stream is currently paused (e.g., app in background).
    /// When paused, reconnection attempts are suspended and the active
    /// stream is gracefully disconnected to conserve resources.
    var isPaused: Bool = false
    
    /// Whether the stream is currently connected and receiving events.
    var isConnected: Bool { state == .connected }
    
    /// Event handler for parsed resource updates from the bridge.
    var onEvent: (@Sendable (ResourceUpdate) -> Void)?

    /// Error handler for stream-level errors.
    var onError: (@Sendable (any Error) -> Void)?

    /// Callback invoked when the SSE buffer overflows and a full sync is required.
    /// When `maxSSEBufferLength` is exceeded, the incremental stream may be
    /// corrupted or out of order. This callback signals the parent `HueClient`
    /// to force a clean `GET /resources` fetch to recover state.
    var onFullSyncRequired: (@Sendable () -> Void)?
    
    // MARK: - Private State
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "HueEventStream"
    )
    
    /// The active URL session for the SSE connection.
    private var urlSession: URLSession?
    
    /// The active SSE parsing task (holds the stream for cancellation).
    private var sseTask: Task<Void, Never>?
    
    /// The active reconnection backoff task.
    private var reconnectTask: Task<Void, Never>?
    
    /// Accumulates data lines for multi-line SSE events.
    private var sseDataBuffer = ""
    
    /// Reconnection delay with exponential backoff.
    var reconnectDelay: TimeInterval = 1.0
    
    /// Maximum reconnect delay.
    private var maxReconnectDelay: TimeInterval = 30.0
    
    /// Minimum reconnect delay.
    private var minReconnectDelay: TimeInterval = 1.0
    
    /// Base reconnect delay for exponential backoff.
    private var baseReconnectDelay: TimeInterval = 1.0
    
    /// Maximum consecutive parse failures before entering degraded mode.
    /// Configurable to adapt to different network conditions.
    private var maxParseFailures: Int = 10
    
    /// Track parse failures for degradation detection.
    private var parseFailures = 0
    
    /// Maximum SSE data buffer length to prevent OOM crashes.
    private var maxSSEBufferLength: Int = 5 * 1024 * 1024
    
    /// Connection health metrics for adaptive reconnection tuning.
    private(set) var connectionHealthMetrics = SSEConnectionHealthMetrics()
    
    /// Sliding-window deduplication cache for light state updates.
    /// Maps light resource ID to the most recent state hash. When a new event
    /// arrives with an identical hash, it's skipped to prevent buffer thrashing
    /// during rapid bridge firmware updates or large ecosystem sync bursts (60+ lights).
    /// The cache is keyed by light ID, with the hash being a compact representation
    /// of the light's on/brightness/color state.
    private var deduplicationCache: [String: UInt64] = [:]
    
    /// Maximum size of the deduplication cache to prevent unbounded growth.
    /// For a 60+ light ecosystem, this provides per-light deduplication without
    /// consuming excessive memory. Configurable via `Configuration.maxDedupCacheSize`.
    private var maxDedupCacheSize: Int = 256
    
    /// Configuration for SSE connection behavior.
    struct Configuration: Sendable {
        /// Maximum consecutive parse failures before entering degraded mode.
        var maxParseFailures: Int = 10

        /// Base reconnect delay in seconds.
        var baseReconnectDelay: TimeInterval = 1.0

        /// Maximum reconnect delay in seconds.
        var maxReconnectDelay: TimeInterval = 30.0

        /// Minimum reconnect delay in seconds.
        var minReconnectDelay: TimeInterval = 1.0

        /// Whether to enable connection health metrics tracking.
        var trackHealthMetrics: Bool = true

        /// Maximum SSE data buffer length in bytes to prevent OOM crashes.
        /// If the accumulated buffer exceeds this limit, the stream enters
        /// degraded mode to protect against unbounded memory growth.
        var maxSSEBufferLength: Int = 5 * 1024 * 1024

        /// Maximum size of the sliding-window deduplication cache.
        /// Prevents unbounded memory growth in large ecosystems (60+ lights)
        /// while still providing effective deduplication for recent events.
        var maxDedupCacheSize: Int = 256

        static let `default` = Configuration()
    }
    
    /// Connection health metrics for adaptive reconnection tuning.
    struct SSEConnectionHealthMetrics: Sendable {
        /// Average time between successful event parses (in seconds).
        var averageEventInterval: TimeInterval = 0.0
        
        /// Number of events successfully parsed.
        var eventsParsed: Int = 0
        
        /// Number of consecutive parse failures.
        var consecutiveParseFailures: Int = 0
        
        /// Timestamp of the last successful event parse.
        var lastEventTimestamp: Date?
        
        /// Whether the connection appears healthy based on event frequency.
        var isHealthy: Bool {
            if eventsParsed == 0 { return true }
            guard let lastEventTimestamp else { return false }
            return Date().timeIntervalSince(lastEventTimestamp) < 60.0
        }
    }
    
    /// TOFU callback for certificate pinning.
    private var tofuCallback: @Sendable (Data) async -> Void = { _ in }
    
    /// Callback for pin mismatch events during SSE connection.
    private var onPinMismatch: @Sendable (Data, Data) async -> Void = { _, _ in }
    
    /// Saved connection parameters for reconnection.
    private var pendingReconnection: (url: URL, pinnedHash: Data?, keychainKey: String?, tofuCallback: @Sendable (Data) async -> Void)?
    
    // MARK: - Connection Management
    
    /// Start the SSE connection to the bridge event stream.
    func start(
        url: URL,
        pinnedHash: Data?,
        keychainKey: String?,
        tofuCallback: @escaping @Sendable (Data) async -> Void,
        onPinMismatch: @escaping @Sendable (Data, Data) async -> Void = { _, _ in }
    ) {
        guard state != .connected else {
            logger.debug("SSE stream already connected, ignoring start request")
            return
        }
        
        disconnect()
        
        self.tofuCallback = tofuCallback
        self.onPinMismatch = onPinMismatch
        self.pendingReconnection = (url: url, pinnedHash: pinnedHash, keychainKey: keychainKey, tofuCallback: tofuCallback)
        
        let sessionDelegate = CertificatePinningDelegate(
            pinnedHash: pinnedHash,
            keychainKey: keychainKey
        ) { [weak self] trustedHash in
            Task { [weak self] in
                await self?.tofuCallback(trustedHash)
            }
        } onPinMismatch: { [weak self] newHash, oldHash in
            Task { [weak self] in
                await self?.onPinMismatch(newHash, oldHash)
            }
        }
        
        urlSession = URLSession(
            configuration: .default,
            delegate: sessionDelegate,
            delegateQueue: nil
        )
        
        let session = urlSession
        
        sseTask = Task { [weak self, session] in
            guard let self else { return }
            
            do {
                var request = URLRequest(url: url)
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.setValue("keep-alive", forHTTPHeaderField: "Connection")
                request.timeoutInterval = 300
                
                guard let session else {
                    await handleDisconnect(error: HueError.invalidResponse)
                    return
                }
                
                let (bytes, response) = try await session.bytes(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    await handleDisconnect(error: HueError.invalidResponse)
                    return
                }
                
                await streamEventsIncrementally(from: bytes.lines)
                
            } catch {
                await handleDisconnect(error: error)
            }
        }
        
        state = .connected
        logger.info("SSE event stream started")
    }
    
    /// Set the event handler for parsed resource updates.
    func setEventHandler(_ handler: @escaping @Sendable (ResourceUpdate) -> Void) {
        onEvent = handler
    }
    
    /// Set the error handler for stream-level errors.
    func setErrorHandler(_ handler: @escaping @Sendable (any Error) -> Void) {
        onError = handler
    }

    /// Set the full sync required callback, triggered when the SSE buffer overflows.
    func setFullSyncRequiredHandler(_ handler: @escaping @Sendable () -> Void) {
        onFullSyncRequired = handler
    }
    
    /// Configure the SSE connection behavior with custom thresholds.
    func configure(_ configuration: Configuration) {
        self.maxParseFailures = configuration.maxParseFailures
        self.baseReconnectDelay = configuration.baseReconnectDelay
        self.maxReconnectDelay = configuration.maxReconnectDelay
        self.minReconnectDelay = configuration.minReconnectDelay
        self.maxSSEBufferLength = configuration.maxSSEBufferLength
        self.maxDedupCacheSize = configuration.maxDedupCacheSize
        logger.info("SSE configuration updated: maxParseFailures=\(configuration.maxParseFailures), baseDelay=\(String(format: "%.1f", configuration.baseReconnectDelay))s, maxBuffer=\(configuration.maxSSEBufferLength) bytes, dedupCache=\(configuration.maxDedupCacheSize)")
    }
    
    /// Get the current connection health metrics for monitoring.
    func healthMetrics() -> SSEConnectionHealthMetrics {
        connectionHealthMetrics
    }
    
    /// Pause the SSE stream, gracefully disconnecting and suspending
    /// reconnection attempts. This is called when the app enters the
    /// background to prevent unnecessary network activity and battery drain.
    func pause() {
        isPaused = true
        logger.info("SSE stream paused (app entered background)")
        disconnect()
    }
    
    /// Resume the SSE stream after being paused. Schedules a reconnection
    /// attempt if the stream was connected when paused.
    func resume() {
        isPaused = false
        logger.info("SSE stream resumed (app entered foreground)")
        // Reconnection will be triggered by HueClient.startEventStream()
        // which is called from the app lifecycle handler on foreground transition.
    }
    
    /// Stream SSE events incrementally from a line-by-line byte stream.
    /// Processes events in real-time without buffering the entire response.
    private func streamEventsIncrementally(from lines: any AsyncSequence<String, any Error>) async {
        sseDataBuffer = ""
        parseFailures = 0
        
        if connectionHealthMetrics.eventsParsed == 0 {
            connectionHealthMetrics.lastEventTimestamp = Date()
        }
        
        do {
            for try await line in lines {
                // Respect cancellation for clean teardown
                guard !Task.isCancelled else {
                    logger.info("SSE stream cancelled, tearing down")
                    sseDataBuffer = ""
                    state = .idle
                    return
                }
                
                // Skip empty lines (mark end of event or keep-alive)
                if line.isEmpty {
                    // Empty line marks end of a complete SSE event
                    if !sseDataBuffer.isEmpty {
                        let eventText = sseDataBuffer
                        sseDataBuffer = ""
                        
                        do {
                            try await parseAndDispatchEvent(eventText)
                        } catch {
                            parseFailures += 1
                            connectionHealthMetrics.consecutiveParseFailures += 1
                            if parseFailures >= maxParseFailures {
                                state = .degraded
                                logger.warning("Entered degraded mode after \(self.parseFailures) parse failures")
                            }
                        }
                    }
                    continue
                }
                
                // Accumulate data lines for multi-line SSE events
                if line.hasPrefix("data: ") {
                    let extracted = String(line.dropFirst(6))
                    sseDataBuffer += extracted + "\n"
                    
                    // Enforce buffer size limit to prevent OOM from unbounded growth
                    if sseDataBuffer.utf8.count > self.maxSSEBufferLength {
                        logger.warning("SSE data buffer exceeded \(self.maxSSEBufferLength) bytes, discarding buffer and entering degraded mode")
                        sseDataBuffer = ""
                        parseFailures = maxParseFailures
                        state = .degraded

                        // Emit FullSyncRequired to force a clean GET /resources fetch.
                        // This is the only way to recover if a massive burst of events
                        // corrupted the incremental stream.
                        onFullSyncRequired?()
                    }
                }
            }
        } catch {
            logger.error("SSE stream error during line iteration: \(error.localizedDescription)")
        }
        
        // Process any remaining buffered data after stream ends
        if !sseDataBuffer.isEmpty {
            try? await parseAndDispatchEvent(sseDataBuffer)
        }
        
        await resetReconnectDelay()
        state = .idle
    }
    
    /// Parse an SSE event and dispatch it to the event handler.
    /// Applies sliding-window deduplication to skip identical state updates
    /// within the current connection session, preventing buffer thrashing during
    /// rapid firmware updates or large ecosystem sync bursts.
    func parseAndDispatchEvent(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty || trimmed == "ping" {
            return
        }

        let decoder = JSONDecoder.hueDecoder
        guard let data = trimmed.data(using: .utf8) else { throw HueError.invalidResponse }
        let update = try decoder.decode(ResourceUpdate.self, from: data)

        // Deduplication check: compute a compact hash of light states and skip
        // if identical to the most recently seen state for each light. This
        // prevents redundant UI updates during rapid bridge firmware updates
        // or large sync bursts (60+ lights) that would otherwise flood the buffer.
        if let lights = update.lights {
            guard !areAllLightsDuplicate(lights) else {
                logger.debug("Skipping duplicate SSE event (all lights unchanged)")
                return
            }
            // Update cache with new state hashes
            for light in lights {
                deduplicationCache[light.id] = computeLightStateHash(light)
                // Evict oldest entries if cache exceeds maximum size
                if deduplicationCache.count > maxDedupCacheSize {
                    let keysToEvict = Array(deduplicationCache.keys).prefix(deduplicationCache.count - maxDedupCacheSize)
                    for key in keysToEvict {
                        deduplicationCache.removeValue(forKey: key)
                    }
                }
            }
        }

        parseFailures = 0
        connectionHealthMetrics.consecutiveParseFailures = 0
        connectionHealthMetrics.eventsParsed += 1
        connectionHealthMetrics.lastEventTimestamp = Date()

        let now = Date()
        if let lastTimestamp = connectionHealthMetrics.lastEventTimestamp,
           connectionHealthMetrics.eventsParsed > 1 {
            let interval = now.timeIntervalSince(lastTimestamp)
            let currentAvg = connectionHealthMetrics.averageEventInterval
            let weight = 1.0 / Double(connectionHealthMetrics.eventsParsed)
            connectionHealthMetrics.averageEventInterval = currentAvg + (interval - currentAvg) * weight
        }

        onEvent?(update)
    }

    /// Compute a compact hash of a light's state for deduplication.
    /// Hashes the on state, brightness, and color values to detect
    /// meaningful state changes while ignoring metadata noise.
    private func computeLightStateHash(_ light: HueLightResource) -> UInt64 {
        var hashValue = light.id.hashValue
        if let on = light.state.on {
            hashValue ^= on.hashValue & 0x01
        }
        if let brightness = light.state.brightness {
            hashValue ^= brightness.hashValue
        }
        if let xy = light.state.xy, xy.count >= 2 {
            hashValue ^= Int(xy[0] * 65535).hashValue
            hashValue ^= Int(xy[1] * 65535).hashValue
        }
        if let ct = light.state.ct {
            hashValue ^= ct.hashValue
        }
        return UInt64(hashValue)
    }

    /// Check if all lights in the update have identical state to the cached state.
    /// Returns true if every light's current state matches the deduplication cache,
    /// indicating this is a redundant update that can be safely skipped.
    private func areAllLightsDuplicate(_ lights: [HueLightResource]) -> Bool {
        guard !lights.isEmpty else { return false }

        for light in lights {
            let currentHash = computeLightStateHash(light)
            guard let cachedHash = deduplicationCache[light.id] else {
                // New light or first seen; not a duplicate
                return false
            }
            if currentHash != cachedHash {
                return false
            }
        }
        return true
    }
    
    /// Handle stream disconnection with state machine-driven reconnection.
    func handleDisconnect(error: any Error) async {
        logger.error("SSE stream error: \(error.localizedDescription)")
        
        onError?(error)
        
        // Transition to reconnecting state and schedule reconnection
        state = .reconnecting
        scheduleReconnection()
    }
    
    /// Schedule an exponential backoff reconnection.
    /// Respects the `isPaused` flag: if the app is in the background,
    /// reconnection attempts are suspended to conserve battery.
    private func scheduleReconnection() {
        // Exponential backoff: double the delay each time, capped at max
        reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)
        let delay = reconnectDelay
        let params = pendingReconnection
        
        reconnectTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            
            try? await Task.sleep(for: .seconds(delay))
            
            // Check if we were cancelled during the wait
            guard !Task.isCancelled else { return }
            
            // Respect pause state: do not reconnect while app is in background
            if await self.isPaused {
                await self.logger.debug("SSE reconnection skipped: stream is paused (app in background)")
                return
            }
            
            await self.logger.info("Attempting SSE reconnection (delay: \(String(format: "%.1f", delay))s)...")
            
            guard let params else {
                await self.logger.warning("SSE reconnection aborted: no saved connection parameters")
                return
            }
            
            await self.start(
                url: params.url,
                pinnedHash: params.pinnedHash,
                keychainKey: params.keychainKey,
                tofuCallback: params.tofuCallback
            )
        }
    }
    
    /// Reset the backoff delay after a successful reconnection attempt.
    func resetReconnectDelay() {
        reconnectDelay = minReconnectDelay
    }
    
    /// Disconnect from the SSE stream and reset state.
    func disconnect() {
        sseTask?.cancel()
        sseTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil

        // Explicitly invalidate the URLSession to release internal OS buffers
        // that can leak if the network drops ungracefully.
        urlSession?.invalidateAndCancel()
        urlSession = nil

        sseDataBuffer = ""
        reconnectDelay = minReconnectDelay
        parseFailures = 0
        connectionHealthMetrics.consecutiveParseFailures = 0
        // Clear deduplication cache on disconnect; cached state is no longer valid
        // after reconnection as the bridge may have processed commands during downtime.
        deduplicationCache.removeAll()
        state = .idle
        logger.info("SSE stream disconnected")
    }
}

enum SSEReconnectionState: Sendable {
    case idle
    case connecting
    case connected
    case reconnecting
    case degraded
}
