import XCTest
import @testable VisionLinkHue
import simd

/// Unit tests for the spatial calibration system including the Kabsch
/// algorithm implementation and `SpatialCalibrationEngine`.
///
/// Tests input known ARKit-to-Bridge coordinate pairs and verify the
/// computed transformation produces expected results. This ensures the
/// Kabsch algorithm correctly resolves rotation and translation without
/// drift in room-scale scenarios.
final class CalibrationTests: XCTestCase {
    
    private var engine: SpatialCalibrationEngine!
    
    override func setUp() {
        super.setUp()
        engine = SpatialCalibrationEngine()
    }
    
    override func tearDown() {
        engine = nil
        super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testEngineStartsUnCalibrated() {
        XCTAssertFalse(engine.isCalibrated)
        XCTAssertNil(engine.transformation)
    }
    
    func testEngineRequiresMinimumCalibrationPoints() {
        XCTAssertEqual(SpatialCalibrationEngine.minCalibrationPoints, 3)
    }
    
    // MARK: - Calibration Point Management Tests
    
    func testAddCalibrationPointBeforeMinimum() {
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 0, 0), bridge: SIMD3<Float>(0, 0, 0))
        XCTAssertFalse(engine.isCalibrated)
        XCTAssertNil(engine.transformation)
    }
    
    func testAddThreeCalibrationPointsEnablesCalibration() {
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 0, 0), bridge: SIMD3<Float>(0, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(1, 0, 0), bridge: SIMD3<Float>(1, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 1, 0), bridge: SIMD3<Float>(0, 1, 0))
        
        XCTAssertTrue(engine.isCalibrated)
        XCTAssertNotNil(engine.transformation)
    }
    
    func testFIFOMaxPoints() {
        // Add 8 points (exceeds max of 6)
        for i in 0..<8 {
            engine.addCalibrationPoint(
                arKit: SIMD3<Float>(Float(i), 0, 0),
                bridge: SIMD3<Float>(Float(i), 0, 0)
            )
        }
        
        let points = engine.getCalibrationPoints()
        XCTAssertEqual(points.count, 6, "Should retain only the 6 most recent points")
        XCTAssertEqual(points.first?.arKit.x, 2.0, "First point should be index 2 (oldest retained)")
        XCTAssertEqual(points.last?.arKit.x, 7.0, "Last point should be index 7 (newest)")
    }
    
    func testClearCalibrationResetsState() {
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 0, 0), bridge: SIMD3<Float>(0, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(1, 0, 0), bridge: SIMD3<Float>(1, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 1, 0), bridge: SIMD3<Float>(0, 1, 0))
        
        XCTAssertTrue(engine.isCalibrated)
        engine.clearCalibration()
        
        XCTAssertFalse(engine.isCalibrated)
        XCTAssertNil(engine.transformation)
    }
    
    // MARK: - Identity Transformation Tests
    
    func testIdentityMappingWithZeroOffset() {
        // When ARKit and Bridge coordinates are identical,
        // the transformation should be identity.
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 0, 0), bridge: SIMD3<Float>(0, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(1, 0, 0), bridge: SIMD3<Float>(1, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 1, 0), bridge: SIMD3<Float>(0, 1, 0))
        
        guard let transform = engine.transformation else {
            XCTFail("Expected transformation after 3 calibration points")
            return
        }
        
        // Rotation should be identity
        let identity = simd_float3x3(
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(0, 0, 1)
        )
        XCTAssertEqual(transform.rotation, identity, accuracy: 0.001, "Rotation should be identity")
        
        // Translation should be zero
        XCTAssertEqual(transform.translation, SIMD3<Float>(0, 0, 0), accuracy: 0.001, "Translation should be zero")
    }
    
    func testIdentityMappingPreservesPoints() {
        // With identity mapping, mapped points should equal original ARKit points
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 0, 0), bridge: SIMD3<Float>(0, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(1, 0, 0), bridge: SIMD3<Float>(1, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 1, 0), bridge: SIMD3<Float>(0, 1, 0))
        
        let mapped = engine.mapToBridgeSpace(SIMD3<Float>(0.5, 0.5, 0))
        XCTAssertEqual(mapped, SIMD3<Float>(0.5, 0.5, 0), accuracy: 0.001)
    }
    
    // MARK: - Translation Transformation Tests
    
    func testTranslationOnlyTransformation() {
        // All calibration points have a constant offset, testing pure translation
        let offset = SIMD3<Float>(5.0, -3.0, 2.0)
        
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 0, 0), bridge: offset)
        engine.addCalibrationPoint(arKit: SIMD3<Float>(1, 0, 0), bridge: offset + SIMD3<Float>(1, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 1, 0), bridge: offset + SIMD3<Float>(0, 1, 0))
        
        guard let transform = engine.transformation else {
            XCTFail("Expected transformation after 3 calibration points")
            return
        }
        
        // Rotation should be identity
        let identity = simd_float3x3(
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(0, 0, 1)
        )
        XCTAssertEqual(transform.rotation, identity, accuracy: 0.01)
        
        // Translation should match the offset
        XCTAssertEqual(transform.translation, offset, accuracy: 0.01)
    }
    
    func testMapWithTranslation() {
        let offset = SIMD3<Float>(10.0, 0, 0)
        
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 0, 0), bridge: offset)
        engine.addCalibrationPoint(arKit: SIMD3<Float>(1, 0, 0), bridge: offset + SIMD3<Float>(1, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 1, 0), bridge: offset + SIMD3<Float>(0, 1, 0))
        
        let mapped = engine.mapToBridgeSpace(SIMD3<Float>(2, 3, 0))
        let expected = SIMD3<Float>(12, 3, 0)
        XCTAssertEqual(mapped, expected, accuracy: 0.01)
    }
    
    // MARK: - Rotation Transformation Tests
    
    func testRotationAroundZAxis() {
        // Test 90-degree rotation around Z axis
        // ARKit (1,0,0) maps to Bridge (0,1,0)
        // ARKit (0,1,0) maps to Bridge (-1,0,0)
        
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 0, 0), bridge: SIMD3<Float>(0, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(1, 0, 0), bridge: SIMD3<Float>(0, 1, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 1, 0), bridge: SIMD3<Float>(-1, 0, 0))
        
        guard let transform = engine.transformation else {
            XCTFail("Expected transformation after 3 calibration points")
            return
        }
        
        // Apply rotation to (1, 0, 0) should give (0, 1, 0)
        let result1 = transform.apply(SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(result1, SIMD3<Float>(0, 1, 0), accuracy: 0.05)
        
        // Apply rotation to (0, 1, 0) should give (-1, 0, 0)
        let result2 = transform.apply(SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(result2, SIMD3<Float>(-1, 0, 0), accuracy: 0.05)
    }
    
    func testRotationMatrixIsOrthogonal() {
        // Create non-trivial calibration points that require rotation
        let angle: Float = .pi / 6 // 30 degrees
        
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 0, 0), bridge: SIMD3<Float>(0, 0, 0))
        engine.addCalibrationPoint(
            arKit: SIMD3<Float>(1, 0, 0),
            bridge: SIMD3<Float>(cos(angle), sin(angle), 0)
        )
        engine.addCalibrationPoint(
            arKit: SIMD3<Float>(0, 1, 0),
            bridge: SIMD3<Float>(-sin(angle), cos(angle), 0)
        )
        
        guard let transform = engine.transformation else {
            XCTFail("Expected transformation after 3 calibration points")
            return
        }
        
        // Verify rotation matrix columns are unit vectors
        for i in 0..<3 {
            let col = transform.rotation.columns[i]
            XCTAssertEqual(simd_length(col), 1.0, accuracy: 0.01, "Column \(i) should be unit length")
        }
        
        // Verify columns are orthogonal
        let col0 = transform.rotation.columns[0]
        let col1 = transform.rotation.columns[1]
        let col2 = transform.rotation.columns[2]
        XCTAssertEqual(dot(col0, col1), 0.0, accuracy: 0.01, "Columns 0 and 1 should be orthogonal")
        XCTAssertEqual(dot(col1, col2), 0.0, accuracy: 0.01, "Columns 1 and 2 should be orthogonal")
        XCTAssertEqual(dot(col0, col2), 0.0, accuracy: 0.01, "Columns 0 and 2 should be orthogonal")
    }
    
    // MARK: - Combined Rotation and Translation Tests
    
    func testCombinedRotationAndTranslation() {
        // Test with both rotation and translation
        let rotationAngle: Float = .pi / 4
        let translation = SIMD3<Float>(3.0, 2.0, 1.0)
        
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 0, 0), bridge: translation)
        engine.addCalibrationPoint(
            arKit: SIMD3<Float>(1, 0, 0),
            bridge: translation + SIMD3<Float>(cos(rotationAngle), sin(rotationAngle), 0)
        )
        engine.addCalibrationPoint(
            arKit: SIMD3<Float>(0, 1, 0),
            bridge: translation + SIMD3<Float>(-sin(rotationAngle), cos(rotationAngle), 0)
        )
        
        guard let transform = engine.transformation else {
            XCTFail("Expected transformation after 3 calibration points")
            return
        }
        
        // Translation should be close to expected
        XCTAssertEqual(transform.translation, translation, accuracy: 0.05)
    }
    
    // MARK: - Fallback Behavior Tests
    
    func testMapToBridgeSpaceReturnsIdentityWhenNotCalibrated() {
        let input = SIMD3<Float>(5.0, 10.0, 15.0)
        let output = engine.mapToBridgeSpace(input)
        
        XCTAssertEqual(output, input, "Uncalibrated engine should return identity mapping")
    }
    
    func testDegenerateCalibrationSetsFailureState() {
        // Near-collinear points should fail calibration rather than
        // silently returning an identity transform that corrupts spatial mapping.
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 0, 0), bridge: SIMD3<Float>(0, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(1, 0.001, 0), bridge: SIMD3<Float>(1, 0.001, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(2, 0.002, 0), bridge: SIMD3<Float>(2, 0.002, 0))
        
        // Should report failure state rather than silently applying identity
        XCTAssertFalse(engine.isCalibrated)
        XCTAssertNil(engine.transformation)
        XCTAssertEqual(engine.calibrationFailure, .illConditionedCovariance)
        
        // mapToBridgeSpace should return input unchanged (identity fallback)
        let mapped = engine.mapToBridgeSpace(SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(mapped, SIMD3<Float>(1, 0, 0))
    }
    
    func testIdenticalPointsFailsCalibration() {
        // All-identical calibration points should fail calibration
        // rather than silently returning an identity transform.
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 0, 0), bridge: SIMD3<Float>(0, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 0, 0), bridge: SIMD3<Float>(0, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 0, 0), bridge: SIMD3<Float>(0, 0, 0))
        
        // Should report failure state
        XCTAssertFalse(engine.isCalibrated)
        XCTAssertNil(engine.transformation)
        XCTAssertEqual(engine.calibrationFailure, .illConditionedCovariance)
        
        // mapToBridgeSpace should return input unchanged
        let mapped = engine.mapToBridgeSpace(SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(mapped, SIMD3<Float>(1, 0, 0))
    }
    
    func testCalibrationFailureClearedOnSuccessfulCalibration() {
        // After a failed calibration, adding proper points should clear the failure state
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 0, 0), bridge: SIMD3<Float>(0, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(1, 0.001, 0), bridge: SIMD3<Float>(1, 0.001, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(2, 0.002, 0), bridge: SIMD3<Float>(2, 0.002, 0))
        
        XCTAssertFalse(engine.isCalibrated)
        XCTAssertNotNil(engine.calibrationFailure)
        
        // Reset and add valid points
        engine.clearCalibration()
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 0, 0), bridge: SIMD3<Float>(0, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(1, 0, 0), bridge: SIMD3<Float>(1, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 1, 0), bridge: SIMD3<Float>(0, 1, 0))
        
        XCTAssertTrue(engine.isCalibrated)
        XCTAssertNotNil(engine.transformation)
        XCTAssertNil(engine.calibrationFailure)
    }
    
    func testKabschHandlesMultipleCalibrationPoints() {
        // Using more than 3 points should produce a more accurate result
        // via least-squares optimization
        for i in 0..<6 {
            let arKit = SIMD3<Float>(Float(i), Float(i % 2), 0)
            let bridge = SIMD3<Float>(Float(i) + 5, Float(i % 2) - 3, 0)
            engine.addCalibrationPoint(arKit: arKit, bridge: bridge)
        }
        
        XCTAssertTrue(engine.isCalibrated)
        XCTAssertNotNil(engine.transformation)
        
        // Verify the transformation correctly maps known points
        let testPoint = SIMD3<Float>(3, 0, 0)
        let expectedBridge = SIMD3<Float>(8, -3, 0)
        let mapped = engine.mapToBridgeSpace(testPoint)
        
        XCTAssertEqual(mapped.x, expectedBridge.x, accuracy: 0.1)
        XCTAssertEqual(mapped.y, expectedBridge.y, accuracy: 0.1)
    }
    
    // MARK: - Helper Functions
    
    /// Dot product of two 3D vectors.
    private func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        a.x * b.x + a.y * b.y + a.z * b.z
    }
}
