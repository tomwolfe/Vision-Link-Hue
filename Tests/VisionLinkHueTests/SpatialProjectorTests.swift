import XCTest
@testable import VisionLinkHue

/// Tests for `SpatialProjector` focusing on:
/// - Configuration defaults
/// - ProjectionResult enum behavior
/// - Fallback chain verification via SpatialMath integration
final class SpatialProjectorTests: XCTestCase {
    
    // MARK: - Configuration Tests
    
    func testConfigurationDefaults() {
        let config = SpatialProjector.Configuration()
        
        XCTAssertEqual(config.maxRaycastDistance, 15.0)
        XCTAssertEqual(config.hudOffset, SIMD3<Float>(0, 0.15, 0))
        XCTAssertEqual(config.minDepthMeters, 0.1)
        XCTAssertEqual(config.maxDepthMeters, 15.0)
    }
    
    func testConfigurationCustomValues() {
        let config = SpatialProjector.Configuration(
            maxRaycastDistance: 10.0,
            hudOffset: SIMD3<Float>(0, 0.2, 0),
            minDepthMeters: 0.05,
            maxDepthMeters: 10.0
        )
        
        XCTAssertEqual(config.maxRaycastDistance, 10.0)
        XCTAssertEqual(config.hudOffset, SIMD3<Float>(0, 0.2, 0))
        XCTAssertEqual(config.minDepthMeters, 0.05)
        XCTAssertEqual(config.maxDepthMeters, 10.0)
    }
    
    // MARK: - ProjectionResult Tests
    
    func testAnchoredResultReturnsFixture() {
        let fixture = TrackedFixture(
            id: UUID(),
            detection: FixtureDetection(
                type: .lamp,
                region: NormalizedRect(x: 0.3, y: 0.1, width: 0.2, height: 0.2),
                confidence: 0.9
            ),
            position: SIMD3<Float>(1, 1, -1),
            orientation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
            distanceMeters: 1.5
        )
        
        let result: ProjectionResult = .anchored(fixture)
        
        XCTAssertNotNil(result.anchoredFixture)
        XCTAssertEqual(result.anchoredFixture?.id, fixture.id)
        XCTAssertNil(result.errorMessage)
        XCTAssertTrue(result.isSuccess)
    }
    
    func testFailureResultReturnsError() {
        let result: ProjectionResult = .failure("Test error message")
        
        XCTAssertNil(result.anchoredFixture)
        XCTAssertEqual(result.errorMessage, "Test error message")
        XCTAssertFalse(result.isSuccess)
    }
    
    func testAnchoredResultHasNoErrorMessage() {
        let fixture = TrackedFixture(
            id: UUID(),
            detection: FixtureDetection(
                type: .lamp,
                region: NormalizedRect(x: 0.3, y: 0.1, width: 0.2, height: 0.2),
                confidence: 0.9
            ),
            position: SIMD3<Float>(0, 0, -1),
            orientation: .identity,
            distanceMeters: 1.0
        )
        
        let result: ProjectionResult = .anchored(fixture)
        XCTAssertNil(result.errorMessage)
    }
    
    func testFailureResultHasNoFixture() {
        let result: ProjectionResult = .failure("No session")
        XCTAssertNil(result.anchoredFixture)
    }
    
    // MARK: - Fallback Chain Tests
    
    /// Verify that the fallback chain uses correct spatial math functions.
    /// The fallback position should be at a fixed distance from the camera.
    func testFallbackPositionCalculation() {
        let normalizedPoint = SIMD2<Float>(0.5, 0.5)
        let cameraTransform = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        
        let position = SpatialMath.fallbackPosition(
            normalized: normalizedPoint,
            cameraTransform: cameraTransform,
            distance: 2.0
        )
        
        // Fallback position should be at the specified distance along camera forward.
        XCTAssertEqual(position.z, -2.0, accuracy: 0.01)
    }
    
