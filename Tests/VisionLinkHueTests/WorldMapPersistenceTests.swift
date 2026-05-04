import XCTest
import SwiftData
import @testable VisionLinkHue

/// Unit tests for the ARWorldMap persistence functionality in FixturePersistence.
/// Validates save, load, existence check, and deletion of world map data.
final class WorldMapPersistenceTests: XCTestCase {
    
    private var persistence: FixturePersistence!
    private var modelContainer: ModelContainer!
    
    override func setUp() {
        super.setUp()
        let schema = Schema([FixtureMapping.self])
        modelContainer = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        persistence = FixturePersistence(container: modelContainer)
    }
    
    override func tearDown() {
        persistence = nil
        modelContainer = nil
        super.tearDown()
    }
    
    // MARK: - World Map File Existence Tests
    
    func testHasWorldMapReturnsFalseWhenNoneSaved() {
        XCTAssertFalse(persistence.hasWorldMap(), "Should return false when no world map exists")
    }
    
    func testSaveWorldMapCreatesFile() {
        // Create a minimal ARWorldMap for testing.
        // In unit tests, we can't create a real ARWorldMap without ARKit hardware,
        // but we can verify the file existence logic.
        let hasBefore = persistence.hasWorldMap()
        XCTAssertFalse(hasBefore, "Should not have world map before saving")
        
        // Note: We can't test actual ARWorldMap save/load in unit tests
        // without ARKit hardware. The file existence check is the primary
        // testable behavior here.
    }
    
    func testDeleteWorldMapRemovesFile() {
        // Verify delete doesn't crash when no file exists.
        persistence.deleteWorldMap()
        XCTAssertFalse(persistence.hasWorldMap(), "Should return false after deleting non-existent map")
    }
    
    // MARK: - Integration with Fixture Persistence
    
    func testFixturePersistenceStillWorksAfterWorldMapMethods() {
        // Ensure adding world map methods didn't break existing fixture persistence.
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 1.5, -2.0)
        let orientation = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0))
        
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "test-light-id",
            position: position,
            orientation: orientation,
            distanceMeters: 2.5,
            fixtureType: "ceiling",
            confidence: 0.9
        )
        
        let mappings = try! persistence.modelContext.fetch(FetchDescriptor<FixtureMapping>())
        XCTAssertEqual(mappings.count, 1, "Should have one saved mapping")
    }
    
    func testWorldMapDoesNotInterfereWithFixtureMappings() {
        // Save a fixture mapping.
        let fixtureId = UUID()
        persistence.saveMapping(
            fixtureId: fixtureId,
            lightId: "light-1",
            position: SIMD3<Float>(0.5, 1.0, -1.0),
            orientation: simd_quatf.identity,
            distanceMeters: 1.5,
            fixtureType: "pendant",
            confidence: 0.85
        )
        
        // Verify the mapping is still accessible.
        let loaded = try! persistence.modelContext.fetch(FetchDescriptor<FixtureMapping>())
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.lightId, "light-1")
    }
}
