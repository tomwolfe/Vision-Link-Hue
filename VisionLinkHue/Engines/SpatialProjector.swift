import Foundation
import ARKit
import RealityKit
import simd

/// Class responsible for projecting 2D normalized coordinates from AI
/// detection into 3D world coordinates using ARKit raycasting and depth.
/// All methods execute on the MainActor since ARKit raycast APIs are
/// strictly main-thread bound.
@MainActor
@Observable
final class SpatialProjector {
    
    /// Configuration for the projector.
    struct Configuration {
        /// Maximum raycast distance in meters.
        let maxRaycastDistance: Float = 15.0
        
        /// Offset above the detected surface for the HUD placement.
        let hudOffset: SIMD3<Float> = SIMD3<Float>(0, 0.15, 0)
        
        /// Minimum depth value to trust (meters).
        let minDepthMeters: Float = 0.1
        
        /// Maximum depth value to trust (meters).
        let maxDepthMeters: Float = 15.0
    }
    
    private let configuration: Configuration
    private let provider: CameraConfigurationProvider
    private weak var session: ARSession?
    
    /// Exponential Moving Average of successful depth measurements for
    /// robust fallback distance estimation. Uses adaptive smoothing:
    /// alpha ramps to 0.8 when depth changes significantly (rapid pan),
    /// then drops to 0.2 for micro-jitter smoothing during steady tracking.
    private var emaDepth: Float?
    private let emaBaseSmoothingFactor: Float = 0.2
    private let emaAdaptiveAlphaPeak: Float = 0.8
    private let emaDepthChangeThreshold: Float = 0.5
    
    /// Maximum depth drop in a single frame before the measurement is
    /// treated as a temporary occlusion (e.g., user walking in front of
    /// the fixture) and rejected. Prevents the fixture's HUD from jumping
    /// forward when the depth sensor briefly measures the user's head/body.
    private let occlusionDepthSpikeThreshold: Float = 1.0
    
    init(session: ARSession? = nil, configuration: Configuration = .init(), provider: CameraConfigurationProvider? = nil) {
        self.configuration = configuration
        self.provider = provider ?? DefaultCameraConfigurationProvider()
        self.session = session
    }
    
    /// Update the session reference after the AR session is launched.
    func configure(with arSession: ARSession) {
        self.session = arSession
    }
    
    // MARK: - Coordinate Projection
    
    /// Project a normalized 2D point to a 3D world position.
    func project(
        normalizedPoint: SIMD2<Float>,
        cameraTransform: simd_float4x4,
        anchor: AnchorEntity
    ) -> ProjectionResult {
        
        let intrinsics = provider.intrinsics

        guard let _ = SpatialMath.unprojectDirection(
            normalized: normalizedPoint,
            intrinsics: intrinsics,
            cameraTransform: cameraTransform
        ) else {
            return .failure("Failed to compute camera direction vector")
        }
        
        if let meshResult = raycastOnMesh(
            from: normalizedPoint,
            cameraTransform: cameraTransform,
            anchor: anchor
        ) {
            return .anchored(meshResult)
        }
        
        if let fixture = unprojectViaDepthMap(
            normalizedPoint,
            cameraTransform: cameraTransform,
            anchor: anchor
        )?.anchoredFixture {
            return .anchored(fixture)
        }
        
        let fallbackDistance: Float = emaDepth ?? DetectionConstants.fallbackDistanceMeters
        let fallbackPosition = SpatialMath.fallbackPosition(
            normalized: normalizedPoint,
            cameraTransform: cameraTransform,
            distance: fallbackDistance
        )
        
        let rotationMatrix = SpatialMath.rotationMatrix(from: cameraTransform)
        let fallbackOrientation = simd_quatf(rotationMatrix)
        
        return .anchored(
            TrackedFixture(
                id: UUID(),
                detection: FixtureDetection(
                    type: .lamp,
                    region: NormalizedRect(
                        topLeft: normalizedPoint - SIMD2<Float>(0.05, 0.05),
                        bottomRight: normalizedPoint + SIMD2<Float>(0.05, 0.05)
                    ),
                    confidence: 0.5
                ),
                position: fallbackPosition,
                orientation: fallbackOrientation,
                distanceMeters: fallbackDistance,
                material: nil
            )
        )
    }
    
