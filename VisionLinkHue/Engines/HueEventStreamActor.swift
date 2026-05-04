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
    
    /// Whether the stream is currently connected and receiving events.
    var isConnected: Bool { state == .connected }
    
    /// Event handler for parsed resource updates from the bridge.
    var onEvent: (@Sendable (ResourceUpdate) -> Void)?
    
    /// Error handler for stream-level errors.
    var onError: (@Sendable (any Error) -> Void)?
    
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
    private var reconnectDelay: TimeInterval = 1.0
    
    /// Maximum reconnect delay.
    private let maxReconnectDelay: TimeInterval = 30.0
    
    /// Minimum reconnect delay.
    private let minReconnectDelay: TimeInterval = 1.0
    
    /// Maximum consecutive parse failures before entering degraded mode.
    private let maxParseFailures = 10
    
    /// Track parse failures for degradation detection.
    private var parseFailures = 0
    
    /// TOFU callback for certificate pinning.
    private var tofuCallback: @Sendable (Data) async -> Void = { _ in }
    
    /// Saved connection parameters for reconnection.
    private var pendingReconnection: (url: URL, pinnedHash: Data?, keychainKey: String?, tofuCallback: @Sendable (Data) async -> Void)?
    
    // MARK: - Connection Management
    
    /// Start the SSE connection to the bridge event stream.
    func start(
        url: URL,
        pinnedHash: Data?,
        keychainKey: String?,
        tofuCallback: @escaping @Sendable (Data) async -> Void
    ) {
        guard state != .connected else {
            logger.debug("SSE stream already connected, ignoring start request")
            return
        }
        
        disconnect()
        
        self.tofuCallback = tofuCallback
        self.pendingReconnection = (url: url, pinnedHash: pinnedHash, keychainKey: keychainKey, tofuCallback: tofuCallback)
        
        let sessionDelegate = CertificatePinningDelegate(
            pinnedHash: pinnedHash,
            keychainKey: keychainKey
        ) { [weak self] trustedHash in
            Task { [weak self] in
                await self?.tofuCallback(trustedHash)
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
    
    /// Stream SSE events incrementally from a line-by-line byte stream.
    /// Processes events in real-time without buffering the entire response.
    private func streamEventsIncrementally(from lines: any AsyncSequence<String, any Error>) async {
        sseDataBuffer = ""
        parseFailures = 0
        
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
                    sseDataBuffer += String(line.dropFirst(6)) + "\n"
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
    private func parseAndDispatchEvent(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmed.isEmpty || trimmed == "ping" {
            return
        }
        
        let decoder = JSONDecoder()
        guard let data = trimmed.data(using: .utf8) else { throw HueError.invalidResponse }
        let update = try decoder.decode(ResourceUpdate.self, from: data)
        
        parseFailures = 0
        
        onEvent?(update)
    }
    
    /// Handle stream disconnection with state machine-driven reconnection.
    private func handleDisconnect(error: any Error) async {
        logger.error("SSE stream error: \(error.localizedDescription)")
        
        onError?(error)
        
        // Transition to reconnecting state and schedule reconnection
        state = .reconnecting
        scheduleReconnection()
    }
    
    /// Schedule an exponential backoff reconnection.
    private func scheduleReconnection() {
        // Exponential backoff: double the delay each time, capped at max
        reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)
        let delay = reconnectDelay
        let params = pendingReconnection
        
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            
            try? await Task.sleep(for: .seconds(delay))
            
            // Check if we were cancelled during the wait
            guard !Task.isCancelled else { return }
            
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
    private func resetReconnectDelay() {
        reconnectDelay = minReconnectDelay
    }
    
    /// Disconnect from the SSE stream and reset state.
    func disconnect() {
        sseTask?.cancel()
        sseTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        urlSession = nil
        sseDataBuffer = ""
        reconnectDelay = minReconnectDelay
        parseFailures = 0
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
