import Foundation
import simd
#if canImport(ARKit)
import ARKit
#endif

/// Lightweight camera intrinsics for use on both device and simulator.
/// Mirrors `ARCamera.Intrinsics` which is unavailable on the simulator SDK.
struct CameraIntrinsics {
    let k0: Float
    let k4: Float
    let k2: Float
    let k5: Float
    
    init(k0: Float, k4: Float, k2: Float, k5: Float) {
        self.k0 = k0
        self.k4 = k4
        self.k2 = k2
        self.k5 = k5
    }
    
    #if !targetEnvironment(simulator)
    init(_ intrinsics: ARCamera.Intrinsics) {
        self.k0 = Float(intrinsics.k0)
        self.k4 = Float(intrinsics.k4)
        self.k2 = Float(intrinsics.k2)
        self.k5 = Float(intrinsics.k5)
    }
    #endif
}

/// Stateless utility for spatial coordinate transforms used by the AR projector.
/// All methods are pure functions suitable for unit testing.
enum SpatialMath {
    
    #if !targetEnvironment(simulator)
    /// Convert normalized [0,1] coordinates to a camera-space ray using intrinsics.
    static func cameraRay(
        normalized: SIMD2<Float>,
        intrinsics: ARCamera.Intrinsics,
        cameraTransform: simd_float4x4,
        imageSize: CGSize
    ) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        let fx = Float(intrinsics.k0)
        let fy = Float(intrinsics.k4)
        let cx = Float(intrinsics.k2)
        let cy = Float(intrinsics.k5)
        
        let pixelX = normalized.x * Float(imageSize.width)
        let pixelY = normalized.y * Float(imageSize.height)
        
        let dirX = (pixelX - cx) / fx
        let dirY = (pixelY - cy) / fy
        
        var direction = SIMD3<Float>(dirX, dirY, 1.0)
        direction = normalize(direction)
        
        let rotationMatrix = rotationMatrix(from: cameraTransform)
        direction = rotationMatrix * direction
        
        let cameraPos = translation(from: cameraTransform)
        
