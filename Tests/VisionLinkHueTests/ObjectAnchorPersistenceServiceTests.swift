import XCTest
import @testable VisionLinkHue
import simd

/// Unit tests for ObjectAnchorPersistenceService, validating fixture
/// archetype registration, persistence, and relocalization matching.
final class ObjectAnchorPersistenceServiceTests: XCTestCase {
    
    private var service: ObjectAnchorPersistenceService!
    
    override func setUp() {
        super.setUp()
        service = ObjectAnchorPersistenceService()
        // Clear any persisted data between tests
        service.clearAllArchetypes()
    }
    
    override func tearDown() {
        service?.clearAllArchetypes()
        service = nil
        super.tearDown()
    }
    
    // MARK: - Initial State Tests
    
    func testServiceStartsWithNoArchetypes() {
        XCTAssertFalse(service.hasActiveAnchors)
        XCTAssertTrue(service.archetypes.isEmpty)
        XCTAssertFalse(service.isRelocalized)
        XCTAssertNil(service.matchedArchetype)
    }
    
    // MARK: - Archetype Registration Tests
    
    func testRegisterArchetypalFixture() {
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0))
        
        service.registerArchetype(
            fixtureType: .chandelier,
            objectAnchorName: "fixture_chandelier_abc12345",
            position: position,
            orientation: orientation,
            confidence: 0.85
        )
        
        XCTAssertEqual(service.archetypes.count, 1)
        XCTAssertEqual(service.archetypes[0].fixtureType, .chandelier)
        XCTAssertEqual(service.archetypes[0].confidence, 0.85)
        XCTAssertTrue(service.hasActiveAnchors)
    }
    
    func testRegisterNonArchetypalFixtureIsSkipped() {
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0))
        
        service.registerArchetype(
            fixtureType: .recessed,
            objectAnchorName: "fixture_recessed_xyz78901",
            position: position,
            orientation: orientation,
            confidence: 0.90
        )
        
        XCTAssertTrue(service.archetypes.isEmpty)
        XCTAssertFalse(service.hasActiveAnchors)
    }
    
    func testRegisterMultipleArchetypes() {
        let positions: [SIMD3<Float>] = [
            SIMD3<Float>(1, 2, 3),
            SIMD3<Float>(4, 5, 6),
            SIMD3<Float>(7, 8, 9)
        ]
        let types: [FixtureType] = [.chandelier, .sconce, .deskLamp]
        
        for (i, type) in types.enumerated() {
            service.registerArchetype(
                fixtureType: type,
                objectAnchorName: "fixture_\(type.rawValue)_\(i)",
                position: positions[i],
                orientation: simd_quatf.identity,
                confidence: 0.8
            )
        }
        
        XCTAssertEqual(service.archetypes.count, 3)
        XCTAssertTrue(service.hasActiveAnchors)
    }
    
    func testUnarchetypalTypes() {
        let position = SIMD3<Float>(1, 2, 3)
        let orientation = simd_quatf.identity
        
        // These types should NOT be registered as archetypes
        let nonArchetypalTypes: [FixtureType] = [.lamp, .recessed, .ceiling, .strip]
        
        for type in nonArchetypalTypes {
            service.registerArchetype(
                fixtureType: type,
                objectAnchorName: "test",
                position: position,
                orientation: orientation,
                confidence: 0.9
            )
        }
        
        XCTAssertTrue(service.archetypes.isEmpty)
    }
    
    // MARK: - Archetype Removal Tests
    
    func testRemoveArchetype() {
        service.registerArchetype(
            fixtureType: .chandelier,
            objectAnchorName: "test_anchor",
            position: SIMD3<Float>(1, 2, 3),
            orientation: simd_quatf.identity,
            confidence: 0.8
        )
        
        let id = service.archetypes[0].id
        service.removeArchetype(for: id)
        
        XCTAssertTrue(service.archetypes.isEmpty)
        XCTAssertFalse(service.hasActiveAnchors)
    }
    
    func testClearAllArchetypes() {
        for i in 0..<3 {
            service.registerArchetype(
                fixtureType: .chandelier,
                objectAnchorName: "anchor_\(i)",
                position: SIMD3<Float>(Float(i), 0, 0),
                orientation: simd_quatf.identity,
                confidence: 0.8
            )
        }
        
        service.clearAllArchetypes()
        
        XCTAssertTrue(service.archetypes.isEmpty)
        XCTAssertFalse(service.hasActiveAnchors)
        XCTAssertFalse(service.isRelocalized)
        XCTAssertNil(service.matchedArchetype)
    }
    
    // MARK: - Relocalization Tests
    
    func testMatchObjectAnchors() {
        service.registerArchetype(
            fixtureType: .chandelier,
            objectAnchorName: "fixture_chandelier_abc12345",
            position: SIMD3<Float>(1, 2, 3),
            orientation: simd_quatf.identity,
            confidence: 0.85
        )
        
        // Simulate ARKit finding the anchor
        service.matchObjectAnchors(to: ["fixture_chandelier_abc12345", "other_anchor"])
        
        XCTAssertTrue(service.isRelocalized)
        XCTAssertNotNil(service.matchedArchetype)
        XCTAssertEqual(service.matchedArchetype?.fixtureType, .chandelier)
    }
    
    func testMatchObjectAnchorsNoMatch() {
        service.registerArchetype(
            fixtureType: .sconce,
            objectAnchorName: "fixture_sconce_xyz78901",
            position: SIMD3<Float>(1, 2, 3),
            orientation: simd_quatf.identity,
            confidence: 0.75
        )
        
        // ARKit finds different anchors
        service.matchObjectAnchors(to: ["other_anchor_1", "other_anchor_2"])
        
        XCTAssertFalse(service.isRelocalized)
        XCTAssertNil(service.matchedArchetype)
    }
    
    func testMatchObjectAnchorsAlreadyMatchedSkipped() {
        service.registerArchetype(
            fixtureType: .chandelier,
            objectAnchorName: "anchor_chandelier",
            position: SIMD3<Float>(1, 2, 3),
            orientation: simd_quatf.identity,
            confidence: 0.8
        )
        
        service.registerArchetype(
            fixtureType: .sconce,
            objectAnchorName: "anchor_sconce",
            position: SIMD3<Float>(4, 5, 6),
            orientation: simd_quatf.identity,
            confidence: 0.7
        )
        
        // Match first archetype
        service.matchObjectAnchors(to: ["anchor_chandelier"])
        XCTAssertTrue(service.isRelocalized)
        
        // Try matching again with both anchors - chandelier should be skipped
        service.matchObjectAnchors(to: ["anchor_chandelier", "anchor_sconce"])
        
        // Still only one matched (the sconce should now match)
        XCTAssertTrue(service.isRelocalized)
    }
    
    func testUpdateMatchedAnchorID() {
        service.registerArchetype(
            fixtureType: .deskLamp,
            objectAnchorName: "fixture_desklamp_def45678",
            position: SIMD3<Float>(1, 2, 3),
            orientation: simd_quatf.identity,
            confidence: 0.9
        )
        
        let archetypeID = service.archetypes[0].id
        service.updateMatchedAnchorID(for: archetypeID, anchorID: "AR_anchor_abc")
        
        XCTAssertEqual(service.archetypes[0].matchedAnchorID, "AR_anchor_abc")
    }
    
    // MARK: - Grouping Tests
    
    func testArchetypesByType() {
        service.registerArchetype(
            fixtureType: .chandelier,
            objectAnchorName: "chandelier_1",
            position: SIMD3<Float>(1, 2, 3),
            orientation: simd_quatf.identity,
            confidence: 0.8
        )
        
        service.registerArchetype(
            fixtureType: .chandelier,
            objectAnchorName: "chandelier_2",
            position: SIMD3<Float>(4, 5, 6),
            orientation: simd_quatf.identity,
            confidence: 0.7
        )
        
        service.registerArchetype(
            fixtureType: .sconce,
            objectAnchorName: "sconce_1",
            position: SIMD3<Float>(7, 8, 9),
            orientation: simd_quatf.identity,
            confidence: 0.9
        )
        
        let grouped = service.archetypesByType()
        XCTAssertEqual(grouped[.chandelier]?.count, 2)
        XCTAssertEqual(grouped[.sconce]?.count, 1)
    }
    
    func testUnmatchedCount() {
        service.registerArchetype(
            fixtureType: .chandelier,
            objectAnchorName: "anchor_1",
            position: SIMD3<Float>(1, 2, 3),
            orientation: simd_quatf.identity,
            confidence: 0.8
        )
        
        service.registerArchetype(
            fixtureType: .sconce,
            objectAnchorName: "anchor_2",
            position: SIMD3<Float>(4, 5, 6),
            orientation: simd_quatf.identity,
            confidence: 0.7
        )
        
        XCTAssertEqual(service.unmatchedCount, 2)
        
        // Match one
        service.matchObjectAnchors(to: ["anchor_1"])
        XCTAssertEqual(service.unmatchedCount, 1)
    }
    
    // MARK: - FixtureArchetype Tests
    
    func testFixtureArchetypeCreation() {
        let archetype = FixtureArchetype(
            fixtureType: .pendant,
            objectAnchorName: "test_pendant",
            position: SIMD3<Float>(1, 2, 3),
            orientation: simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0)),
            confidence: 0.75
        )
        
        XCTAssertNotNil(archetype.id)
        XCTAssertEqual(archetype.fixtureType, .pendant)
        XCTAssertEqual(archetype.objectAnchorName, "test_pendant")
        XCTAssertEqual(archetype.confidence, 0.75)
        XCTAssertFalse(archetype.isMatched)
        XCTAssertNil(archetype.matchedAnchorID)
    }
}