    /// Verify that lookAtSafe produces valid orientation for typical fixture positions.
    func testLookAtSafeProducesValidOrientation() {
        let cameraPosition = SIMD3<Float>(0, 0, 0)
        let lookTarget = SIMD3<Float>(0, 0, -5)
        let worldUp = SIMD3<Float>(0, 1, 0)
        
        let orientation = SpatialMath.lookAtSafe(
            from: cameraPosition,
            at: lookTarget,
            worldUp: worldUp
        )
        
        XCTAssertNotNil(orientation)
        XCTAssertEqual(orientation!.x, 0, accuracy: 0.01)
        XCTAssertEqual(orientation!.y, 0, accuracy: 0.01)
        XCTAssertEqual(orientation!.z, 0, accuracy: 0.01)
        XCTAssertEqual(orientation!.w, 1, accuracy: 0.01) // Identity quaternion for straight ahead
    }
    
    /// Verify that lookAtSafe returns nil for parallel/identical vectors.
    func testLookAtSafeReturnsNilForParallelVectors() {
        let position = SIMD3<Float>(0, 0, 0)
        let target = SIMD3<Float>(0, 0, 0) // Same as position
        let worldUp = SIMD3<Float>(0, 1, 0)
        
        let orientation = SpatialMath.lookAtSafe(
            from: position,
            at: target,
            worldUp: worldUp
        )
        
        XCTAssertNil(orientation, "Should return nil for parallel vectors")
    }
    
    /// Verify that camera ray production works with valid intrinsics.
    func testCameraRayWithValidIntrinsics() {
        // Create simple intrinsics matrix (3x3).
        let fx: Float = 500.0
        let fy: Float = 500.0
        let cx: Float = 0.5
        let cy: Float = 0.5
        
        let intrinsics = simd_float3x3(
            SIMD3<Float>(fx, 0, cx),
            SIMD3<Float>(0, fy, cy),
            SIMD3<Float>(0, 0, 1)
        )
        
        let cameraTransform = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        
        let ray = SpatialMath.cameraRay(
            normalized: SIMD2<Float>(0.5, 0.5),
            intrinsics: intrinsics,
            cameraTransform: cameraTransform,
            imageSize: CGSize(width: 1920, height: 1080)
        )
        
        XCTAssertNotNil(ray)
        // Center point should produce ray pointing straight ahead.
        XCTAssertEqual(ray!.origin, SIMD3<Float>(0, 0, 0), accuracy: 0.01)
    }
    
    /// Verify that camera ray returns nil when intrinsics are unavailable.
    func testCameraRayWithNilIntrinsics() {
        let cameraTransform = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        
        let ray = SpatialMath.cameraRay(
            normalized: SIMD2<Float>(0.5, 0.5),
            intrinsics: nil,
            cameraTransform: cameraTransform,
            imageSize: CGSize(width: 1920, height: 1080)
        )
        
        XCTAssertNil(ray, "Should return nil when intrinsics are unavailable")
    }
    
    /// Verify that unprojectDirection falls back to camera forward when intrinsics are nil.
    func testUnprojectDirectionWithNilIntrinsics() {
        let cameraTransform = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        
        let direction = SpatialMath.unprojectDirection(
            normalized: SIMD2<Float>(0.5, 0.5),
            intrinsics: nil,
            cameraTransform: cameraTransform
        )
        
        XCTAssertNotNil(direction, "Should return valid forward direction when intrinsics are unavailable")
        XCTAssertEqual(direction!, SIMD3<Float>(0, 0, -1), accuracy: 0.01, "Should fall back to camera forward direction")
    }
    
    // MARK: - ProjectionError Tests
    
    func testProjectionErrorDescriptions() {
        XCTAssertEqual(ProjectionError.noWorldMap.errorDescription, "No world map available for raycasting")
        XCTAssertEqual(ProjectionError.invalidNormalizedPoint.errorDescription, "Invalid normalized point coordinates")
        XCTAssertEqual(ProjectionError.raycastMiss.errorDescription, "Raycast did not hit any mesh geometry")
        XCTAssertEqual(ProjectionError.depthUnavailable.errorDescription, "Depth data unavailable")
        XCTAssertEqual(ProjectionError.invalidIntrinsics.errorDescription, "Invalid camera intrinsics")
        XCTAssertEqual(ProjectionError.noSession.errorDescription, "ARSession not configured")
    }
}