        return (origin: cameraPos, direction: direction)
    }
    #endif
    
    /// Convert normalized [0,1] coordinates to a camera-space ray using intrinsics.
    /// Simulator-compatible version using lightweight CameraIntrinsics.
    static func cameraRay(
        normalized: SIMD2<Float>,
        intrinsics: CameraIntrinsics,
        cameraTransform: simd_float4x4,
        imageSize: CGSize
    ) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        let fx = intrinsics.k0
        let fy = intrinsics.k4
        let cx = intrinsics.k2
        let cy = intrinsics.k5
        
        let pixelX = normalized.x * Float(imageSize.width)
        let pixelY = normalized.y * Float(imageSize.height)
        
        let dirX = (pixelX - cx) / fx
        let dirY = (pixelY - cy) / fy
        
        var direction = SIMD3<Float>(dirX, dirY, 1.0)
        direction = normalize(direction)
        
        let rotationMatrix = rotationMatrix(from: cameraTransform)
        direction = rotationMatrix * direction
        
        let cameraPos = translation(from: cameraTransform)
        
        return (origin: cameraPos, direction: direction)
    }
    
    #if !targetEnvironment(simulator)
    /// Unproject a normalized 2D point into a camera-space direction vector.
    static func unprojectDirection(
        normalized: SIMD2<Float>,
        intrinsics: ARCamera.Intrinsics?,
        cameraTransform: simd_float4x4
    ) -> SIMD3<Float>? {
        guard let intrinsics else {
            return normalize(normalize(rotationMatrix(from: cameraTransform) * SIMD3<Float>(0, 0, -1)))
        }
        
        let fx = Float(intrinsics.k0)
        let fy = Float(intrinsics.k4)
        let cx = Float(intrinsics.k2)
        let cy = Float(intrinsics.k5)
        
        let dirX = (normalized.x - cx)
        let dirY = (normalized.y - cy)
        
        var direction = SIMD3<Float>(dirX, dirY, 1.0)
        direction = normalize(direction)
        
        let rotationMatrix = rotationMatrix(from: cameraTransform)
        return normalize(rotationMatrix * direction)
    }
    #endif
    
    /// Simulator-compatible unproject using lightweight CameraIntrinsics.
    static func unprojectDirection(
        normalized: SIMD2<Float>,
        intrinsics: CameraIntrinsics?,
        cameraTransform: simd_float4x4
    ) -> SIMD3<Float>? {
        guard let intrinsics else {
            return normalize(normalize(rotationMatrix(from: cameraTransform) * SIMD3<Float>(0, 0, -1)))
        }
        
        let fx = intrinsics.k0
        let fy = intrinsics.k4
        let cx = intrinsics.k2
        let cy = intrinsics.k5
        
        let dirX = (normalized.x - cx)
        let dirY = (normalized.y - cy)
        
        var direction = SIMD3<Float>(dirX, dirY, 1.0)
        direction = normalize(direction)
        
        let rotationMatrix = rotationMatrix(from: cameraTransform)
        return normalize(rotationMatrix * direction)
    }
    
    #if !targetEnvironment(simulator)
    /// Unproject a pixel coordinate with depth into a world-space position.
    static func depthUnproject(
        pixelX: Int,
        pixelY: Int,
        depthMeters: Float,
        intrinsics: ARCamera.Intrinsics,
        cameraTransform: simd_float4x4,
        imageWidth: Int,
        imageHeight: Int
    ) -> SIMD3<Float>? {
        let clampedPx = min(max(pixelX, 0), imageWidth - 1)
        let clampedPy = min(max(pixelY, 0), imageHeight - 1)
        
        let fx = Float(intrinsics.k0)
        let fy = Float(intrinsics.k4)
        let cx = Float(intrinsics.k2)
        let cy = Float(intrinsics.k5)
        
        let pixelXf = Float(clampedPx)
        let pixelYf = Float(clampedPy)
        
        let dirX = (pixelXf - cx) / fx
        let dirY = (pixelYf - cy) / fy
        
        let direction = SIMD3<Float>(dirX, dirY, 1.0)
        let rotationMatrix = rotationMatrix(from: cameraTransform)
        let rotatedDirection = rotationMatrix * direction
        
        let cameraPosition = translation(from: cameraTransform)
        return cameraPosition + rotatedDirection * depthMeters
    }
    #endif
    
    /// Simulator-compatible depth unproject using lightweight CameraIntrinsics.
    static func depthUnproject(
        pixelX: Int,
        pixelY: Int,
        depthMeters: Float,
        intrinsics: CameraIntrinsics,
        cameraTransform: simd_float4x4,
        imageWidth: Int,
        imageHeight: Int
    ) -> SIMD3<Float>? {
        let clampedPx = min(max(pixelX, 0), imageWidth - 1)
        let clampedPy = min(max(pixelY, 0), imageHeight - 1)
        
        let fx = intrinsics.k0
        let fy = intrinsics.k4
        let cx = intrinsics.k2
        let cy = intrinsics.k5
        
        let pixelXf = Float(clampedPx)
        let pixelYf = Float(clampedPy)
        
        let dirX = (pixelXf - cx) / fx
        let dirY = (pixelYf - cy) / fy
        
        let direction = SIMD3<Float>(dirX, dirY, 1.0)
        let rotationMatrix = rotationMatrix(from: cameraTransform)
        let rotatedDirection = rotationMatrix * direction
        
        let cameraPosition = translation(from: cameraTransform)
        return cameraPosition + rotatedDirection * depthMeters
    }
    
    /// Compute a fallback 3D position at a fixed distance along camera frustum.
    static func fallbackPosition(
        normalized: SIMD2<Float>,
        cameraTransform: simd_float4x4,
        distance: Float
    ) -> SIMD3<Float> {
        let cameraPos = translation(from: cameraTransform)
        let rotation = rotationMatrix(from: cameraTransform)
        
        let forward = normalize(rotation * SIMD3<Float>(0, 0, -1))
        let horizontal = normalize(rotation * SIMD3<Float>(1, 0, 0))
        let vertical = normalize(rotation * SIMD3<Float>(0, 1, 0))
        
        let offset = SIMD3<Float>(
            (normalized.x - 0.5) * 2.0,
            (normalized.y - 0.5) * 2.0,
            0
        )
        
        let direction = forward + horizontal * offset.x + vertical * offset.y
        return cameraPos + normalize(direction) * distance
    }
    
    /// Construct a look-at orientation quaternion.
    /// Returns nil if worldUp and forward are parallel (singularity).
    static func lookAt(from: SIMD3<Float>, at: SIMD3<Float>, worldUp: SIMD3<Float>) -> simd_quatf {
        let forward = normalize(at - from)
        let right = normalize(cross(worldUp, forward))
        let up = cross(forward, right)
        
        let rotationMatrix = simd_float3x3(
            right,
            up,
            -forward
        )
        
        return simd_quatf(rotationMatrix)
    }
    
    /// Construct a look-at orientation quaternion, returning nil on singularity.
    /// Use this when worldUp alignment cannot be guaranteed (e.g., camera pointing straight up/down).
    static func lookAtSafe(from: SIMD3<Float>, at: SIMD3<Float>, worldUp: SIMD3<Float>) -> simd_quatf? {
        let forward = normalize(at - from)
        let crossProduct = cross(worldUp, forward)
        
        let crossLength = length(crossProduct)
        guard crossLength > 1e-6 else {
            return nil
        }
        
        let right = normalize(crossProduct)
        let up = cross(forward, right)
        
        let rotationMatrix = simd_float3x3(
            right,
            up,
            -forward
        )
        
        return simd_quatf(rotationMatrix)
    }
    
    /// Extract the 3x3 rotation matrix from a 4x4 transform.
    /// Uses native simd_float4x4 accessors available since iOS 19/26.
    static func rotationMatrix(from transform: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        )
    }
    
    static func translation(from transform: simd_float4x4) -> SIMD3<Float> {
        SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }
}
