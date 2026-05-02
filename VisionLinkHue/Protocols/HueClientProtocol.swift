import Foundation

/// Protocol abstraction for Hue bridge communication.
/// Enables mocking in unit tests and decouples networking from UI layers.
protocol HueClientProtocol: AnyObject, Sendable {
    
    /// The IP address of the connected bridge.
    var bridgeIP: String? { get }
    
    /// The port of the connected bridge.
    var bridgePort: Int { get }
    
    /// The authenticated API key (username).
    var apiKey: String? { get }
    
    /// Last error message, if any.
    var lastError: String? { get }
    
    /// Discover Hue bridges on the local network using mDNS.
    func discoverBridges() async -> [BridgeInfo]
    
    /// Create a new developer session (API key) on the bridge.
    func createApiKey() async throws -> String
    
    /// Get the current bridge state (lights, scenes, groups).
    func fetchState() async throws -> HueBridgeState
    
    /// Patch light state via CLIP v2 API.
    func patchLightState(resourceId: String, state: LightStatePatch) async throws
    
    /// Recall a scene via CLIP v2 API.
    func recallScene(groupId: String, sceneId: String) async throws
    
    /// Set brightness for a light or group resource.
    func setBrightness(resourceId: String, brightness: Int, transitionDuration: Int) async throws
    
    /// Set color temperature for a light or group resource.
    func setColorTemperature(resourceId: String, mireds: Int, transitionDuration: Int) async throws
    
    /// Set XY color for a light or group resource.
    func setColorXY(resourceId: String, x: Double, y: Double, transitionDuration: Int) async throws
    
    /// Toggle power state for a light or group resource.
    func togglePower(resourceId: String, on: Bool) async throws
    
    /// Start the SSE connection to the bridge event stream.
    func startEventStream()
    
    /// Disconnect from the bridge.
    func disconnect()
    
    /// Reconnect to the bridge (re-authenticate and restart SSE).
    func reconnect() async
}
