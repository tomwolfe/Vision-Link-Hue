import XCTest
@testable import VisionLinkHue
import simd

/// Unit tests for the spatial calibration persistence system.
/// Verifies that the `SpatialCalibrationEngine` correctly saves,
/// loads, and clears the transformation matrix via a persistence store.
@MainActor
final class CalibrationPersistenceTests: XCTestCase {
    
    private var engine: SpatialCalibrationEngine!
    private var mockStore: MockCalibrationStore!
    
    override func setUp() {
        super.setUp()
        mockStore = MockCalibrationStore()
        engine = SpatialCalibrationEngine()
        engine.persistenceStore = mockStore
    }
    
    override func tearDown() {
        engine = nil
        mockStore = nil
        super.tearDown()
    }
    
    // MARK: - Persistence Wire-up Tests
    
    func testEngineAcceptsPersistenceStore() {
        XCTAssertNotNil(engine.persistenceStore)
        XCTAssertTrue(engine.persistenceStore is MockCalibrationStore)
    }
    
    func testEngineWorksWithoutPersistenceStore() {
        let engineWithoutStore = SpatialCalibrationEngine()
        XCTAssertNil(engineWithoutStore.persistenceStore)
        
        engineWithoutStore.addCalibrationPoint(arKit: SIMD3<Float>(0, 0, 0), bridge: SIMD3<Float>(0, 0, 0))
        engineWithoutStore.addCalibrationPoint(arKit: SIMD3<Float>(1, 0, 0), bridge: SIMD3<Float>(1, 0, 0))
        engineWithoutStore.addCalibrationPoint(arKit: SIMD3<Float>(0, 1, 0), bridge: SIMD3<Float>(0, 1, 0))
        
        XCTAssertTrue(engineWithoutStore.isCalibrated)
        XCTAssertNotNil(engineWithoutStore.transformation)
    }
    
    // MARK: - Save Calibration Tests
    
    func testCalibrationIsSavedAfterComputation() async {
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 0, 0), bridge: SIMD3<Float>(0, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(1, 0, 0), bridge: SIMD3<Float>(1, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 1, 0), bridge: SIMD3<Float>(0, 1, 0))
        
        XCTAssertTrue(engine.isCalibrated)
        XCTAssertNotNil(engine.transformation)
        
