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
    var onEvent: ((ResourceUpdate) async -> Void)?
    
    /// Error handler for stream-level errors.
    var onError: ((any Error) async -> Void)?
    
    // MARK: - Private State
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "HueEventStream"
    )
    
    /// The active URL session for the SSE connection.
    private var urlSession: URLSession?
    
    /// The active SSE parsing task (holds the stream for cancellation).
    private var sseTask: Task<Void, Never>?
    
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
        
        sseTask = Task { [weak self] in
            guard let self else { return }
            
            do {
                var request = URLRequest(url: url)
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.setValue("keep-alive", forHTTPHeaderField: "Connection")
                request.timeoutInterval = 300
                
                guard let urlSession else {
                    await handleDisconnect(error: HueError.invalidResponse)
                    return
                }
                let (data, response) = try await urlSession.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    await handleDisconnect(error: HueError.invalidResponse)
                    return
                }
                
                await streamEvents(from: data)
                
            } catch {
                await handleDisconnect(error: error)
            }
        }
        
        state = .connected
        logger.info("SSE event stream started")
    }
    
    /// Set the event handler for parsed resource updates.
    func setEventHandler(_ handler: @escaping @Sendable ((ResourceUpdate) async -> Void)) {
        onEvent = handler
    }
    
    /// Set the error handler for stream-level errors.
    func setErrorHandler(_ handler: @escaping @Sendable ((any Error) async -> Void)) {
        onError = handler
    }
    
    /// Stream SSE events from the data.
    private func streamEvents(from data: Data) async {
        sseDataBuffer = ""
        parseFailures = 0
        
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\n")
        
        for line in lines {
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
                sseDataBuffer += String(line.dropFirst(6))
            }
        }
        
        // Process any remaining buffered data after stream ends
        if !sseDataBuffer.isEmpty {
            try? await parseAndDispatchEvent(sseDataBuffer)
        }
        
        state = .idle
    }
    
    /// Parse an SSE event and dispatch it to the event handler.
    private func parseAndDispatchEvent(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmed.isEmpty || trimmed == "ping" {
            return
        }
        
        let decoder = JSONDecoder()
        let update = try decoder.decode(ResourceUpdate.self, from: trimmed.data(using: .utf8)!)
        
        await onEvent?(update)
    }
    
    /// Handle stream disconnection with state machine-driven reconnection.
    private func handleDisconnect(error: any Error) async {
        logger.error("SSE stream error: \(error.localizedDescription)")
        
        await onError?(error)
        
        // Transition to reconnecting state and schedule reconnection
        state = .reconnecting
        scheduleReconnection()
    }
    
    /// Schedule an exponential backoff reconnection.
    private func scheduleReconnection() {
        // Exponential backoff: double the delay each time, capped at max
        reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)
        let delay = reconnectDelay
        
        Task { [weak self] in
            guard let self else { return }
            
            try? await Task.sleep(for: .seconds(delay))
            
            // Check if we were cancelled during the wait
            guard !Task.isCancelled else { return }
            
            await self.logger.info("Attempting SSE reconnection (delay: \(String(format: "%.1f", delay))s)...")
        }
    }
    
    /// Disconnect from the SSE stream and reset state.
    func disconnect() {
        sseTask?.cancel()
        sseTask = nil
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
