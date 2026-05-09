import Foundation
import simd

/// Protocol abstraction for Hue bridge communication.
/// Enables mocking in unit tests and decouples networking from UI layers.
@MainActor
protocol HueClientProtocol: AnyObject {
    
    /// The IP address of the connected bridge.
    var bridgeIP: String? { get }
    
    /// The port of the connected bridge.
    var bridgePort: Int { get }
    
    /// The authenticated API key (username).
    var apiKey: String? { get }
    
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
    
    /// Toggle power state for a specific group.
    func togglePower(groupId: String, on: Bool) async throws
    
    /// Set brightness for a specific group.
    func setBrightness(groupId: String, brightness: Int, transitionDuration: Int) async throws
    
    /// Set color temperature for a specific group.
    func setColorTemperature(groupId: String, mireds: Int, transitionDuration: Int) async throws
    
    /// Set XY color for a specific group.
    
    /// Sync AR-detected fixture positions back to the Hue Bridge.
    func syncSpatialAwareness(fixtures: [SpatialAwarePosition]) async throws
    
    /// Sync a single fixture's spatial awareness data.
    func syncSpatialAwareness(fixture: SpatialAwarePosition) async throws
    
    /// Get current spatial awareness data from the bridge.
    func fetchSpatialAwareness() async throws -> [SpatialAwarePosition]
    
    /// Verify firmware compatibility for SpatialAware features before sync.
    func verifySpatialAwareCompatibility() async throws -> BridgeSpatialInfo
    
    /// Map ARKit local space coordinates to Bridge Room Space coordinates.
    func mapARKitToBridgeSpace(arKitPosition: SIMD3<Float>, arKitOrientation: simd_quatf, referencePoint: SIMD3<Float>?) -> (position: SpatialAwarePosition.Position3D, roomOffset: SpatialAwarePosition.RoomOffset?)
    
    /// Create a full SpatialAwarePosition from ARKit detection data with room-relative mapping.
    func createSpatialAwarePosition(context: DetectionContext) -> SpatialAwarePosition
    
    /// Whether a valid 3+ point calibration has been established.
    var isCalibrated: Bool { get }
    
    /// Check if the connected bridge supports SpatialAware features.
    var isSpatialAwareSupported: Bool { get }
    
    /// Start the SSE connection to the bridge event stream.
    func startEventStream()
    
    /// Disconnect from the bridge.
    func disconnect()
    
    /// Reconnect to the bridge (re-authenticate and restart SSE).
    func reconnect() async
    
    // MARK: - Matter Fallback
    
    /// Whether Matter fallback is available as an alternative control path.
    var isMatterFallbackAvailable: Bool { get }
    
    /// Get the preferred control path based on current availability.
    var preferredControlPath: ControlPath { get async }
    
    /// Fetch Matter device state when Hue Bridge is unavailable.
    func fetchMatterDevices() async throws -> MatterBridgeState
    
    /// Set power for a Matter light device (fallback path).
    func setMatterPower(deviceId: String, on: Bool) async throws
    
    /// Set brightness for a Matter light device (fallback path).
    func setMatterBrightness(deviceId: String, brightness: Int, transitionDuration: Int) async throws
    
    /// Set color temperature for a Matter light device (fallback path).
    func setMatterColorTemperature(deviceId: String, mireds: Int, transitionDuration: Int) async throws
    
    /// Set XY color for a Matter light device (fallback path).
    func setMatterColorXY(deviceId: String, x: Double, y: Double, transitionDuration: Int) async throws
    
    /// Patch a Matter light with multiple state changes (fallback path).
    func patchMatterLight(deviceId: String, patch: MatterLightStatePatch) async throws
}