        // Give the async save task time to complete
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // The mock store should have received saveCalibration calls
        // (triggered by savePersistedCalibration in computeTransformation)
        XCTAssertFalse(mockStore.savedRotationData.isEmpty, "Rotation data should have been saved")
        XCTAssertFalse(mockStore.savedTranslationData.isEmpty, "Translation data should have been saved")
    }
    
    // MARK: - Load Calibration Tests
    
    func testLoadPersistedCalibrationRestoresTransformation() async throws {
        guard let transform = engine.transformation else {
            // Need to calibrate first
            engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 0, 0), bridge: SIMD3<Float>(0, 0, 0))
            engine.addCalibrationPoint(arKit: SIMD3<Float>(1, 0, 0), bridge: SIMD3<Float>(1, 0, 0))
            engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 1, 0), bridge: SIMD3<Float>(0, 1, 0))
            return
        }
        
        // Pre-populate the mock store with calibration data
        guard let transform = engine.transformation else {
            XCTFail("Expected transformation after 3 calibration points")
            return
        }
        
        mockStore.calibrationData = CalibrationData(
            rotationData: withUnsafeBytes(of: transform.rotation) { Data($0) },
            translationData: withUnsafeBytes(of: transform.translation) { Data($0) }
        )
        
        // Clear the engine's transformation
        engine.transformation = nil
        XCTAssertNil(engine.transformation)
        
        // Load from persistence
        let loaded = await engine.loadPersistedCalibration()
        XCTAssertTrue(loaded, "Should successfully load persisted calibration")
        XCTAssertNotNil(engine.transformation, "Transformation should be restored")
    }
    
    func testLoadPersistedCalibrationReturnsFalseWhenNoData() async {
        mockStore.calibrationData = nil
        
        let loaded = await engine.loadPersistedCalibration()
        XCTAssertFalse(loaded, "Should return false when no calibration data exists")
        XCTAssertNil(engine.transformation, "Transformation should remain nil")
    }
    
    // MARK: - Clear Calibration Tests
    
    func testClearCalibrationAlsoClearsPersistence() async {
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 0, 0), bridge: SIMD3<Float>(0, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(1, 0, 0), bridge: SIMD3<Float>(1, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 1, 0), bridge: SIMD3<Float>(0, 1, 0))
        
        XCTAssertTrue(engine.isCalibrated)
        
        engine.clearCalibration()
        
        XCTAssertFalse(engine.isCalibrated)
        XCTAssertNil(engine.transformation)
        
        // Give async clear time to complete
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        XCTAssertTrue(mockStore.clearCalled, "Persistence store should have been cleared")
    }
    
    // MARK: - Explicit Save/Load Tests
    
    func testExplicitSaveAndLoadCalibration() async {
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 0, 0), bridge: SIMD3<Float>(0, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(1, 0, 0), bridge: SIMD3<Float>(1, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 1, 0), bridge: SIMD3<Float>(0, 1, 0))
        
        guard let originalTransform = engine.transformation else {
            XCTFail("Expected transformation")
            return
        }
        
        // Create a new engine with the same store
        let newEngine = SpatialCalibrationEngine()
        newEngine.persistenceStore = mockStore
        
        // Load persisted calibration into new engine
        let loaded = await newEngine.loadPersistedCalibration()
        XCTAssertTrue(loaded, "New engine should load persisted calibration")
        XCTAssertNotNil(newEngine.transformation)
        
        // Verify the loaded transformation matches the original
        let loadedTransform = newEngine.transformation!
        for i in 0..<12 {
            let loadedR = loadedTransform.rotation[i]
            let originalR = originalTransform.rotation[i]
            XCTAssertEqual(loadedR.x, originalR.x, accuracy: 0.001)
            XCTAssertEqual(loadedR.y, originalR.y, accuracy: 0.001)
            XCTAssertEqual(loadedR.z, originalR.z, accuracy: 0.001)
        }
        for i in 0..<3 {
            let loadedT = loadedTransform.translation[i]
            let originalT = originalTransform.translation[i]
            XCTAssertEqual(loadedT, originalT, accuracy: 0.001)
        }
    }
    
    func testSavePersistedCalibrationSavesData() async {
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 0, 0), bridge: SIMD3<Float>(0, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(1, 0, 0), bridge: SIMD3<Float>(1, 0, 0))
        engine.addCalibrationPoint(arKit: SIMD3<Float>(0, 1, 0), bridge: SIMD3<Float>(0, 1, 0))
        
        // Manually trigger save (in production, this is called automatically after computeTransformation)
        engine.savePersistedCalibration()
        
        // Give async save time to complete
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        XCTAssertFalse(mockStore.savedRotationData.isEmpty)
        XCTAssertFalse(mockStore.savedTranslationData.isEmpty)
    }
}

// MARK: - Mock Calibration Store

/// Mock implementation of `SpatialCalibrationPersistenceStore` for testing.
final class MockCalibrationStore: SpatialCalibrationPersistenceStore {
    
    var calibrationData: CalibrationData?
    var savedRotationData: Data = Data()
    var savedTranslationData: Data = Data()
    var clearCalled = false
    
    func loadCalibration() async -> CalibrationData? {
        calibrationData
    }
    
    func saveCalibration(rotationData: Data, translationData: Data) async {
        savedRotationData = rotationData
        savedTranslationData = translationData
    }
    
    func clearCalibration() async {
        clearCalled = true
        calibrationData = nil
    }
}
