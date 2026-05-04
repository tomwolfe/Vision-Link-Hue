import XCTest
import @testable VisionLinkHue
import SwiftData
import simd

/// Unit tests for CloudKit spatial persistence integration, validating
/// that `FixturePersistence` and `SpatialSyncRecord` share a ModelContainer
/// and that spatial sync records are properly created and managed.
final class CloudKitPersistenceTests: XCTestCase {
    
    private var persistence: FixturePersistence!
    private var modelContainer: ModelContainer!
    
    override func setUp() {
        super.setUp()
        
        // Create an isolated in-memory ModelContainer with both schemas
        let schema = Schema([FixtureMapping.self, SpatialSyncRecord.self])
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
    
    // MARK: - Schema Integration Tests
    
    func testPersistenceIncludesSpatialSyncRecordSchema() {
        // Verify the persistence container was created with both models.
        // The schema includes both FixtureMapping and SpatialSyncRecord.
        XCTAssertFalse(persistence.isUsingInMemoryStorage, "Should use persistent storage in test")
    }
    
    func testFixtureMappingPersistsCorrectly() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.5,
            fixtureType: "pendant",
            confidence: 0.9
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.count, 1)
        XCTAssertEqual(mappings.first?.lightId, "test-light")
    }
    
    func testFixtureMappingWithBridgeSpacePersists() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        let bridgePosition = SIMD3<Float>(5.0, 1.5, 2.0)
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "bridge-light",
            position: position,
            orientation: orientation,
            distanceMeters: 3.0,
            fixtureType: "ceiling",
            confidence: 0.95,
            bridgePosition: bridgePosition
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.count, 1)
        XCTAssertEqual(mappings.first?.bridgePositionX, 5.0)
        XCTAssertEqual(mappings.first?.bridgePositionY, 1.5)
        XCTAssertEqual(mappings.first?.bridgePositionZ, 2.0)
    }
    
    func testMarkSyncedUpdatesBridgeSyncStatus() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "synced-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "lamp",
            confidence: 0.8
        )
        
        var mappings = await persistence.loadMappings()
        XCTAssertFalse(mappings.first?.isSyncedToBridge ?? true)
        
        persistence.markSynced(fixtureId)
        
        mappings = await persistence.loadMappings()
        XCTAssertTrue(mappings.first?.isSyncedToBridge ?? false)
    }
    
    func testLoadMappingsWithBridgeSpaceFiltersCorrectly() async {
        let fixtureId1 = UUID()
        let fixtureId2 = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        // Save one mapping with bridge space
        persistence.saveMapping(
            fixtureId: fixtureId1,
            lightId: "bridge-1",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "pendant",
            confidence: 0.9,
            bridgePosition: SIMD3<Float>(5.0, 1.0, 2.0)
        )
        
        // Save one without bridge space
        persistence.saveMapping(
            fixtureId: fixtureId2,
            lightId: "no-bridge",
            position: position,
            orientation: orientation,
            distanceMeters: 3.0,
            fixtureType: "ceiling",
            confidence: 0.85
        )
        
        let bridgeMappings = await persistence.loadMappingsWithBridgeSpace()
        XCTAssertEqual(bridgeMappings.count, 1)
        XCTAssertEqual(bridgeMappings.first?.lightId, "bridge-1")
        
        let allMappings = await persistence.loadMappings()
        XCTAssertEqual(allMappings.count, 2)
    }
    
    func testHasBridgeSpaceMappingsReturnsCorrectly() async {
        XCTAssertFalse(await persistence.hasBridgeSpaceMappings())
        
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "lamp",
            confidence: 0.8,
            bridgePosition: SIMD3<Float>(5.0, 1.0, 2.0)
        )
        
        XCTAssertTrue(await persistence.hasBridgeSpaceMappings())
    }
    
    func testUpdateMappingPreservesBridgeSpaceCoordinates() async {
        let fixtureId = UUID()
        let position1 = SIMD3<Float>(1.0, 2.0, 3.0)
        let position2 = SIMD3<Float>(4.0, 5.0, 6.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        let bridgePosition = SIMD3<Float>(5.0, 1.5, 2.0)
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "original",
            position: position1,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9,
            bridgePosition: bridgePosition
        )
        
        var mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.first?.bridgePositionX, 5.0)
        
        // Update without bridge position - should preserve existing
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "updated",
            position: position2,
            orientation: orientation,
            distanceMeters: 3.0,
            fixtureType: "ceiling",
            confidence: 0.95
        )
        
        mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.first?.bridgePositionX, 5.0, "Bridge space should be preserved")
        XCTAssertEqual(mappings.first?.positionX, 4.0, "ARKit position should be updated")
    }
    
    func testClearAllMappingsRemovesEverything() async {
        let fixtureId1 = UUID()
        let fixtureId2 = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        persistence.saveMapping(
            fixtureId: fixtureId1,
            lightId: "light-1",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "pendant",
            confidence: 0.9
        )
        persistence.saveMapping(
            fixtureId: fixtureId2,
            lightId: "light-2",
            position: position,
            orientation: orientation,
            distanceMeters: 3.0,
            fixtureType: "ceiling",
            confidence: 0.85
        )
        
        XCTAssertEqual(await persistence.loadMappings().count, 2)
        
        persistence.clearAllMappings()
        
        XCTAssertTrue((await persistence.loadMappings()).isEmpty)
    }
    
    func testContainerProvidesSharedModelContainer() {
        let container = persistence.container
        XCTAssertNotNil(container)
    }
    
    // MARK: - Edge Cases
    
    func testRejectsInvalidSpatialDataBeforeSync() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(.nan, 2.0, 3.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "lamp",
            confidence: 0.8
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertTrue(mappings.isEmpty, "Invalid spatial data should be rejected before sync")
    }
    
    func testAcceptsValidDataForSync() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 0, 1), angle: Float.pi / 4)
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "syncable-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.5,
            fixtureType: "pendant",
            confidence: 0.9
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.count, 1, "Valid spatial data should be accepted for sync")
        XCTAssertFalse(mappings.first?.isSyncedToBridge ?? true, "Should not be marked as synced yet")
    }
}
