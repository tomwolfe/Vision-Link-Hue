import XCTest
@testable import VisionLinkHue
import simd

/// Unit tests for ObjectAnchorPersistenceService, validating fixture
/// archetype registration, persistence, and relocalization matching.
@MainActor
final class ObjectAnchorPersistenceServiceTests: XCTestCase {
    
    private var service: ObjectAnchorPersistenceService!
    
    override func setUp() async throws {
        try await super.setUp()
        service = await MainActor.run { ObjectAnchorPersistenceService() }
        // Clear any persisted data between tests
        await MainActor.run { service.clearAllArchetypes() }
    }
    
    override func tearDown() async throws {
        await MainActor.run { service?.clearAllArchetypes() }
        service = nil
        try await super.tearDown()
    }
    
    // MARK: - Initial State Tests
    
    func testServiceStartsWithNoArchetypes() async {
        let hasActiveAnchors = await service.hasActiveAnchors
        XCTAssertFalse(hasActiveAnchors)
        let archetypes = await service.archetypes
        XCTAssertTrue(archetypes.isEmpty)
        let isRelocalized = await service.isRelocalized
        XCTAssertFalse(isRelocalized)
        let matchedArchetype = await service.matchedArchetype
        XCTAssertNil(matchedArchetype)
    }
    
    // MARK: - Archetype Registration Tests
    