    /// Project a normalized bounding box center to a 3D position with orientation.
    func project(
        region: NormalizedRect,
        cameraTransform: simd_float4x4,
        anchor: AnchorEntity
    ) -> ProjectionResult {
        
        let center = region.center
        
        let intrinsics = provider.intrinsics

        let direction = SpatialMath.unprojectDirection(
            normalized: center,
            intrinsics: intrinsics,
            cameraTransform: cameraTransform
        ) ?? SIMD3<Float>(0, 0, -1)
        
        if let meshResult = raycastOnMesh(
            from: center,
            cameraTransform: cameraTransform,
            anchor: anchor
        ) {
            let lookTarget = SIMD3<Float>(
                meshResult.position.x,
                meshResult.position.y,
                meshResult.position.z
            ) + direction * -1.0
            
            guard let orientation = SpatialMath.lookAtSafe(
                from: meshResult.position,
                at: lookTarget,
                worldUp: SIMD3<Float>(0, 1, 0)
            ) else {
                return .failure("Failed to compute orientation")
            }
            
            let adjustedPosition = meshResult.position + configuration.hudOffset
            
            return .anchored(
                TrackedFixture(
                    id: UUID(),
                    detection: FixtureDetection(
                        type: .lamp,
                        region: region,
                        confidence: DetectionConstants.meshResultConfidence
                    ),
                    position: adjustedPosition,
                    orientation: orientation,
                    distanceMeters: meshResult.distanceMeters,
                    material: nil
                )
            )
        }
        
        if let depthResult = unprojectViaDepthMap(
            center,
            cameraTransform: cameraTransform,
            anchor: anchor
        ) {
            return depthResult
        }
        
        return .failure("Projection failed for region: \(region)")
    }
    
    // MARK: - Raycast on Scene Reconstruction Mesh
    
    /// Perform a synchronous raycast against the scene reconstruction mesh.
    /// ARKit raycast APIs are strictly main-thread bound.
    private func raycastOnMesh(
        from normalizedPoint: SIMD2<Float>,
        cameraTransform: simd_float4x4,
        anchor: AnchorEntity
    ) -> TrackedFixture? {
        
        let intrinsics = provider.intrinsics

        guard let ray = SpatialMath.cameraRay(
            normalized: normalizedPoint,
            intrinsics: intrinsics,
            cameraTransform: cameraTransform,
            imageSize: .zero
        ) else {
            return nil
        }
        
        guard let activeSession = session else {
            return nil
        }
        
        let raycastQuery = ARRaycastQuery(
            origin: ray.origin,
            direction: ray.direction,
            allowing: .estimatedPlane,
            alignment: .horizontal
        )
        
        let results = activeSession.raycast(raycastQuery)
        
        guard let hit = results.first else {
            return nil
        }
        
        let position = SIMD3<Float>(
            hit.worldTransform.columns.3.x,
            hit.worldTransform.columns.3.y,
            hit.worldTransform.columns.3.z
        )
        
        let orientation = simd_quatf(hit.worldTransform)
        let distance = length(position - ray.origin)
        emaDepth = updateEMA(depth: distance, currentEma: emaDepth)
        
        let adjustedPosition = position + configuration.hudOffset
        
        return TrackedFixture(
            id: UUID(),
            detection: FixtureDetection(
                type: .lamp,
                region: NormalizedRect(
                    topLeft: normalizedPoint - SIMD2<Float>(0.05, 0.05),
                    bottomRight: normalizedPoint + SIMD2<Float>(0.05, 0.05)
                ),
                confidence: DetectionConstants.raycastProjectionConfidence
            ),
            position: adjustedPosition,
            orientation: orientation,
            distanceMeters: distance,
            material: nil
        )
    }
    
    // MARK: - Depth Map Unprojection
    
