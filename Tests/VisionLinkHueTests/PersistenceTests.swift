import XCTest
import @testable VisionLinkHue
import SwiftData
import simd

/// Unit tests for `FixturePersistence` ensuring that malformed spatial
/// data (NaN, infinity, non-unit quaternions, extreme distances) is
/// correctly rejected, and that SwiftData transactions are atomic.
final class PersistenceTests: XCTestCase {
    
    private var persistence: FixturePersistence!
    private var modelContainer: ModelContainer!
    
    override func setUp() {
        super.setUp()
        
        // Create an isolated in-memory ModelContainer for testing
        let schema = Schema([FixtureMapping.self])
        modelContainer = try! ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        persistence = FixturePersistence(container: modelContainer)
    }
    
    override func tearDown() {
        persistence = nil
        modelContainer = nil
        super.tearDown()
    }
    
    // MARK: - Spatial Data Validation Tests
    
    func testRejectsNaNPositionX() {
        let fixtureId = UUID()
        let position = SIMD3<Float>(.nan, 1.0, 2.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        // Should silently reject - no crash, no persistence
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "NaN position X should be rejected")
    }
    
    func testRejectsNaNPositionY() {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, .nan, 2.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "NaN position Y should be rejected")
    }
    
    func testRejectsNaNPositionZ() {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, .nan)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "NaN position Z should be rejected")
    }
    
    func testRejectsInfinitePositionX() {
        let fixtureId = UUID()
        let position = SIMD3<Float>(.infinity, 1.0, 2.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "Infinite position X should be rejected")
    }
    
    func testRejectsInfinitePositionY() {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, -.infinity, 2.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "Negative infinite position Y should be rejected")
    }
    
    func testRejectsInfinitePositionZ() {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, .infinity)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "Infinite position Z should be rejected")
    }
    
    func testRejectsNonUnitQuaternion() {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        // Quaternion with norm far from 1.0
        let orientation = simd_quatf(real: 2.0, imag: SIMD3<Float>(0, 0, 0))
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "Non-unit quaternion should be rejected")
    }
    
    func testRejectsQuaternionWithNaNComponents() {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(real: .nan, imag: SIMD3<Float>(0, 0, 0))
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "Quaternion with NaN components should be rejected")
    }
    
    func testRejectsUnreasonableDistanceZero() {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "Zero distance should be rejected")
    }
    
    func testRejectsUnreasonableDistanceNegative() {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: -5.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "Negative distance should be rejected")
    }
    
    func testRejectsUnreasonableDistanceOver100Meters() {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 101.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "Distance over 100 meters should be rejected")
    }
    
    func testRejectsExtremePositionOver1km() {
        let fixtureId = UUID()
        let position = SIMD3<Float>(5000.0, 5000.0, 5000.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 50.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "Position over 1km from origin should be rejected")
    }
    
    // MARK: - Valid Data Acceptance Tests
    
    func testAcceptsValidSpatialData() {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.5,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = persistence.loadMappings()
        XCTAssertEqual(mappings.count, 1, "Valid spatial data should be accepted")
        XCTAssertEqual(mappings.first?.lightId, "test-light")
        XCTAssertEqual(mappings.first?.fixtureType, "ceiling")
        XCTAssertEqual(mappings.first?.distanceMeters, 2.5)
    }
    
    func testAcceptsBoundaryDistanceExactly100Meters() {
        let fixtureId = UUID()
        let position = SIMD3<Float>(0.1, 0.1, 0.1)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 100.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = persistence.loadMappings()
        XCTAssertEqual(mappings.count, 1, "Distance exactly 100 meters should be accepted")
    }
    
    func testAcceptsUnitQuaternion() {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        // Properly normalized quaternion
        let orientation = simd_quatf(axis: SIMD3<Float>(1, 0, 0), angle: Float.pi / 2)
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 5.0,
            fixtureType: "pendant",
            confidence: 0.85
        )
        
        let mappings = persistence.loadMappings()
        XCTAssertEqual(mappings.count, 1, "Unit quaternion should be accepted")
    }
    
    // MARK: - Atomic Transaction Tests
    
    func testUpdateExistingMappingIsAtomic() {
        let fixtureId = UUID()
        let position1 = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation1 = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        // Save initial mapping
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "light-1",
            position: position1,
            orientation: orientation1,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        var mappings = persistence.loadMappings()
        XCTAssertEqual(mappings.count, 1)
        XCTAssertEqual(mappings.first?.lightId, "light-1")
        
        // Update with new data
        let position2 = SIMD3<Float>(4.0, 5.0, 6.0)
        let orientation2 = simd_quatf(axis: SIMD3<Float>(0, 1, 0), angle: Float.pi / 3)
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "light-2",
            position: position2,
            orientation: orientation2,
            distanceMeters: 3.0,
            fixtureType: "pendant",
            confidence: 0.95
        )
        
        mappings = persistence.loadMappings()
        XCTAssertEqual(mappings.count, 1, "Should still have exactly one mapping after update")
        XCTAssertEqual(mappings.first?.lightId, "light-2", "Light ID should be updated")
        XCTAssertEqual(mappings.first?.positionX, 4.0, "Position X should be updated")
        XCTAssertEqual(mappings.first?.fixtureType, "pendant", "Fixture type should be updated")
    }
    
    func testLinkFixtureIsAtomic() {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        // Create mapping without light ID
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: nil,
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        var mappings = persistence.loadMappings()
        XCTAssertEqual(mappings.count, 1)
        XCTAssertNil(mappings.first?.lightId)
        
        // Link to a light
        persistence.linkFixture(fixtureId, toLight: "linked-light-id")
        
        mappings = persistence.loadMappings()
        XCTAssertEqual(mappings.count, 1)
        XCTAssertEqual(mappings.first?.lightId, "linked-light-id", "Light ID should be linked")
    }
    
    func testUnlinkFixtureIsAtomic() {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        // Create mapping with light ID
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "original-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        // Unlink
        persistence.unlinkFixture(fixtureId)
        
        let mappings = persistence.loadMappings()
        XCTAssertEqual(mappings.count, 1)
        XCTAssertNil(mappings.first?.lightId, "Light ID should be nil after unlink")
    }
    
    func testMarkSyncedUpdatesIsSyncedToBridge() {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        var mappings = persistence.loadMappings()
        XCTAssertFalse(mappings.first?.isSyncedToBridge ?? true, "Should start as not synced")
        
        // Mark as synced
        persistence.markSynced(fixtureId)
        
        mappings = persistence.loadMappings()
        XCTAssertTrue(mappings.first?.isSyncedToBridge ?? false, "Should be marked as synced after calling markSynced")
    }
    
    func testRemoveMappingRemovesEntirely() {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        XCTAssertEqual(persistence.loadMappings().count, 1)
        
        // Remove the mapping
        persistence.removeMapping(for: fixtureId)
        
        let mappings = persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "Mapping should be removed entirely")
    }
    
    func testClearAllMappingsRemovesEverything() {
        let fixtureId1 = UUID()
        let fixtureId2 = UUID()
        let fixtureId3 = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        persistence.saveMapping(
            fixtureId: fixtureId1,
            lightId: "light-1",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        persistence.saveMapping(
            fixtureId: fixtureId2,
            lightId: "light-2",
            position: position,
            orientation: orientation,
            distanceMeters: 3.0,
            fixtureType: "pendant",
            confidence: 0.85
        )
        persistence.saveMapping(
            fixtureId: fixtureId3,
            lightId: "light-3",
            position: position,
            orientation: orientation,
            distanceMeters: 4.0,
            fixtureType: "recessed",
            confidence: 0.8
        )
        
        XCTAssertEqual(persistence.loadMappings().count, 3)
        
        // Clear all
        persistence.clearAllMappings()
        
        let mappings = persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "All mappings should be cleared")
    }
    
    func testMultipleMappingsPersistedCorrectly() {
        let fixtureId1 = UUID()
        let fixtureId2 = UUID()
        let position1 = SIMD3<Float>(1.0, 2.0, 3.0)
        let position2 = SIMD3<Float>(4.0, 5.0, 6.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        persistence.saveMapping(
            fixtureId: fixtureId1,
            lightId: "light-1",
            position: position1,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        persistence.saveMapping(
            fixtureId: fixtureId2,
            lightId: "light-2",
            position: position2,
            orientation: orientation,
            distanceMeters: 3.0,
            fixtureType: "pendant",
            confidence: 0.85
        )
        
        let mappings = persistence.loadMappings()
        XCTAssertEqual(mappings.count, 2, "Should have exactly two mappings")
        
        let lightIds = Set(mappings.map { $0.lightId })
        XCTAssertEqual(lightIds, ["light-1", "light-2"], "Should contain both light IDs")
    }
    
    // MARK: - Edge Cases
    
    func testRejectsMixedNaNAndValidPosition() {
        let fixtureId = UUID()
        let position = SIMD3<Float>(.nan, 2.0, 3.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "Position with any NaN component should be rejected")
    }
    
    func testRejectsZeroDistance() {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 0.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "Zero distance should be rejected")
    }
    
    func testAcceptsMinimalValidPosition() {
        let fixtureId = UUID()
        let position = SIMD3<Float>(0.001, 0.001, 0.001)
        let orientation = simd_quatf(real: 1.0, imag: SIMD3<Float>(0, 0, 0))
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 0.01,
            fixtureType: "lamp",
            confidence: 0.5
        )
        
        let mappings = persistence.loadMappings()
        XCTAssertEqual(mappings.count, 1, "Minimal valid position should be accepted")
    }
}
