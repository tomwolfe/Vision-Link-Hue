import SwiftUI
import ARKit

/// Centralized dependency injection container for the application.
/// Initializes all core services once at app launch and provides
/// deterministic access to dependencies throughout the view hierarchy.
///
/// This eliminates manual dependency instantiation in `ContentView.init()`
/// and makes each view testable in isolation with mock dependencies.
@MainActor
final class AppContainer {
    
    static let shared = AppContainer()
    
    let stateStream: HueStateStream
    let hueClient: HueClient
    let detectionEngine: DetectionEngine
    let arSessionManager: ARSessionManager
    let spatialProjector: SpatialProjector
    
    private init() {
        let persistence = FixturePersistence.shared
        let stream = HueStateStream(persistence: persistence)
        stream.configure()
        
        let client = HueClient(stateStream: stream)
        client.spatialService?.setHueClient(client)
        
        let detector = DetectionEngine()
        let projector = SpatialProjector()
        let manager = ARSessionManager(
            detectionEngine: detector,
            spatialProjector: projector,
            hueClient: client,
            stateStream: stream
        )
        
        // Wire up calibration persistence to the spatial service's engine
        let keychainManager = KeychainManager()
        let calibrationStore = KeychainCalibrationStore(keychainManager: keychainManager)
        client.spatialService?.calibrationEngine.persistenceStore = calibrationStore
        
        self.stateStream = stream
        self.hueClient = client
        self.detectionEngine = detector
        self.arSessionManager = manager
        self.spatialProjector = projector
    }
}
