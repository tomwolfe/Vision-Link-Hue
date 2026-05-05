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
    
    /// Returns the world reconstruction mode for the current environment.
    var worldReconstructionMode: Int? { get }
    
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
        if let frame, let intrinsics = frame.camera.intrinsics {
            return CameraIntrinsics(intrinsics)
        }
        #endif
        return CameraIntrinsics(k0: 1.0, k4: 1.0, k2: 0.5, k5: 0.5)
    }
    
    var worldReconstructionMode: Int? {
        #if !targetEnvironment(simulator)
        if #available(iOS 26, *) {
            return 1
        }
        return nil
        #else
        return nil
        #endif
    }
    
    func makeWorldAnchor() -> AnchorEntity {
        #if !targetEnvironment(simulator)
        if #available(iOS 26, *) {
            return AnchorEntity.world()
        }
        return AnchorEntity()
        #else
        return AnchorEntity()
        #endif
    }
}

/// Provides the default plane detection configuration for the current environment.
extension ARWorldTrackingConfiguration {
    func configuredWithEnvironment() -> ARWorldTrackingConfiguration {
        #if !targetEnvironment(simulator)
        if #available(iOS 26, *) {
            self.worldReconstructionMode = .automatic
            self.lightEstimation = .automatic
        }
        #endif
        self.planeDetection = [.horizontal, .vertical]
        return self
    }
}
