import ARKit
import RealityKit
import Foundation

/// Protocol for providing camera configuration based on the runtime
/// target environment (device vs. simulator). Centralizes all
/// `#if !targetEnvironment(simulator)` conditionals to improve
/// readability and reduce duplication.
protocol CameraConfigurationProvider {
    /// Returns device intrinsics on real hardware, simulator fallback on simulator.
    var intrinsics: CameraIntrinsics { get }
    
    /// Returns the appropriate anchor type for the current environment.
    func makeWorldAnchor() -> AnchorEntity
}

/// Default implementation that provides device intrinsics on real hardware
/// and simulator-safe fallback values on the simulator.
final class DefaultCameraConfigurationProvider: CameraConfigurationProvider {
    
    private let frame: ARFrame?
    
    init(frame: ARFrame? = nil) {
        self.frame = frame
    }
    
    var intrinsics: CameraIntrinsics {
        #if !targetEnvironment(simulator)
        if let frame {
            return CameraIntrinsics(frame.camera.intrinsics)
        }
        #endif
        return CameraIntrinsics(k0: 1.0, k4: 1.0, k2: 0.5, k5: 0.5)
    }
    
    func makeWorldAnchor() -> AnchorEntity {
        AnchorEntity()
    }
}

/// Provides the default plane detection configuration for the current environment.
extension ARWorldTrackingConfiguration {
    func configuredWithEnvironment() -> ARWorldTrackingConfiguration {
        self.planeDetection = [.horizontal, .vertical]
        
        // Enable scene reconstruction for raycasting against the mesh (when available)
        // Scene reconstruction requires LiDAR-capable devices; omitted for compatibility
        
        return self
    }
}
