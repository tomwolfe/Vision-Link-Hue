import XCTest
@testable import VisionLinkHue
import simd

/// Unit tests for the Gram-Schmidt NaN protection in `SpatialCalibrationEngine`.
///
/// These tests verify that the orthogonalization step handles degenerate
/// inputs (zero-length columns, NaN values, collinear points) gracefully
/// by returning an identity matrix instead of propagating NaN.
@MainActor
final class GramSchmidtNaNProtectionTests: XCTestCase {
    
    private var engine: SpatialCalibrationEngine!
    
    override func setUp() {
        super.setUp()
        engine = SpatialCalibrationEngine()
    }
    
    override func tearDown() {
        engine = nil
        super.tearDown()
    }
    
    // MARK: - Degenerate Input Tests
    
    func testCollinearPointsDoNotProduceNaN() {
        // All points on a straight line creates a degenerate covariance matrix.
        // The det(HTH) check should catch this and fall back to identity.
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 0, 0), bridge: SIMD3<Float>(0, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(1, 0, 0), bridge: SIMD3<Float>(1, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(2, 0, 0), bridge: SIMD3<Float>(2, 0, 0))
        
        // Should not crash and should produce valid (non-NaN) output
        let mapped = engine.mapToBridgeSpace(SIMD3<Float>(1, 1, 0))
        XCTAssertFalse(mapped.x.isNaN, "Mapped X should not be NaN")
        XCTAssertFalse(mapped.y.isNaN, "Mapped Y should not be NaN")
        XCTAssertFalse(mapped.z.isNaN, "Mapped Z should not be NaN")
        XCTAssertFalse(mapped.x.isInfinite, "Mapped X should not be infinite")
        XCTAssertFalse(mapped.y.isInfinite, "Mapped Y should not be infinite")
        XCTAssertFalse(mapped.z.isInfinite, "Mapped Z should not be infinite")
    }
    
    func testNearZeroColumnDoesNotProduceNaN() {
        // Calibration points that produce a near-zero column in the rotation matrix.
        // The Gram-Schmidt NaN guard should catch this.
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 0, 0), bridge: SIMD3<Float>(0, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(1, 0, 0), bridge: SIMD3<Float>(0.0001, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 1, 0), bridge: SIMD3<Float>(0.0001, 0.0001, 0))
        
        let mapped = engine.mapToBridgeSpace(SIMD3<Float>(1, 1, 1))
        XCTAssertFalse(mapped.x.isNaN, "Mapped X should not be NaN")
        XCTAssertFalse(mapped.y.isNaN, "Mapped Y should not be NaN")
        XCTAssertFalse(mapped.z.isNaN, "Mapped Z should not be NaN")
    }
    
    func testAllSamePointDoesNotProduceNaN() {
        // All calibration points at the same location is maximally degenerate.
        engine.addCalibrationPoint(arKit: SIMD3<Float>(5, 5, 5), bridge: SIMD3<Float>(5, 5, 5))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(5, 5, 5), bridge: SIMD3<Float>(5, 5, 5))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(5, 5, 5), bridge: SIMD3<Float>(5, 5, 5))
        
        let mapped = engine.mapToBridgeSpace(SIMD3<Float>(0, 0, 0))
        XCTAssertFalse(mapped.x.isNaN, "Mapped X should not be NaN")
        XCTAssertFalse(mapped.y.isNaN, "Mapped Y should not be NaN")
        XCTAssertFalse(mapped.z.isNaN, "Mapped Z should not be NaN")
    }
    
    // MARK: - Valid Transformation Tests
    
    func testValidTransformationStillOrthogonal() {
        // Ensure the NaN guard does not break normal operation.
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 0, 0), bridge: SIMD3<Float>(0, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(1, 0, 0), bridge: SIMD3<Float>(1, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 1, 0), bridge: SIMD3<Float>(0, 1, 0))
        
        guard let transform = engine.transformation else {
            XCTFail("Expected transformation after 3 calibration points")
            return
        }
        
        // Verify rotation columns are unit vectors
        let col0 = transform.rotation.columns.0
        let col1 = transform.rotation.columns.1
        let col2 = transform.rotation.columns.2
        for (i, col) in [(0, col0), (1, col1), (2, col2)] {
            let length = simd_length(col)
            XCTAssertEqual(length, 1.0, accuracy: 0.01, "Column \(i) length should be ~1.0")
        }
        
        // Verify determinant is +1 (proper rotation, not reflection)
        let det = transform.rotation.columns.0.x * (
            transform.rotation.columns.1.y * transform.rotation.columns.2.z -
            transform.rotation.columns.1.z * transform.rotation.columns.2.y
        ) - transform.rotation.columns.0.y * (
            transform.rotation.columns.1.x * transform.rotation.columns.2.z -
            transform.rotation.columns.1.z * transform.rotation.columns.2.x
        ) + transform.rotation.columns.0.z * (
            transform.rotation.columns.1.x * transform.rotation.columns.2.y -
            transform.rotation.columns.1.y * transform.rotation.columns.2.x
        )
        XCTAssertGreaterThan(det, 0.5, "Determinant should be positive (>0.5) for proper rotation")
    }
    
    func testRotationTransformationSurvivesNaNGuard() {
        // A 90-degree rotation test that should still work correctly.
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 0, 0), bridge: SIMD3<Float>(0, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(1, 0, 0), bridge: SIMD3<Float>(0, 1, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 1, 0), bridge: SIMD3<Float>(-1, 0, 0))
        
        guard let transform = engine.transformation else {
            XCTFail("Expected transformation after 3 calibration points")
            return
        }
        
        let result = transform.apply(SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(result.x, 0, accuracy: 0.05)
        XCTAssertEqual(result.y, 1, accuracy: 0.05)
        XCTAssertEqual(result.z, 0, accuracy: 0.05)
    }
}
