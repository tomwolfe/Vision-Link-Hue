import XCTest
import @testable VisionLinkHue
import SwiftData

/// Unit tests for `FixturePersistence` context management operations.
///
/// Verifies that the checkpoint and flush operations correctly save
/// and reset the SwiftData model context to prevent memory bloat
/// during heavy sync operations.
final class FixturePersistenceContextTests: XCTestCase {
    
    private var persistence: FixturePersistence!
    private var modelContainer: ModelContainer!
    
    override func setUp() {
        super.setUp()
        
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
    
    // MARK: - Save Mapping Tests
    
    func testSaveMappingCreatesRecord() async {
        let fixtureId = UUID()
        let lightId = "light-1"
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(axis: SIMD3<Float>(0, 1, 0), angle: .pi / 4)
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: lightId,
            position: position,
            orientation: orientation,
            distanceMeters: 2.5,
            fixtureType: "pendant",
            confidence: 0.95
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.count, 1)
        XCTAssertEqual(mappings.first?.uuid, fixtureId)
        XCTAssertEqual(mappings.first?.lightId, lightId)
    }
    
    func testSaveMappingRejectsNaNPosition() async {
        let fixtureId = UUID()
        let position = SIMD3<Float>(.nan, 2.0, 3.0)
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "light-1",
            position: position,
            orientation: simd_quatf(),
            distanceMeters: 2.5,
            fixtureType: "pendant",
            confidence: 0.95
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.count, 0, "NaN position should be rejected")
    }
    
    func testSaveMappingRejectsNonUnitQuaternion() async {
        let fixtureId = UUID()
        // Quaternion with norm far from 1.0
        let orientation = simd_quatf(vector: SIMD4<Float>(10, 0, 0, 0), w: 0)
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "light-1",
            position: SIMD3<Float>(1, 2, 3),
            orientation: orientation,
            distanceMeters: 2.5,
            fixtureType: "pendant",
            confidence: 0.95
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.count, 0, "Non-unit quaternion should be rejected")
    }
    
    func testSaveMappingRejectsZeroDistance() async {
        let fixtureId = UUID()
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "light-1",
            position: SIMD3<Float>(1, 2, 3),
            orientation: simd_quatf(),
            distanceMeters: 0,
            fixtureType: "pendant",
            confidence: 0.95
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.count, 0, "Zero distance should be rejected")
    }
    
    // MARK: - Update Existing Mapping Tests
    
    func testSaveMappingUpdatesExistingRecord() async {
        let fixtureId = UUID()
        
        // Save initial mapping
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "light-1",
            position: SIMD3<Float>(1, 2, 3),
            orientation: simd_quatf(),
            distanceMeters: 2.5,
            fixtureType: "pendant",
            confidence: 0.95
        )
        
        // Update the same fixture
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "light-2",
            position: SIMD3<Float>(4, 5, 6),
            orientation: simd_quatf(),
            distanceMeters: 3.0,
            fixtureType: "sconce",
            confidence: 0.85
        )
        
        let mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.count, 1, "Should still have exactly 1 mapping")
        XCTAssertEqual(mappings.first?.lightId, "light-2")
    }
    
    // MARK: - Link/Unlink Tests
    
    func testLinkFixture() async {
        let fixtureId = UUID()
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: nil,
            position: SIMD3<Float>(1, 2, 3),
            orientation: simd_quatf(),
            distanceMeters: 2.5,
            fixtureType: "pendant",
            confidence: 0.95
        )
        
        await persistence.linkFixture(fixtureId, toLight: "light-123")
        
        let mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.first?.lightId, "light-123")
    }
    
    func testUnlinkFixture() async {
        let fixtureId = UUID()
        
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "light-123",
            position: SIMD3<Float>(1, 2, 3),
            orientation: simd_quatf(),
            distanceMeters: 2.5,
            fixtureType: "pendant",
            confidence: 0.95
        )
        
        await persistence.unlinkFixture(fixtureId)
        
        let mappings = await persistence.loadMappings()
        XCTAssertNil(mappings.first?.lightId)
    }
    
    // MARK: - Batch Operations Tests
    
    func testExecuteBatchedExecutesAllOperations() async {
        let fixtureIds = (0..<10).map { _ in UUID() }
        
        let results = await persistence.executeBatched(
            count: fixtureIds.count,
            batchSize: 3,
            operation: { index in
                await persistence.saveMapping(
                    fixtureId: fixtureIds[index],
                    lightId: "light-\(index)",
                    position: SIMD3<Float>(Float(index), 0, 0),
                    orientation: simd_quatf(),
                    distanceMeters: 1.0,
                    fixtureType: "pendant",
                    confidence: 0.9
                )
            }
        )
        
        XCTAssertEqual(results.count, 10)
        let mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.count, 10)
    }
    
    func testClearAllMappings() async {
        for i in 0..<5 {
            await persistence.saveMapping(
                fixtureId: UUID(),
                lightId: "light-\(i)",
                position: SIMD3<Float>(Float(i), 0, 0),
                orientation: simd_quatf(),
                distanceMeters: 1.0,
                fixtureType: "pendant",
                confidence: 0.9
            )
        }
        
        await persistence.clearAllMappings()
        
        let mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.count, 0)
    }
    
    // MARK: - Bridge Space Mapping Tests
    
    func testLoadMappingsWithBridgeSpace() async {
        let fixtureId = UUID()
        
        // Save with bridge-space coordinates
        let bridgePos = SIMD3<Float>(10, 20, 30)
        await persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "light-1",
            position: SIMD3<Float>(1, 2, 3),
            orientation: simd_quatf(),
            distanceMeters: 2.5,
            fixtureType: "pendant",
            confidence: 0.95,
            bridgePosition: bridgePos
        )
        
        let bridgeMappings = await persistence.loadMappingsWithBridgeSpace()
        XCTAssertEqual(bridgeMappings.count, 1)
        XCTAssertEqual(bridgeMappings.first?.bridgePositionX, 10)
        XCTAssertEqual(bridgeMappings.first?.bridgePositionY, 20)
        XCTAssertEqual(bridgeMappings.first?.bridgePositionZ, 30)
    }
    
    func testLoadMappingsWithBridgeSpaceExcludesNoBridge() async {
        await persistence.saveMapping(
            fixtureId: UUID(),
            lightId: "light-1",
            position: SIMD3<Float>(1, 2, 3),
            orientation: simd_quatf(),
            distanceMeters: 2.5,
            fixtureType: "pendant",
            confidence: 0.95
        )
        
        let bridgeMappings = await persistence.loadMappingsWithBridgeSpace()
        XCTAssertEqual(bridgeMappings.count, 0, "Mappings without bridge coordinates should be excluded")
    }
    
    func testHasBridgeSpaceMappings() async {
        XCTAssertFalse(await persistence.hasBridgeSpaceMappings())
        
        await persistence.saveMapping(
            fixtureId: UUID(),
            lightId: "light-1",
            position: SIMD3<Float>(1, 2, 3),
            orientation: simd_quatf(),
            distanceMeters: 2.5,
            fixtureType: "pendant",
            confidence: 0.95,
            bridgePosition: SIMD3<Float>(10, 20, 30)
        )
        
        XCTAssertTrue(await persistence.hasBridgeSpaceMappings())
    }
    
    // MARK: - Context Management Tests
    
    func testCheckpointContextDoesNotCrash() async {
        // Save a mapping first to ensure there are pending changes.
        await persistence.saveMapping(
            fixtureId: UUID(),
            lightId: "light-1",
            position: SIMD3<Float>(1, 2, 3),
            orientation: simd_quatf(),
            distanceMeters: 2.5,
            fixtureType: "pendant",
            confidence: 0.95
        )
        
        // Checkpoint should succeed without crashing.
        // The processPendingChanges() call ensures UI responsiveness
        // during large CloudKit downloads.
        await persistence.checkpointContext(batchSize: 50)
        
        // Verify the mapping is still accessible after checkpoint.
        let mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.count, 1)
    }
    
    func testFlushContextDoesNotCrash() async {
        await persistence.saveMapping(
            fixtureId: UUID(),
            lightId: "light-1",
            position: SIMD3<Float>(1, 2, 3),
            orientation: simd_quatf(),
            distanceMeters: 2.5,
            fixtureType: "pendant",
            confidence: 0.95
        )
        
        // Flush should succeed without crashing.
        await persistence.flushContext()
        
        let mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.count, 1)
    }
}
