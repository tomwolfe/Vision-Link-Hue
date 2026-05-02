import XCTest
import @testable VisionLinkHue
import simd

/// Unit tests for the pure spatial math utilities.
/// All methods are deterministic pure functions, making them ideal for
/// isolated unit testing without ARKit or Vision framework dependencies.
final class SpatialMathTests: XCTestCase {
    
    // MARK: - cameraRay Tests
    
    func testCameraRayProducesValidOriginAndDirection() {
        // Camera at origin looking down -Z axis with standard intrinsics.
        let cameraTransform = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        
        let intrinsics = cameraIntrinsics(
            k0: 500.0, k1: 0.0, k2: 320.0,
            k3: 0.0, k4: 500.0, k5: 240.0,
            k6: 0.0, k7: 0.0, k8: 1.0
        )
        
        let imageSize = CGSize(width: 640, height: 480)
        let center = SIMD2<Float>(0.5, 0.5)
        
        guard let ray = SpatialMath.cameraRay(
            normalized: center,
            intrinsics: intrinsics,
            cameraTransform: cameraTransform,
            imageSize: imageSize
        ) else {
            XCTFail("Expected valid camera ray for center point")
            return
        }
        
        // Center normalized point should produce a ray pointing straight ahead (-Z).
        XCTAssertEqual(ray.origin, SIMD3<Float>(0, 0, 0), accuracy: 0.001)
        XCTAssertEqual(ray.direction, SIMD3<Float>(0, 0, -1), accuracy: 0.001)
    }
    
    func testCameraRayEdgePoint() {
        let cameraTransform = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        
        let intrinsics = cameraIntrinsics(
            k0: 500.0, k1: 0.0, k2: 320.0,
            k3: 0.0, k4: 500.0, k5: 240.0,
            k6: 0.0, k7: 0.0, k8: 1.0
        )
        
        let imageSize = CGSize(width: 640, height: 480)
        let topLeft = SIMD2<Float>(0.0, 0.0)
        
        guard let ray = SpatialMath.cameraRay(
            normalized: topLeft,
            intrinsics: intrinsics,
            cameraTransform: cameraTransform,
            imageSize: imageSize
        ) else {
            XCTFail("Expected valid camera ray for top-left point")
            return
        }
        
        // Top-left corner should have a negative X and negative Y direction component.
        XCTAssertLessThan(ray.direction.x, 0, accuracy: 0.001)
        XCTAssertLessThan(ray.direction.y, 0, accuracy: 0.001)
        XCTAssertGreaterThan(ray.direction.z, 0, accuracy: 0.001)
        
        // Direction should be normalized.
        XCTAssertEqual(length(ray.direction), 1.0, accuracy: 0.001)
    }
    
    // MARK: - unprojectDirection Tests
    
    func testUnprojectDirectionReturnsNormalizedVector() {
        let cameraTransform = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        
        let intrinsics = cameraIntrinsics(
            k0: 500.0, k1: 0.0, k2: 320.0,
            k3: 0.0, k4: 500.0, k5: 240.0,
            k6: 0.0, k7: 0.0, k8: 1.0
        )
        
        let direction = SpatialMath.unprojectDirection(
            normalized: SIMD2<Float>(0.5, 0.5),
            intrinsics: intrinsics,
            cameraTransform: cameraTransform
        )
        
        XCTAssertNotNil(direction)
        XCTAssertEqual(length(direction!), 1.0, accuracy: 0.001)
    }
    
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
        
