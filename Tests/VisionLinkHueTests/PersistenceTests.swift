import XCTest
@testable import VisionLinkHue
import SwiftData
import simd

/// Unit tests for `FixturePersistence` ensuring that malformed spatial
/// data (NaN, infinity, non-unit quaternions, extreme distances) is
/// correctly rejected, and that SwiftData transactions are atomic.
@MainActor
final class PersistenceTests: XCTestCase {
    
    private var persistence: FixturePersistence!
    private var modelContainer: ModelContainer!
    
    override func setUp() async throws {
        try await super.setUp()
        
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
    
    func testRejectsNaNPositionX() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(.nan, 1.0, 2.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        // Should silently reject - no crash, no persistence
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "NaN position X should be rejected")
    }
    
    func testRejectsNaNPositionY() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, .nan, 2.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "NaN position Y should be rejected")
    }
    
    func testRejectsNaNPositionZ() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, .nan)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "NaN position Z should be rejected")
    }
    
    func testRejectsInfinitePositionX() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(.infinity, 1.0, 2.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "Infinite position X should be rejected")
    }
    
    func testRejectsInfinitePositionY() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, -.infinity, 2.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "Negative infinite position Y should be rejected")
    }
    
    func testRejectsInfinitePositionZ() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, .infinity)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "Infinite position Z should be rejected")
    }
    
    func testRejectsNonUnitQuaternion() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        // Quaternion with norm far from 1.0
        let orientation = simd_quatf(real: 2.0, imag: SIMD3<Float>(0, 0, 0))
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "Non-unit quaternion should be rejected")
    }
    
    func testRejectsQuaternionWithNaNComponents() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(real: .nan, imag: SIMD3<Float>(0, 0, 0))
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "Quaternion with NaN components should be rejected")
    }
    
    func testRejectsUnreasonableDistanceZero() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "Zero distance should be rejected")
    }
    
    func testRejectsUnreasonableDistanceNegative() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: -5.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "Negative distance should be rejected")
    }
    
    func testRejectsUnreasonableDistanceOver100Meters() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 101.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "Distance over 100 meters should be rejected")
    }
    
    func testRejectsExtremePositionOver1km() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(5000.0, 5000.0, 5000.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 50.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "Position over 1km from origin should be rejected")
    }
    
    // MARK: - Valid Data Acceptance Tests
    
    func testAcceptsValidSpatialData() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.5,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = await persistence.loadAllMappings()
        XCTAssertEqual(mappings.count, 1, "Valid spatial data should be accepted")
        XCTAssertEqual(mappings.first?.lightId, "test-light")
        XCTAssertEqual(mappings.first?.fixtureType, "ceiling")
        XCTAssertEqual(mappings.first?.position.x, 1.0)
    }
    
    func testAcceptsBoundaryDistanceExactly100Meters() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(0.1, 0.1, 0.1)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 100.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.count, 1, "Distance exactly 100 meters should be accepted")
    }
    
    func testAcceptsUnitQuaternion() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        // Properly normalized quaternion
        let orientation = simd_quatf(angle: Float.pi / 2, axis: SIMD3<Float>(1, 0, 0))
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 5.0,
            fixtureType: "pendant",
            confidence: 0.85
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.count, 1, "Unit quaternion should be accepted")
    }
    
    // MARK: - Atomic Transaction Tests
    
    func testUpdateExistingMappingIsAtomic() async {
        let fixtureId = UUID()
        let position1 = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation1 = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        // Save initial mapping
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "light-1",
            position: position1,
            orientation: orientation1,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        var mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.count, 1)
        XCTAssertEqual(mappings.first?.lightId, "light-1")
        
        // Update with new data
        let position2 = SIMD3<Float>(4.0, 5.0, 6.0)
        let orientation2 = simd_quatf(angle: Float.pi / 3, axis: SIMD3<Float>(0, 1, 0))
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "light-2",
            position: position2,
            orientation: orientation2,
            distanceMeters: 3.0,
            fixtureType: "pendant",
            confidence: 0.95
        )
        
        let allMappings = await persistence.loadAllMappings()
        XCTAssertEqual(allMappings.count, 1, "Should still have exactly one mapping after update")
        XCTAssertEqual(allMappings.first?.lightId, "light-2", "Light ID should be updated")
        XCTAssertEqual(allMappings.first?.position.x, 4.0, "Position X should be updated")
        XCTAssertEqual(allMappings.first?.fixtureType, "pendant", "Fixture type should be updated")
    }
    
    func testLinkFixtureIsAtomic() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        // Create mapping without light ID
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: nil,
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        var mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.count, 1)
        XCTAssertNil(mappings.first?.lightId)
        
        // Link to a light
        await persistence.linkFixture(fixtureId, toLight: "linked-light-id")
        
        mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.count, 1)
        XCTAssertEqual(mappings.first?.lightId, "linked-light-id", "Light ID should be linked")
    }
    
    func testUnlinkFixtureIsAtomic() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        // Create mapping with light ID
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "original-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        // Unlink
        await persistence.unlinkFixture(fixtureId)
        
        let mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.count, 1)
        XCTAssertNil(mappings.first?.lightId, "Light ID should be nil after unlink")
    }
    

    func testRemoveMappingRemovesEntirely() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let count = await persistence.loadMappings().count
        XCTAssertEqual(count, 1)
        
        // Remove the mapping
        await persistence.removeMapping(for: fixtureId)
        
        let mappings = await persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "Mapping should be removed entirely")
    }
    
    func testClearAllMappingsRemovesEverything() async {
        let fixtureId1 = UUID()
        let fixtureId2 = UUID()
        let fixtureId3 = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        await persistence.saveMapping(
            fixtureId: fixtureId1,
            lightId: "light-1",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        await persistence.saveMapping(
            fixtureId: fixtureId2,
            lightId: "light-2",
            position: position,
            orientation: orientation,
            distanceMeters: 3.0,
            fixtureType: "pendant",
            confidence: 0.85
        )
        await persistence.saveMapping(
            fixtureId: fixtureId3,
            lightId: "light-3",
            position: position,
            orientation: orientation,
            distanceMeters: 4.0,
            fixtureType: "recessed",
            confidence: 0.8
        )
        
        
        let count = await persistence.loadMappings().count
        XCTAssertEqual(count, 3)
        
        // Clear all
        await persistence.clearAllMappings()
        
        let mappings = await persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "All mappings should be cleared")
    }
    
    func testMultipleMappingsPersistedCorrectly() async {
        let fixtureId1 = UUID()
        let fixtureId2 = UUID()
        let position1 = SIMD3<Float>(1.0, 2.0, 3.0)
        let position2 = SIMD3<Float>(4.0, 5.0, 6.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        await persistence.saveMapping(
            fixtureId: fixtureId1,
            lightId: "light-1",
            position: position1,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        await persistence.saveMapping(
            fixtureId: fixtureId2,
            lightId: "light-2",
            position: position2,
            orientation: orientation,
            distanceMeters: 3.0,
            fixtureType: "pendant",
            confidence: 0.85
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.count, 2, "Should have exactly two mappings")
        
        let lightIds = Set(mappings.map { $0.lightId })
        XCTAssertEqual(lightIds, ["light-1", "light-2"], "Should contain both light IDs")
    }
    
    // MARK: - Edge Cases
    
    func testRejectsMixedNaNAndValidPosition() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(.nan, 2.0, 3.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "Position with any NaN component should be rejected")
    }
    
    func testRejectsZeroDistance() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 0.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "Zero distance should be rejected")
    }
    
    func testAcceptsMinimalValidPosition() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(0.001, 0.001, 0.001)
        let orientation = simd_quatf(real: 1.0, imag: SIMD3<Float>(0, 0, 0))
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 0.01,
            fixtureType: "lamp",
            confidence: 0.5
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.count, 1, "Minimal valid position should be accepted")
    }
    
    // MARK: - Bridge Space Coordinate Tests
    
    func testSaveMappingWithBridgeSpaceCoordinates() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        let bridgePosition = SIMD3<Float>(5.0, 1.5, 2.0)
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.5,
            fixtureType: "pendant",
            confidence: 0.9,
            bridgePosition: bridgePosition
        )
        
        let mappings = await persistence.loadMappingsWithBridgeSpace()
        XCTAssertEqual(mappings.count, 1, "Mapping with bridge space should be accepted")
        XCTAssertEqual(mappings.first?.bridgePositionX, 5.0)
        XCTAssertEqual(mappings.first?.bridgePositionY, 1.5)
        XCTAssertEqual(mappings.first?.bridgePositionZ, 2.0)
    }
    
    func testLoadMappingsWithBridgeSpace() async {
        let fixtureId1 = UUID()
        let fixtureId2 = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        // Save one mapping with bridge space, one without
        await persistence.saveMapping(
            fixtureId: fixtureId1,
            lightId: "light-1",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9,
            bridgePosition: SIMD3<Float>(5.0, 1.0, 2.0)
        )
        await persistence.saveMapping(
            fixtureId: fixtureId2,
            lightId: "light-2",
            position: position,
            orientation: orientation,
            distanceMeters: 3.0,
            fixtureType: "lamp",
            confidence: 0.85
        )
        
        let bridgeMappings = await persistence.loadMappingsWithBridgeSpace()
        XCTAssertEqual(bridgeMappings.count, 1, "Should only return mappings with bridge space")
        XCTAssertEqual(bridgeMappings.first?.lightId, "light-1")
        
        let allMappings = await persistence.loadMappings()
        XCTAssertEqual(allMappings.count, 2, "Should return all mappings")
    }
    
    func testHasBridgeSpaceMappingsReturnsTrue() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        let hasBridge = await persistence.hasBridgeSpaceMappings()
        XCTAssertFalse(hasBridge, "Should be false with no mappings")
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9,
            bridgePosition: SIMD3<Float>(5.0, 1.0, 2.0)
        )
        
        XCTAssertTrue(hasBridge, "Should be true after saving bridge space")
    }
    
    func testHasBridgeSpaceMappingsReturnsFalseWithoutBridgeSpace() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let hasBridge = await persistence.hasBridgeSpaceMappings()
        XCTAssertFalse(hasBridge, "Should be false without bridge space")
    }
    
    func testUpdateMappingPreservesBridgeSpace() async {
        let fixtureId = UUID()
        let position1 = SIMD3<Float>(1.0, 2.0, 3.0)
        let position2 = SIMD3<Float>(4.0, 5.0, 6.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        let bridgePosition = SIMD3<Float>(5.0, 1.5, 2.0)
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "light-1",
            position: position1,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9,
            bridgePosition: bridgePosition
        )
        
        let bridgeMappings = await persistence.loadMappingsWithBridgeSpace()
        XCTAssertEqual(bridgeMappings.first?.bridgePositionX, 5.0)
        
        // Update with new ARKit position but no bridge space (should preserve existing)
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "light-1",
            position: position2,
            orientation: orientation,
            distanceMeters: 3.0,
            fixtureType: "ceiling",
            confidence: 0.95
        )
        
        let updatedBridgeMappings = await persistence.loadMappingsWithBridgeSpace()
        XCTAssertEqual(updatedBridgeMappings.first?.bridgePositionX, 5.0, "Bridge space should be preserved after update")
        XCTAssertEqual(bridgeMappings.first?.position.x, 4.0, "ARKit position should be updated")
    }
}