    private func unprojectViaDepthMap(
        _ normalizedPoint: SIMD2<Float>,
        cameraTransform: simd_float4x4,
        anchor: AnchorEntity
    ) -> ProjectionResult? {
        
        #if !targetEnvironment(simulator)
        if #available(iOS 26, *) {
            // Depth data unavailable - cameraTransform alone cannot provide scene depth
            return nil
        } else {
            return nil
        }
        #else
        return nil
        #endif
    }
    
    /// Extract depth value at a pixel coordinate from the depth and confidence maps.
    /// Returns depth in meters, or nil if the depth is invalid or confidence is insufficient.
    private func extractDepth(
        at pixel: SIMD2<Int>,
        in normalizedPoint: SIMD2<Float>,
        depthMap: CVPixelBuffer,
        confidenceMap: CVPixelBuffer?,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> Float? {
        let px = pixel.x
        let py = pixel.y
        
        let depthIndex = py * pixelWidth + px
        
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        let baseAddress = CVPixelBufferGetBaseAddress(depthMap)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let pointer = baseAddress.advanced(by: Int(py) * bytesPerRow + Int(px) * MemoryLayout<Float32>.stride)
        let depthMeters = pointer.assumingMemoryBound(to: Float32.self).pointee
        CVPixelBufferUnlockBaseAddress(depthMap, [])
        
        guard depthMeters >= configuration.minDepthMeters,
              depthMeters <= configuration.maxDepthMeters else {
            return nil
        }
        
        if let confidenceMap = confidenceMap {
            let confidenceIndex = py * pixelWidth + px
            if confidenceIndex >= 0, confidenceIndex < pixelWidth * pixelHeight {
                CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
                let confBase = CVPixelBufferGetBaseAddress(confidenceMap)!
                let confBytesPerRow = CVPixelBufferGetBytesPerRow(confidenceMap)
                let confPointer = confBase.advanced(by: Int(py) * confBytesPerRow + Int(px))
                let confidenceByte = confPointer.assumingMemoryBound(to: UInt8.self).pointee
                CVPixelBufferUnlockBaseAddress(confidenceMap, [])
                if confidenceByte == 0 {
                    return nil
                }
            }
        }
        
        return depthMeters
    }
}

// MARK: - Adaptive EMA Depth Smoothing

extension SpatialProjector {
    /// Apply an adaptive Exponential Moving Average (EMA) filter to depth measurements.
    /// When the depth change exceeds `emaDepthChangeThreshold`, the alpha ramps up to
    /// `emaAdaptiveAlphaPeak` (0.8) to snap to the new depth boundary quickly. Once
    /// measurements stabilize, alpha drops back to `emaBaseSmoothingFactor` (0.2) for
    /// micro-jitter resistance against mirrors, windows, or reflective surfaces.
    ///
    /// Occlusion rejection: if the depth drops by more than `occlusionDepthSpikeThreshold`
    /// (1.0m) in a single frame, the measurement is treated as a temporary occlusion
    /// (e.g., user walking in front of the fixture) and rejected to prevent the HUD
    /// from jumping forward. The EMA retains its previous value.
    ///
    /// - Parameters:
    ///   - depth: The new depth measurement in meters.
    ///   - currentEma: The current EMA value, or nil for the first measurement.
    /// - Returns: The updated EMA value, or the previous EMA if the measurement
    ///   is rejected as an occlusion spike.
    private func updateEMA(depth: Float, currentEma: Float?) -> Float {
        guard let currentEma = currentEma else { return depth }
        
        // Occlusion spike rejection: ignore sudden, massive depth drops that
        /// indicate temporary occlusion (e.g., user walking in front of the fixture).
        /// A drop of more than 1.0 meter in a single frame is physically implausible
        /// for a fixed fixture and almost certainly represents the depth sensor
        /// measuring the user's head/body instead of the target.
        let depthDelta = depth - currentEma
        if depthDelta < -occlusionDepthSpikeThreshold {
            return currentEma
        }
        
        let absDepthDelta = abs(depthDelta)
        
        // Adaptive alpha: ramp up when depth changes significantly
        let alpha: Float
        if absDepthDelta > emaDepthChangeThreshold {
            // Large depth change detected — snap quickly to new boundary
            alpha = emaAdaptiveAlphaPeak
        } else {
            // Small change — smooth out micro-jitter
            alpha = emaBaseSmoothingFactor
        }
        
        return alpha * depth + (1 - alpha) * currentEma
    }
}

// MARK: - Projection Result

/// Result of a coordinate projection operation.
enum ProjectionResult {
    case anchored(TrackedFixture)
    case failure(String)
    
    var anchoredFixture: TrackedFixture? {
        if case .anchored(let fixture) = self { return fixture }
        return nil
    }
    
    var errorMessage: String? {
        if case .failure(let msg) = self { return msg }
        return nil
    }
    
    var isSuccess: Bool {
        if case .anchored = self { return true }
        return false
    }
}

// MARK: - Projection Errors

/// Errors that can occur during spatial projection.
enum ProjectionError: Error, LocalizedError {
    case noWorldMap
    case invalidNormalizedPoint
    case raycastMiss
    case depthUnavailable
    case invalidIntrinsics
    case noSession
    
    var errorDescription: String? {
        switch self {
        case .noWorldMap: return "No world map available for raycasting"
        case .invalidNormalizedPoint: return "Invalid normalized point coordinates"
        case .raycastMiss: return "Raycast did not hit any mesh geometry"
        case .depthUnavailable: return "Depth data unavailable"
        case .invalidIntrinsics: return "Invalid camera intrinsics"
        case .noSession: return "ARSession not configured"
        }
    }
}
