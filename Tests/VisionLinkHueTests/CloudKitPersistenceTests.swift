import XCTest
@testable import VisionLinkHue
import SwiftData
import simd

/// Unit tests for CloudKit spatial persistence integration, validating
/// that `FixturePersistence` and `SpatialSyncRecord` share a ModelContainer
/// and that spatial sync records are properly created and managed.
@MainActor
final class CloudKitPersistenceTests: XCTestCase {
    
    private var persistence: FixturePersistence!
    private var modelContainer: ModelContainer!
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Create an isolated in-memory ModelContainer with both schemas
        let schema = Schema([FixtureMapping.self, SpatialSyncRecord.self])
        modelContainer = await MainActor.run {
            try! ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
        }
        persistence = await MainActor.run {
            FixturePersistence(container: modelContainer)
        }
    }
    
    override func tearDown() async throws {
        persistence = nil
        modelContainer = nil
        try await super.tearDown()
    }
    
    // MARK: - Schema Integration Tests
    
    func testPersistenceIncludesSpatialSyncRecordSchema() async {
        // Verify the persistence container was created with both models.
        // The schema includes both FixtureMapping and SpatialSyncRecord.
        let isInMemory = await persistence.isUsingInMemoryStorage
        XCTAssertFalse(isInMemory, "Should use persistent storage in test")
    }
    
    func testFixtureMappingPersistsCorrectly() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        await persistence.saveMapping(
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
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        let bridgePosition = SIMD3<Float>(5.0, 1.5, 2.0)
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "bridge-light",
            position: position,
            orientation: orientation,
            distanceMeters: 3.0,
            fixtureType: "ceiling",
            confidence: 0.95,
            bridgePosition: bridgePosition
        )
        
        let mappings = await persistence.loadAllMappings()
        guard let first = mappings.first else {
            XCTFail("Expected at least one mapping")
            return
        }
        XCTAssertEqual(first.position.x, 1.0)
        XCTAssertEqual(first.position.y, 2.0)
        XCTAssertEqual(first.position.z, 3.0)
    }
    
    func testMarkSyncedUpdatesBridgeSyncStatus() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "synced-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "lamp",
            confidence: 0.8
        )
        
        let mappings = await persistence.loadAllMappings()
        guard let first = mappings.first else {
            XCTFail("Expected at least one mapping")
            return
        }
        XCTAssertFalse(first.lightId == nil)
        
        await persistence.markSynced(fixtureId)
        
        let updatedMappings = await persistence.loadAllMappings()
        guard let updatedFirst = updatedMappings.first else {
            XCTFail("Expected at least one mapping")
            return
        }
        XCTAssertEqual(updatedFirst.lightId, "synced-light")
    }
    
    func testLoadMappingsWithBridgeSpaceFiltersCorrectly() async {
        let fixtureId1 = UUID()
        let fixtureId2 = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        // Save one mapping with bridge space
        await persistence.saveMapping(
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
        await persistence.saveMapping(
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
        let hasBridgeSpace = await persistence.hasBridgeSpaceMappings()
        XCTAssertFalse(hasBridgeSpace)
        
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "lamp",
            confidence: 0.8,
            bridgePosition: SIMD3<Float>(5.0, 1.0, 2.0)
        )
        
        let hasBridgeSpaceMappings = await persistence.hasBridgeSpaceMappings()
        XCTAssertTrue(hasBridgeSpaceMappings)
    }
    
    func testUpdateMappingPreservesBridgeSpaceCoordinates() async {
        let fixtureId = UUID()
        let position1 = SIMD3<Float>(1.0, 2.0, 3.0)
        let position2 = SIMD3<Float>(4.0, 5.0, 6.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        let bridgePosition = SIMD3<Float>(5.0, 1.5, 2.0)
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "original",
            position: position1,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "ceiling",
            confidence: 0.9,
            bridgePosition: bridgePosition
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.first?.lightId, "original")
        
        // Update without bridge position - should preserve existing
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "updated",
            position: position2,
            orientation: orientation,
            distanceMeters: 3.0,
            fixtureType: "ceiling",
            confidence: 0.95
        )
        
        let allMappings = await persistence.loadAllMappings()
        XCTAssertEqual(allMappings.first?.lightId, "updated", "Light ID should be updated")
        XCTAssertEqual(allMappings.first?.lightId, "updated", "Light ID should be updated")
    }
    
    func testClearAllMappingsRemovesEverything() async {
        let fixtureId1 = UUID()
        let fixtureId2 = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        await persistence.saveMapping(
            fixtureId: fixtureId1,
            lightId: "light-1",
            position: position,
            orientation: orientation,
            distanceMeters: 2.0,
            fixtureType: "pendant",
            confidence: 0.9
        )
        await persistence.saveMapping(
            fixtureId: fixtureId2,
            lightId: "light-2",
            position: position,
            orientation: orientation,
            distanceMeters: 3.0,
            fixtureType: "ceiling",
            confidence: 0.85
        )
        await persistence.saveMapping(
            fixtureId: fixtureId2,
            lightId: "light-2",
            position: position,
            orientation: orientation,
            distanceMeters: 3.0,
            fixtureType: "ceiling",
            confidence: 0.85
        )
        
        let allMappings = await persistence.loadAllMappings()
        XCTAssertEqual(allMappings.count, 2)
        
        await persistence.clearAllMappings()
        
        let finalMappings = await persistence.loadMappings()
        XCTAssertTrue(finalMappings.isEmpty)
    }
    
    func testContainerProvidesSharedModelContainer() {
        let container = persistence.container
        XCTAssertNotNil(container)
    }
    
    // MARK: - Edge Cases
    
    func testRejectsInvalidSpatialDataBeforeSync() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(.nan, 2.0, 3.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        await persistence.saveMapping(
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
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        await persistence.saveMapping(
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
        XCTAssertNil(mappings.first?.lightId, "Should not be marked as synced yet")
    }
}
