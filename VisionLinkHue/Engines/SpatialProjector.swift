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
    private let session: ARSession
    private let scene: ARSCNView? // Optional SceneKit overlay for debug
    private var lastWorldMap: WorldMap?
    
    init(session: ARSession, configuration: Configuration = .init()) {
        self.configuration = configuration
        self.session = session
        self.scene = nil
    }
    
    // MARK: - Coordinate Projection
    
    /// Project a normalized 2D point to a 3D world position.
    /// Uses raycast on scene reconstruction mesh as primary method,
    /// falls back to depth map unprojection.
    func project(
        normalizedPoint: SIMD2<Float>,
        inFrame frame: ARFrame,
        anchor: AnchorEntity.World
    ) async -> ProjectionResult {
        
        // Step 1: Convert normalized [0,1] to camera-space direction vector
        guard let cameraDirection = unprojectDirection(
            normalizedPoint,
            cameraTransform: frame.camera.transform
        ) else {
            return .failure("Failed to compute camera direction vector")
        }
        
        // Step 2: Try raycasting on scene reconstruction mesh
        if let meshResult = try? await raycastOnMesh(
            from: normalizedPoint,
            in: frame,
            anchor: anchor
        ) {
            return .success(meshResult)
        }
        
        // Step 3: Fallback to depth map unprojection
        if let depthResult = unprojectViaDepthMap(
            normalizedPoint,
            frame: frame,
            anchor: anchor
        ) {
            return .success(depthResult)
        }
        
        // Step 4: Last resort - use camera frustum projection
        if let fallback = fallbackProjection(
            normalizedPoint,
            cameraTransform: frame.camera.transform
        ) {
            return .success(fallback)
        }
        
        return .failure("All projection methods failed")
    }
    
    /// Project a normalized bounding box center to a 3D position with orientation.
    func project(
        region: NormalizedRect,
        inFrame frame: ARFrame,
        anchor: AnchorEntity.World
    ) async -> ProjectionResult {
        
        let center = region.center
        
        // Get the dominant direction from the bounding box normal
        let direction = unprojectDirection(center, cameraTransform: frame.camera.transform)
            ?? SIMD3<Float>(0, 0, -1)
        
        // Step 1: Raycast on scene reconstruction
        if let meshResult = try? await raycastOnMesh(
            from: center,
            in: frame,
            anchor: anchor
        ) {
            // Adjust orientation to face the camera
            let lookTarget = SIMD3<Float>(
                meshResult.position.x,
                meshResult.position.y,
                meshResult.position.z
            ) + direction * -1.0
            
            let orientation = simd_look_at(
                from: meshResult.position,
                at: lookTarget,
                worldUp: SIMD3<Float>(0, 1, 0)
            )
            
            let adjustedPosition = meshResult.position + configuration.hudOffset
            
            return .anchored(
                AnchoredFixture(
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
        
        // Step 2: Depth map fallback
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
    ) async throws -> AnchoredFixture {
        
        guard let worldMap = frame.worldMap else {
            throw ProjectionError.noWorldMap
        }
        
        // Convert normalized coordinates to camera-space ray
        guard let ray = cameraRay(from: normalizedPoint, frame: frame) else {
            throw ProjectionError.invalidNormalizedPoint
        }
        
        // Perform raycast on the scene reconstruction mesh
        let raycastQuery = RaycastQuery(
            origin: ray.origin,
            direction: ray.direction,
            length: configuration.maxRaycastDistance,
            originalAnchor: anchor,
            type: .existingPlaneExtent,
            filter: .mesh
        )
        
        let results = session.raycast(raycastQuery, using: worldMap)
        
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
        
        // Apply HUD offset
        let adjustedPosition = position + configuration.hudOffset
        
        return AnchoredFixture(
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
        
        guard let depthData = frame.worldMap?.depthData,
              let depthMap = depthData.depthMap else {
            return nil
        }
        
        // Convert normalized coordinates to depth map pixel coordinates
        let pixelWidth = Int(depthMap.width)
        let pixelHeight = Int(depthMap.height)
        
        let px = Int(normalizedPoint.x * Float(pixelWidth))
        let py = Int(normalizedPoint.y * Float(pixelHeight))
        
        let clampedPx = min(max(px, 0), pixelWidth - 1)
        let clampedPy = min(max(py, 0), pixelHeight - 1)
        
        // Read depth value at pixel
        let depthIndex = clampedPy * pixelWidth + clampedPx
        
        // Depth map is typically in meters, stored as uint16
        let depthBytes = depthMap.data.bindMemory(to: UInt16.self, capacity: depthMap.data.count)
        
        guard depthIndex < depthMap.data.count / MemoryLayout<UInt16>.stride else {
            return nil
        }
        
        let depthValue = depthBytes[depthIndex]
        let depthMeters = Float(depthValue) / 1000.0 // Convert mm to meters
        
        // Validate depth
        guard depthMeters >= configuration.minDepthMeters,
              depthMeters <= configuration.maxDepthMeters else {
            return nil
        }
        
        // Unproject to camera space
        guard let intrinsics = frame.camera.intrinsics else {
            return nil
        }
        
        let cameraPosition = SIMD3<Float>(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )
        
        let cameraRotation = simd_float3x3(
            frame.camera.transform.columns.0.xyz,
            frame.camera.transform.columns.1.xyz,
            frame.camera.transform.columns.2.xyz
        )
        
        // Convert pixel to camera-space direction
        let fx = Float(intrinsics.k0)
        let fy = Float(intrinsics.k4)
        let cx = Float(intrinsics.k2)
        let cy = Float(intrinsics.k5)
        
        let pixelX = Float(clampedPx)
        let pixelY = Float(clampedPy)
        
        let dirX = (pixelX - cx) / fx
        let dirY = (pixelY - cy) / fy
        
        let direction = SIMD3<Float>(dirX, dirY, 1.0)
        let rotatedDirection = cameraRotation * direction
        
        let position = cameraPosition + rotatedDirection * depthMeters
        
        let orientation = simd_quatf(
            rotationMatrix: simd_float3x3(
                frame.camera.transform.columns.0,
                frame.camera.transform.columns.1,
                frame.camera.transform.columns.2
            )
        )
        
        let adjustedPosition = position + configuration.hudOffset
        
        return .anchored(
            AnchoredFixture(
                id: UUID(),
                detection: FixtureDetection(
                    type: .lamp,
                    region: NormalizedRect(
                        topLeft: normalizedPoint - SIMD2<Float>(0.05, 0.05),
                        bottomRight: normalizedPoint + SIMD2<Float>(0.05, 0.05)
                    ),
                    confidence: 0.75 // Lower confidence for depth fallback
                ),
                position: adjustedPosition,
                orientation: orientation,
                distanceMeters: depthMeters
            )
        )
    }
    
    // MARK: - Camera Ray Mathematics
    
    /// Convert normalized [0,1] coordinates to a camera-space ray.
    private func cameraRay(from normalized: SIMD2<Float>, frame: ARFrame) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        guard let intrinsics = frame.camera.intrinsics else { return nil }
        
        let cameraPos = SIMD3<Float>(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )
        
        let fx = Float(intrinsics.k0)
        let fy = Float(intrinsics.k4)
        let cx = Float(intrinsics.k2)
        let cy = Float(intrinsics.k5)
        
        let imageWidth = Float(frame.capturedImageSize.width)
        let imageHeight = Float(frame.capturedImageSize.height)
        
        let pixelX = normalized.x * imageWidth
        let pixelY = normalized.y * imageHeight
        
        // Back-project to camera space (z = 1 plane)
        let dirX = (pixelX - cx) / fx
        let dirY = (pixelY - cy) / fy
        
        var direction = SIMD3<Float>(dirX, dirY, 1.0)
        direction = normalize(direction)
        
        // Rotate direction by camera orientation
        let rotationMatrix = simd_float3x3(
            frame.camera.transform.columns.0.xyz,
            frame.camera.transform.columns.1.xyz,
            frame.camera.transform.columns.2.xyz
        )
        direction = rotationMatrix * direction
        
        return (origin: cameraPos, direction: direction)
    }
    
    /// Unproject a normalized 2D point into a camera-space direction vector.
    private func unprojectDirection(
        _ normalized: SIMD2<Float>,
        cameraTransform: simd_float4x4
    ) -> SIMD3<Float>? {
        let rotation = simd_float3x3(
            cameraTransform.columns.0.xyz,
            cameraTransform.columns.1.xyz,
            cameraTransform.columns.2.xyz
        )
        
        // Default: project straight ahead in camera frustum
        let direction = normalize(rotation * SIMD3<Float>(0, 0, -1))
        return direction
    }
    
    // MARK: - Fallback Projection
    
    private func fallbackProjection(
        _ normalized: SIMD2<Float>,
        cameraTransform: simd_float4x4
    ) -> ProjectionResult? {
        
        let cameraPos = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        
        let rotation = simd_float3x3(
            cameraTransform.columns.0.xyz,
            cameraTransform.columns.1.xyz,
            cameraTransform.columns.2.xyz
        )
        
        // Project at a fixed distance along camera forward
        let forward = normalize(rotation * SIMD3<Float>(0, 0, -1))
        let horizontal = normalize(rotation * SIMD3<Float>(1, 0, 0))
        let vertical = normalize(rotation * SIMD3<Float>(0, 1, 0))
        
        let offset = SIMD3<Float>(
            (normalized.x - 0.5) * 2.0,
            (normalized.y - 0.5) * 2.0,
            0
        )
        
        let direction = forward + horizontal * offset.x + vertical * offset.y
        let distance: Float = 2.0
        let position = cameraPos + normalize(direction) * distance
        
        let orientation = simd_quatf(rotationMatrix: rotation)
        
        return .anchored(
            AnchoredFixture(
                id: UUID(),
                detection: FixtureDetection(
                    type: .lamp,
                    region: NormalizedRect(
                        topLeft: normalized - SIMD2<Float>(0.05, 0.05),
                        bottomRight: normalized + SIMD2<Float>(0.05, 0.05)
                    ),
                    confidence: 0.5 // Lowest confidence for fallback
                ),
                position: position,
                orientation: orientation,
                distanceMeters: distance
            )
        )
    }
    
    // MARK: - Utility
    
    /// Look-at matrix construction for orientation.
    private func simd_look_at(from: SIMD3<Float>, at: SIMD3<Float>, worldUp: SIMD3<Float>) -> simd_quatf {
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
}

/// Result of a coordinate projection operation.
enum ProjectionResult {
    case anchored(AnchoredFixture)
    case failure(String)
    
    var anchoredFixture: AnchoredFixture? {
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

/// Errors that can occur during spatial projection.
enum ProjectionError: Error, LocalizedError {
    case noWorldMap
    case invalidNormalizedPoint
    case raycastMiss
    case depthUnavailable
    case invalidIntrinsics
    
    var errorDescription: String? {
        switch self {
        case .noWorldMap: return "No world map available for raycasting"
        case .invalidNormalizedPoint: return "Invalid normalized point coordinates"
        case .raycastMiss: return "Raycast did not hit any mesh geometry"
        case .depthUnavailable: return "Depth data unavailable"
        case .invalidIntrinsics: return "Invalid camera intrinsics"
        }
    }
}
