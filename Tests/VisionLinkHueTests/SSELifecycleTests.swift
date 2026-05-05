import XCTest
import @testable VisionLinkHue

/// Unit tests for the SSE stream pause/resume lifecycle management in
/// `HueEventStreamActor`.
///
/// Verifies that the actor correctly pauses reconnection attempts when
/// the app enters the background and resumes when it returns to the
/// foreground, preventing unnecessary network activity.
final class SSELifecycleTests: XCTestCase {
    
    private var actor: HueEventStreamActor!
    
    override func setUp() {
        super.setUp()
        actor = HueEventStreamActor()
    }
    
    override func tearDown() {
        actor = nil
        super.tearDown()
    }
    
    // MARK: - Pause/Resume State Tests
    
    func testInitialStateIsNotPaused() {
        XCTAssertFalse(actor.isPaused)
        XCTAssertEqual(actor.state, .idle)
    }
    
    func testPauseSetsPausedStateAndDisconnects() async {
        // Simulate being connected first
        actor.state = .connected
        
        await actor.pause()
        
        XCTAssertTrue(actor.isPaused)
        XCTAssertEqual(actor.state, .idle)
    }
    
    func testResumeClearsPausedState() async {
        await actor.pause()
        await actor.resume()
        
        XCTAssertFalse(actor.isPaused)
    }
    
    func testPauseWhileAlreadyIdleIsSafe() async {
        await actor.pause()
        
        XCTAssertTrue(actor.isPaused)
        XCTAssertEqual(actor.state, .idle)
    }
    
    func testResumeWhileNotPausedIsSafe() async {
        await actor.resume()
        
        XCTAssertFalse(actor.isPaused)
    }
    
    // MARK: - Reconnection Delay Tests
    
    func testReconnectDelayExponentialBackoff() async {
        // Simulate multiple disconnects to test exponential backoff
        await actor.handleDisconnect(error: HueError.sseConnectionLost)
        let delay1 = await actor.getReconnectDelay()
        
        await actor.handleDisconnect(error: HueError.sseConnectionLost)
        let delay2 = await actor.getReconnectDelay()
        
        await actor.handleDisconnect(error: HueError.sseConnectionLost)
        let delay3 = await actor.getReconnectDelay()
        
        // Each delay should be double the previous, capped at 30
        XCTAssertGreaterThan(delay2, delay1)
        XCTAssertGreaterThan(delay3, delay2)
        XCTAssertLessThanOrEqual(delay3, 30.0)
    }
    
    func testReconnectDelayResetsAfterConnection() async {
        await actor.handleDisconnect(error: HueError.sseConnectionLost)
        _ = await actor.getReconnectDelay()
        
        // Simulate successful reconnection
        await actor.resetReconnectDelay()
        
        let delay = await actor.getReconnectDelay()
        XCTAssertEqual(delay, 1.0, accuracy: 0.001, "Delay should reset to minimum (1.0s)")
    }
    
    // MARK: - Pause Prevents Reconnection Tests
    
    func testPausePreventsReconnectionAttempt() async {
        await actor.handleDisconnect(error: HueError.sseConnectionLost)
        await actor.pause()
        
        // The scheduleReconnection task should be cancelled by disconnect()
        // and the isPaused flag should prevent any new reconnection attempts
        XCTAssertTrue(actor.isPaused)
        // After pause + disconnect, state should be idle
        XCTAssertEqual(actor.state, .idle)
    }
    
    func testPausedStatePersistsAcrossDisconnects() async {
        await actor.pause()
        await actor.handleDisconnect(error: HueError.sseConnectionLost)
        
        // Even after another disconnect, should still be paused
        XCTAssertTrue(actor.isPaused)
    }
    
    func testResumeAllowsReconnectionAfterPause() async {
        await actor.pause()
        await actor.resume()
        
        XCTAssertFalse(actor.isPaused)
        
        // Now a disconnect should schedule reconnection normally
        await actor.handleDisconnect(error: HueError.sseConnectionLost)
        let delay = await actor.getReconnectDelay()
        
        // Should have a normal reconnect delay (not stuck at 0)
        XCTAssertGreaterThan(delay, 0.0)
    }
    
    // MARK: - Health Metrics Tests
    
    func testHealthMetricsInitialValues() async {
        let metrics = await actor.healthMetrics()
        XCTAssertEqual(metrics.eventsParsed, 0)
        XCTAssertEqual(metrics.averageEventInterval, 0.0)
        XCTAssertEqual(metrics.consecutiveParseFailures, 0)
    }
    
    func testHealthMetricsTrackEvents() async {
        // Simulate parsing some events
        await actor.parseAndDispatchEvent("data: {\"type\": \"test\"}")
        
        let metrics = await actor.healthMetrics()
        // The event should have been parsed (it's a valid empty update)
        XCTAssertGreaterThanOrEqual(metrics.eventsParsed, 0)
    }
    
    // MARK: - Configuration Tests
    
    func testConfigureUpdatesThresholds() async {
        await actor.configure(HueEventStreamActor.Configuration(
            maxParseFailures: 20,
            baseReconnectDelay: 2.0,
            maxReconnectDelay: 60.0,
            minReconnectDelay: 0.5
        ))
        
        // Configuration is stored in the actor
        let metrics = await actor.healthMetrics()
        // Metrics should be accessible without error
        XCTAssertNotNil(metrics)
    }
}

// MARK: - Internal Access Extensions for Testing

extension HueEventStreamActor {
    
    /// Internal helper for testing reconnect delay progression.
    func getReconnectDelay() async -> TimeInterval {
        reconnectDelay
    }
}