        XCTAssertNotNil(direction)
        // Should fall back to camera's forward direction.
        XCTAssertEqual(direction!, SIMD3<Float>(0, 0, -1), accuracy: 0.001)
    }
    
    // MARK: - depthUnproject Tests
    
    func testDepthUnprojectProducesCorrectWorldPosition() {
        let cameraTransform = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        
        let intrinsics = cameraIntrinsics(
            k0: 500.0, k1: 0.0, k2: 320.0,
            k3: 0.0, k4: 500.0, k5: 240.0,
            k6: 0.0, k7: 0.0, k8: 1.0
        )
        
        let position = SpatialMath.depthUnproject(
            pixelX: 320,
            pixelY: 240,
            depthMeters: 2.0,
            intrinsics: intrinsics,
            cameraTransform: cameraTransform,
            imageWidth: 640,
            imageHeight: 480
        )
        
        XCTAssertNotNil(position)
        // Center pixel at 2m depth should be at (0, 0, -2) in world space.
        XCTAssertEqual(position!.z, -2.0, accuracy: 0.001)
        XCTAssertEqual(position!.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(position!.y, 0.0, accuracy: 0.001)
    }
    
    func testDepthUnprojectClampsPixelCoordinates() {
        let cameraTransform = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        
        let intrinsics = cameraIntrinsics(
            k0: 500.0, k1: 0.0, k2: 320.0,
            k3: 0.0, k4: 500.0, k5: 240.0,
            k6: 0.0, k7: 0.0, k8: 1.0
        )
        
        // Out-of-bounds pixel should be clamped, not return nil.
        let position = SpatialMath.depthUnproject(
            pixelX: 1000,
            pixelY: -10,
            depthMeters: 1.0,
            intrinsics: intrinsics,
            cameraTransform: cameraTransform,
            imageWidth: 640,
            imageHeight: 480
        )
        
        XCTAssertNotNil(position)
    }
    
    // MARK: - fallbackPosition Tests
    
    func testFallbackPositionAtFixedDistance() {
        let cameraTransform = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        
        let position = SpatialMath.fallbackPosition(
            normalized: SIMD2<Float>(0.5, 0.5),
            cameraTransform: cameraTransform,
            distance: 2.0
        )
        
        // Center point at 2m should be at (0, 0, -2).
        XCTAssertEqual(position.z, -2.0, accuracy: 0.001)
    }
    
    // MARK: - lookAtSafe Tests
    
    func testLookAtSafeProducesValidQuaternion() {
        let from = SIMD3<Float>(0, 0, 0)
        let to = SIMD3<Float>(0, 0, -5)
        let worldUp = SIMD3<Float>(0, 1, 0)
        
        let quaternion = SpatialMath.lookAtSafe(
            from: from,
            at: to,
            worldUp: worldUp
        )
        
        XCTAssertNotNil(quaternion)
        XCTAssertEqual(length(quaternion!), 1.0, accuracy: 0.001)
    }
    
    func testLookAtSafeReturnsNilForParallelVectors() {
        let from = SIMD3<Float>(0, 0, 0)
        let to = SIMD3<Float>(0, 1, 0) // Same direction as worldUp
        let worldUp = SIMD3<Float>(0, 1, 0)
        
        let quaternion = SpatialMath.lookAtSafe(
            from: from,
            at: to,
            worldUp: worldUp
        )
        
        XCTAssertNil(quaternion, "Expected nil for parallel forward and worldUp vectors")
    }
    
    // MARK: - rotationMatrix / translation Tests
    
    func testRotationMatrixExtracts3x3() {
        let transform = simd_float4x4(
            SIMD4<Float>(0, -1, 0, 0),
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        
        let rotation = SpatialMath.rotationMatrix(from: transform)
        
        // The 3x3 rotation should match the upper-left 3x3 of the 4x4.
        XCTAssertEqual(rotation.columns.0, SIMD3<Float>(0, -1, 0), accuracy: 0.001)
        XCTAssertEqual(rotation.columns.1, SIMD3<Float>(1, 0, 0), accuracy: 0.001)
        XCTAssertEqual(rotation.columns.2, SIMD3<Float>(0, 0, 1), accuracy: 0.001)
    }
    
    func testTranslationExtractsPosition() {
        let transform = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(3, 4, 5, 1)
        )
        
        let translation = SpatialMath.translation(from: transform)
        
        XCTAssertEqual(translation, SIMD3<Float>(3, 4, 5), accuracy: 0.001)
    }
}