    func testRegisterArchetypalFixture() async {
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0))
        
        await MainActor.run {
            service.registerArchetype(
                fixtureType: .chandelier,
                objectAnchorName: "fixture_chandelier_abc12345",
                position: position,
                orientation: orientation,
                confidence: 0.85
            )
        }
        
        let archetypes = await service.archetypes
        XCTAssertEqual(archetypes.count, 1)
        XCTAssertEqual(archetypes[0].fixtureType, .chandelier)
        XCTAssertEqual(archetypes[0].confidence, 0.85)
        let hasActiveAnchors = await service.hasActiveAnchors
        XCTAssertTrue(hasActiveAnchors)
    }
    
    func testRegisterNonArchetypalFixtureIsSkipped() async {
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0))
        
        await MainActor.run {
            service.registerArchetype(
                fixtureType: .recessed,
                objectAnchorName: "fixture_recessed_xyz78901",
                position: position,
                orientation: orientation,
                confidence: 0.90
            )
        }
        
        let archetypes = await service.archetypes
        XCTAssertTrue(archetypes.isEmpty)
        let hasActiveAnchors = await service.hasActiveAnchors
        XCTAssertFalse(hasActiveAnchors)
    }
    
    func testRegisterMultipleArchetypes() async {
        let positions: [SIMD3<Float>] = [
            SIMD3<Float>(1, 2, 3),
            SIMD3<Float>(4, 5, 6),
            SIMD3<Float>(7, 8, 9)
        ]
        let types: [FixtureType] = [.chandelier, .sconce, .deskLamp]
        
        for (i, type) in types.enumerated() {
            await MainActor.run {
                service.registerArchetype(
                    fixtureType: type,
                    objectAnchorName: "fixture_\(type.rawValue)_\(i)",
                    position: positions[i],
                    orientation: simd_quatf(),
                    confidence: 0.8
                )
            }
        }
        
        let archetypes = await service.archetypes
        XCTAssertEqual(archetypes.count, 3)
        let hasActiveAnchors = await service.hasActiveAnchors
        XCTAssertTrue(hasActiveAnchors)
    }
    
    func testUnarchetypalTypes() async {
        let position = SIMD3<Float>(1, 2, 3)
        let orientation = simd_quatf()
        
        // These types should NOT be registered as archetypes
        let nonArchetypalTypes: [FixtureType] = [.lamp, .recessed, .ceiling, .strip]
        
        for type in nonArchetypalTypes {
            await MainActor.run {
                service.registerArchetype(
                    fixtureType: type,
                    objectAnchorName: "test",
                    position: position,
                    orientation: orientation,
                    confidence: 0.9
                )
            }
        }
        
        let archetypes = await service.archetypes
        XCTAssertTrue(archetypes.isEmpty)
    }
    
    // MARK: - Archetype Removal Tests
    
    func testRemoveArchetype() async {
        await MainActor.run {
            service.registerArchetype(
                fixtureType: .chandelier,
                objectAnchorName: "test_anchor",
                position: SIMD3<Float>(1, 2, 3),
                orientation: simd_quatf(),
                confidence: 0.8
            )
        }
        
        let archetypes = await service.archetypes
        let id = archetypes[0].id
        await MainActor.run { service.removeArchetype(for: id) }
        
        let remaining = await service.archetypes
        XCTAssertTrue(remaining.isEmpty)
        let hasActiveAnchors = await service.hasActiveAnchors
        XCTAssertFalse(hasActiveAnchors)
    }
    
    func testClearAllArchetypes() async {
        for i in 0..<3 {
            await MainActor.run {
                service.registerArchetype(
                    fixtureType: .chandelier,
                    objectAnchorName: "anchor_\(i)",
                    position: SIMD3<Float>(Float(i), 0, 0),
                    orientation: simd_quatf(),
                    confidence: 0.8
                )
            }
        }
        
        await MainActor.run { service.clearAllArchetypes() }
        
        let archetypes = await service.archetypes
        XCTAssertTrue(archetypes.isEmpty)
        let hasActiveAnchors = await service.hasActiveAnchors
        XCTAssertFalse(hasActiveAnchors)
        let isRelocalized = await service.isRelocalized
        XCTAssertFalse(isRelocalized)
        let matchedArchetype = await service.matchedArchetype
        XCTAssertNil(matchedArchetype)
    }
    
    // MARK: - Relocalization Tests
    
    func testMatchObjectAnchors() async {
        await MainActor.run {
            service.registerArchetype(
                fixtureType: .chandelier,
                objectAnchorName: "fixture_chandelier_abc12345",
                position: SIMD3<Float>(1, 2, 3),
                orientation: simd_quatf(),
                confidence: 0.85
            )
        }
        
        await MainActor.run {
            service.matchObjectAnchors(to: ["fixture_chandelier_abc12345", "other_anchor"])
        }
        
        let isRelocalized = await service.isRelocalized
        XCTAssertTrue(isRelocalized)
        let matchedArchetype = await service.matchedArchetype
        XCTAssertNotNil(matchedArchetype)
        XCTAssertEqual(matchedArchetype?.fixtureType, .chandelier)
    }
    
    func testMatchObjectAnchorsNoMatch() async {
        await MainActor.run {
            service.registerArchetype(
                fixtureType: .sconce,
                objectAnchorName: "fixture_sconce_xyz78901",
                position: SIMD3<Float>(1, 2, 3),
                orientation: simd_quatf(),
                confidence: 0.75
            )
        }
        
        await MainActor.run {
            service.matchObjectAnchors(to: ["other_anchor_1", "other_anchor_2"])
        }
        
        let isRelocalized = await service.isRelocalized
        XCTAssertFalse(isRelocalized)
        let matchedArchetype = await service.matchedArchetype
        XCTAssertNil(matchedArchetype)
    }
    
    func testMatchObjectAnchorsAlreadyMatchedSkipped() async {
        await MainActor.run {
            service.registerArchetype(
                fixtureType: .chandelier,
                objectAnchorName: "anchor_chandelier",
                position: SIMD3<Float>(1, 2, 3),
                orientation: simd_quatf(),
                confidence: 0.8
            )
            service.registerArchetype(
                fixtureType: .sconce,
                objectAnchorName: "anchor_sconce",
                position: SIMD3<Float>(4, 5, 6),
                orientation: simd_quatf(),
                confidence: 0.7
            )
        }
        
        await MainActor.run {
            service.matchObjectAnchors(to: ["anchor_chandelier"])
        }
        let isRelocalized1 = await service.isRelocalized
        XCTAssertTrue(isRelocalized1)
        
        await MainActor.run {
            service.matchObjectAnchors(to: ["anchor_chandelier", "anchor_sconce"])
        }
        
        let isRelocalized2 = await service.isRelocalized
        XCTAssertTrue(isRelocalized2)
    }
    
    func testUpdateMatchedAnchorID() async {
        await MainActor.run {
            service.registerArchetype(
                fixtureType: .deskLamp,
                objectAnchorName: "fixture_desklamp_def45678",
                position: SIMD3<Float>(1, 2, 3),
                orientation: simd_quatf(),
                confidence: 0.9
            )
        }
        
        let archetypes = await service.archetypes
        let archetypeID = archetypes[0].id
        await MainActor.run { service.updateMatchedAnchorID(for: archetypeID, anchorID: "AR_anchor_abc") }
        
        let updated = await service.archetypes
        XCTAssertEqual(updated[0].matchedAnchorID, "AR_anchor_abc")
    }
    
    // MARK: - Grouping Tests
    
    func testArchetypesByType() async {
        await MainActor.run {
            service.registerArchetype(
                fixtureType: .chandelier,
                objectAnchorName: "chandelier_1",
                position: SIMD3<Float>(1, 2, 3),
                orientation: simd_quatf(),
                confidence: 0.8
            )
            service.registerArchetype(
                fixtureType: .chandelier,
                objectAnchorName: "chandelier_2",
                position: SIMD3<Float>(4, 5, 6),
                orientation: simd_quatf(),
                confidence: 0.7
            )
            service.registerArchetype(
                fixtureType: .sconce,
                objectAnchorName: "sconce_1",
                position: SIMD3<Float>(7, 8, 9),
                orientation: simd_quatf(),
                confidence: 0.9
            )
        }
        
        let grouped = await service.archetypesByType()
        XCTAssertEqual(grouped[.chandelier]?.count, 2)
        XCTAssertEqual(grouped[.sconce]?.count, 1)
    }
    
    func testUnmatchedCount() async {
        await MainActor.run {
            service.registerArchetype(
                fixtureType: .chandelier,
                objectAnchorName: "anchor_1",
                position: SIMD3<Float>(1, 2, 3),
                orientation: simd_quatf(),
                confidence: 0.8
            )
            service.registerArchetype(
                fixtureType: .sconce,
                objectAnchorName: "anchor_2",
                position: SIMD3<Float>(4, 5, 6),
                orientation: simd_quatf(),
                confidence: 0.7
            )
        }
        
        let unmatched = await service.unmatchedCount
        XCTAssertEqual(unmatched, 2)
        
        await MainActor.run {
            service.matchObjectAnchors(to: ["anchor_1"])
        }
        let unmatched2 = await service.unmatchedCount
        XCTAssertEqual(unmatched2, 1)
    }
    
    // MARK: - Extended Relocalization Tests
    
    func testExtendedRelocalizationRegistersRecessedFixtures() async {
        let settings = await MainActor.run {
            DetectionSettings()
        }
        await MainActor.run { settings.extendedRelocalizationMode = true }
        let extendedService = await MainActor.run {
            ObjectAnchorPersistenceService(detectionSettings: settings)
        }
        
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0))
        
        await MainActor.run {
            extendedService.registerArchetype(
                fixtureType: .recessed,
                objectAnchorName: "fixture_recessed_extended",
                position: position,
                orientation: orientation,
                confidence: 0.90
            )
        }
        
        let archetypes = await extendedService.archetypes
        XCTAssertEqual(archetypes.count, 1)
        XCTAssertEqual(archetypes[0].fixtureType, .recessed)
        let hasActiveAnchors = await extendedService.hasActiveAnchors
        XCTAssertTrue(hasActiveAnchors)
    }
    
    func testExtendedRelocalizationRegistersCeilingFixtures() async {
        let settings = await MainActor.run {
            DetectionSettings()
        }
        await MainActor.run { settings.extendedRelocalizationMode = true }
        let extendedService = await MainActor.run {
            ObjectAnchorPersistenceService(detectionSettings: settings)
        }
        
        await MainActor.run {
            extendedService.registerArchetype(
                fixtureType: .ceiling,
                objectAnchorName: "fixture_ceiling_extended",
                position: SIMD3<Float>(2, 3, 4),
                orientation: simd_quatf(),
                confidence: 0.85
            )
        }
        
        let archetypes = await extendedService.archetypes
        XCTAssertEqual(archetypes.count, 1)
        XCTAssertEqual(archetypes[0].fixtureType, .ceiling)
    }
    
    func testExtendedRelocalizationRegistersStripFixtures() async {
        let settings = await MainActor.run {
            DetectionSettings()
        }
        await MainActor.run { settings.extendedRelocalizationMode = true }
        let extendedService = await MainActor.run {
            ObjectAnchorPersistenceService(detectionSettings: settings)
        }
        
        await MainActor.run {
            extendedService.registerArchetype(
                fixtureType: .strip,
                objectAnchorName: "fixture_strip_extended",
                position: SIMD3<Float>(3, 4, 5),
                orientation: simd_quatf(),
                confidence: 0.80
            )
        }
        
        let archetypes = await extendedService.archetypes
        XCTAssertEqual(archetypes.count, 1)
        XCTAssertEqual(archetypes[0].fixtureType, .strip)
    }
    
    func testStandardModeStillSkipsRecessedFixtures() async {
        let standardSettings = await MainActor.run {
            DetectionSettings()
        }
        await MainActor.run { standardSettings.extendedRelocalizationMode = false }
        let standardService = await MainActor.run {
            ObjectAnchorPersistenceService(detectionSettings: standardSettings)
        }
        
        await MainActor.run {
            standardService.registerArchetype(
                fixtureType: .recessed,
                objectAnchorName: "fixture_recessed_standard",
                position: SIMD3<Float>(1, 2, 3),
                orientation: simd_quatf(),
                confidence: 0.90
            )
        }
        
        let archetypes = await standardService.archetypes
        XCTAssertTrue(archetypes.isEmpty)
        let hasActiveAnchors = await standardService.hasActiveAnchors
        XCTAssertFalse(hasActiveAnchors)
    }
    
    func testExtendedModeStillSkipsLampFixtures() async {
        let settings = await MainActor.run {
            DetectionSettings()
        }
        await MainActor.run { settings.extendedRelocalizationMode = true }
        let extendedService = await MainActor.run {
            ObjectAnchorPersistenceService(detectionSettings: settings)
        }
        
        await MainActor.run {
            extendedService.registerArchetype(
                fixtureType: .lamp,
                objectAnchorName: "fixture_lamp_extended",
                position: SIMD3<Float>(1, 2, 3),
                orientation: simd_quatf(),
                confidence: 0.85
            )
        }
        
        let archetypes = await extendedService.archetypes
        XCTAssertTrue(archetypes.isEmpty)
    }
    
    // MARK: - FixtureArchetype Tests
    
    func testFixtureArchetypeCreation() async {
        let archetype = await MainActor.run {
            FixtureArchetype(
                fixtureType: .pendant,
                objectAnchorName: "test_pendant",
                position: SIMD3<Float>(1, 2, 3),
                orientation: simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0)),
                confidence: 0.75
            )
        }
        
        XCTAssertNotNil(archetype.id)
        XCTAssertEqual(archetype.fixtureType, .pendant)
        XCTAssertEqual(archetype.objectAnchorName, "test_pendant")
        XCTAssertEqual(archetype.confidence, 0.75)
        XCTAssertFalse(archetype.isMatched)
        XCTAssertNil(archetype.matchedAnchorID)
    }
}
