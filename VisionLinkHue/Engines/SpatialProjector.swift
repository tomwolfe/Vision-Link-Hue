import Foundation
import ARKit
import RealityKit
import simd

/// Actor responsible for projecting 2D normalized coordinates from AI
/// detection into 3D world coordinates using ARKit raycasting and depth.
actor SpatialProjector {
    
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
    private weak var session: ARSession?
    private var lastWorldMap: WorldMap?
    
    init(session: ARSession? = nil, configuration: Configuration = .init()) {
        self.configuration = configuration
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
        inFrame frame: ARFrame,
        anchor: AnchorEntity.World
    ) async -> ProjectionResult {
        
        guard let intrinsics = frame.camera.intrinsics else {
            return .failure("Failed to compute camera direction vector")
        }
        
        guard let cameraDirection = SpatialMath.unprojectDirection(
            normalized: normalizedPoint,
            intrinsics: intrinsics,
            cameraTransform: frame.camera.transform
        ) else {
            return .failure("Failed to compute camera direction vector")
        }
        
        if let meshResult = try? await raycastOnMesh(
            from: normalizedPoint,
            in: frame,
            anchor: anchor
        ) {
            return .success(meshResult)
        }
        
        if let depthResult = unprojectViaDepthMap(
            normalizedPoint,
            frame: frame,
            anchor: anchor
        ) {
            return .success(depthResult)
        }
        
        let fallbackPosition = SpatialMath.fallbackPosition(
            normalized: normalizedPoint,
            cameraTransform: frame.camera.transform,
            distance: 2.0
        )
        
        let rotationMatrix = SpatialMath.rotationMatrix(from: frame.camera.transform)
        let fallbackOrientation = simd_quatf(rotationMatrix: rotationMatrix)
        
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
                distanceMeters: 2.0
            )
        )
    }
    
    /// Project a normalized bounding box center to a 3D position with orientation.
    func project(
        region: NormalizedRect,
        inFrame frame: ARFrame,
        anchor: AnchorEntity.World
    ) async -> ProjectionResult {
        
        let center = region.center
        
        guard let intrinsics = frame.camera.intrinsics else {
            return .failure("Camera intrinsics unavailable")
        }
        
        let direction = SpatialMath.unprojectDirection(
            normalized: center,
            intrinsics: intrinsics,
            cameraTransform: frame.camera.transform
        ) ?? SIMD3<Float>(0, 0, -1)
        
        if let meshResult = try? await raycastOnMesh(
            from: center,
            in: frame,
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
                        confidence: 0.9
                    ),
                    position: adjustedPosition,
                    orientation: orientation,
                    distanceMeters: meshResult.distance
                )
            )
        }
        
        if let depthResult = unprojectViaDepthMap(
            center,
            frame: frame,
            anchor: anchor
        ) {
            return depthResult
        }
        
        return .failure("Projection failed for region: \(region)")
    }
    
    // MARK: - Raycast on Scene Reconstruction Mesh
    
    private func raycastOnMesh(
        from normalizedPoint: SIMD2<Float>,
        in frame: ARFrame,
        anchor: AnchorEntity.World
    ) async throws -> TrackedFixture {
        
        guard let worldMap = frame.worldMap else {
            throw ProjectionError.noWorldMap
        }
        
        guard let intrinsics = frame.camera.intrinsics else {
            throw ProjectionError.invalidIntrinsics
        }
        
        guard let ray = SpatialMath.cameraRay(
            normalized: normalizedPoint,
            intrinsics: intrinsics,
            cameraTransform: frame.camera.transform,
            imageSize: frame.capturedImageSize
        ) else {
            throw ProjectionError.invalidNormalizedPoint
        }
        
        guard let activeSession = session else {
            throw ProjectionError.noSession
        }
        
        let raycastQuery = RaycastQuery(
            origin: ray.origin,
            direction: ray.direction,
            length: configuration.maxRaycastDistance,
            originalAnchor: anchor,
            type: .existingPlaneExtent,
            filter: .mesh
        )
        
        let results = activeSession.raycast(raycastQuery, using: worldMap)
        
        guard let hit = results.first else {
            throw ProjectionError.raycastMiss
        }
        
        let position = SIMD3<Float>(
            hit.worldTransform.columns.3.x,
            hit.worldTransform.columns.3.y,
            hit.worldTransform.columns.3.z
        )
        
        let orientation = simd_quatf(hit.worldTransform)
        let distance = Float(hit.distance)
        
        let adjustedPosition = position + configuration.hudOffset
        
        return TrackedFixture(
            id: UUID(),
            detection: FixtureDetection(
                type: .lamp,
                region: NormalizedRect(
                    topLeft: normalizedPoint - SIMD2<Float>(0.05, 0.05),
                    bottomRight: normalizedPoint + SIMD2<Float>(0.05, 0.05)
                ),
                confidence: 0.95
            ),
            position: adjustedPosition,
            orientation: orientation,
            distanceMeters: distance
        )
    }
    
    // MARK: - Depth Map Unprojection
    
    private func unprojectViaDepthMap(
        _ normalizedPoint: SIMD2<Float>,
        frame: ARFrame,
        anchor: AnchorEntity.World
    ) -> ProjectionResult? {
        
        guard let sceneDepth = frame.sceneDepth,
              let depthMap = sceneDepth.depthMap else {
            return nil
        }
        
        guard let intrinsics = frame.camera.intrinsics else {
            return nil
        }
        
        let pixelWidth = Int(depthMap.width)
        let pixelHeight = Int(depthMap.height)
        
        let px = Int(normalizedPoint.x * Float(pixelWidth))
        let py = Int(normalizedPoint.y * Float(pixelHeight))
        
        let depthIndex = py * pixelWidth + px
        
        let depthBytes = depthMap.data.bindMemory(to: UInt16.self, capacity: depthMap.data.count)
        
        guard depthIndex >= 0, depthIndex < depthMap.data.count / MemoryLayout<UInt16>.stride else {
            return nil
        }
        
        let depthValue = depthBytes[depthIndex]
        let depthMeters = Float(depthValue) / 1000.0
        
        guard depthMeters >= configuration.minDepthMeters,
              depthMeters <= configuration.maxDepthMeters else {
            return nil
        }
        
        if let confidenceMap = sceneDepth.confidenceMap {
            let confidenceIndex = py * pixelWidth + px
            if confidenceIndex >= 0, confidenceIndex < confidenceMap.data.count {
                let confidenceByte = confidenceMap.data[confidenceIndex]
                if confidenceByte == 0 {
                    return nil
                }
            }
        }
        
        guard let position = SpatialMath.depthUnproject(
            pixelX: px,
            pixelY: py,
            depthMeters: depthMeters,
            intrinsics: intrinsics,
            cameraTransform: frame.camera.transform,
            imageWidth: pixelWidth,
            imageHeight: pixelHeight
        ) else {
            return nil
        }
        
        let rotationMatrix = SpatialMath.rotationMatrix(from: frame.camera.transform)
        let orientation = simd_quatf(rotationMatrix: rotationMatrix)
        
        let adjustedPosition = position + configuration.hudOffset
        
        return .anchored(
            TrackedFixture(
                id: UUID(),
                detection: FixtureDetection(
                    type: .lamp,
                    region: NormalizedRect(
                        topLeft: normalizedPoint - SIMD2<Float>(0.05, 0.05),
                        bottomRight: normalizedPoint + SIMD2<Float>(0.05, 0.05)
                    ),
                    confidence: 0.75
                ),
                position: adjustedPosition,
                orientation: orientation,
                distanceMeters: depthMeters
            )
        )
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
