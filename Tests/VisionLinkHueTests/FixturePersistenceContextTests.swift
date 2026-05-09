import XCTest
@testable import VisionLinkHue
import SwiftData
import simd

/// Unit tests for `FixturePersistence` context management operations.
///
/// Verifies that the checkpoint and flush operations correctly save
/// and reset the SwiftData model context to prevent memory bloat
/// during heavy sync operations.
@MainActor
final class FixturePersistenceContextTests: XCTestCase {
    
    private var persistence: FixturePersistence!
    private var modelContainer: ModelContainer!
    
    override func setUp() async throws {
        try await super.setUp()
        
        let schema = Schema([FixtureMapping.self])
        modelContainer = await {
            try! ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
        }()
        persistence = await {
            FixturePersistence(container: modelContainer)
        }()
    }
    
    override func tearDown() async throws {
        persistence = nil
        modelContainer = nil
        try await super.tearDown()
    }
    
    // MARK: - Save Mapping Tests
    
    func testSaveMappingCreatesRecord() async {
        let fixtureId = UUID()
        let lightId = "light-1"
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0))
        
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
        let orientation = simd_quatf(real: 10, imag: SIMD3<Float>(0, 0, 0))
        
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
    
    func testExecuteBatchedExecutesAllOperations() async throws {
        let fixtureIds = (0..<10).map { _ in UUID() }
        
        let results: [UUID] = await withTaskGroup(of: UUID.self) { group in
            for i in 0..<fixtureIds.count {
                group.addTask { [persistence] in
                    guard let persistence else { return UUID() }
                    let id = fixtureIds[i]
                    await persistence.saveMapping(
                        fixtureId: id,
                        lightId: "light-\(i)",
                        position: SIMD3<Float>(Float(i), 0, 0),
                        orientation: simd_quatf(),
                        distanceMeters: 1.0,
                        fixtureType: "pendant",
                        confidence: 0.9
                    )
                    return id
                }
            }
            var ids: [UUID] = []
            for await id in group {
                ids.append(id)
            }
            return ids
        }
        
        XCTAssertEqual(results.count, 10)
        let mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.count, 10)
    }
    
    func testClearAllMappings() async throws {
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
        
        let firstResult = await persistence.loadMappingsWithBridgeSpace()
        XCTAssertEqual(firstResult.count, 1)
        XCTAssertEqual(firstResult.first?.bridgePositionX, 10)
        XCTAssertEqual(firstResult.first?.bridgePositionY, 20)
        XCTAssertEqual(firstResult.first?.bridgePositionZ, 30)
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
        let hasBridgeSpace = await persistence.hasBridgeSpaceMappings()
        XCTAssertFalse(hasBridgeSpace)
        
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
        
        let hasBridgeSpaceUpdated = await persistence.hasBridgeSpaceMappings()
        XCTAssertTrue(hasBridgeSpaceUpdated)
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
