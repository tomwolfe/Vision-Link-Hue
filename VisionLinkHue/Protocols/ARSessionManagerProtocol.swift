import ARKit
import RealityKit
import simd

/// Protocol abstraction for AR session management.
/// Enables mocking in unit tests and decouples AR logic from UI layers.
protocol ARSessionManagerProtocol: AnyObject, Sendable {
    
    /// Whether the AR session is currently active.
    var isSessionActive: Bool { get }
    
    /// Number of currently anchored fixtures.
    var anchorCount: Int { get }
    
    /// Timestamp of the last processed frame.
    var frameTimestamp: TimeInterval { get }
    
    /// Current tracking state.
    var trackingState: ARTrackingState { get }
    
    /// Whether a world map is available for raycasting.
    var worldMapAvailable: Bool { get }
    
    /// Currently tracked fixtures.
    var trackedFixtures: [TrackedFixture] { get }
    
    /// Root anchor for all AR content.
    var rootAnchor: AnchorEntity.World? { get }
    
    /// Configure and start the AR session with scene reconstruction.
    func configureAndStart(in arView: ARView) async
    
    /// Pause the AR session.
    func pause()
    
    /// Reset tracking and restart.
    func resetTracking() async
    
    /// Process a new AR frame for detection.
    func didUpdateFrame(_ frame: ARFrame) async
    
    /// Create a HUD entity for a fixture in the RealityKit scene.
    func createHUD(for fixture: TrackedFixture, in scene: RealityKit.Scene) async
    
    /// Remove a fixture and its HUD from the scene.
    func removeFixture(_ fixtureId: UUID)
    
    /// Clear all fixtures from the scene.
    func clearAllFixtures()
    
    /// Get the Hue light group ID that corresponds to a fixture.
    func resolveHueGroup(for fixture: TrackedFixture) -> String?
}
