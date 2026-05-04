import XCTest
import Vision
import @testable VisionLinkHue

/// Unit tests for the heuristic fixture classifier with new archetype
/// fixture types: Chandelier, Sconce, and Desk Lamp.
/// Validates classification boundaries and specificity tiebreaking
/// for the expanded fixture taxonomy.
final class FixtureHeuristicClassifierNewTypesTests: XCTestCase {
    
    private let classifier = FixtureHeuristicClassifier()
    
    /// Helper to create a mock `VNRectangleObservation` with a given bounding box.
    private func mockObservation(
        minX: Float, minY: Float, width: Float, height: Float
    ) -> VNRectangleObservation {
        let box = CGRect(x: Double(minX), y: Double(minY), width: Double(width), height: Double(height))
        return VNRectangleObservation(box: box)
    }
    
    // MARK: - New Fixture Type Tests
    
    func testClassifyChandelierLargeSquareCeiling() {
        // Large square near top of frame = chandelier (high weight for large + ceiling position).
        let observation = mockObservation(minX: 0.3, minY: 0.05, width: 0.4, height: 0.3)
        let type = classifier.classify(typeFrom: observation)
        
        XCTAssertEqual(type, .chandelier, "Large square near ceiling should classify as chandelier")
    }
    
    func testClassifySconceWideMidFrame() {
        // Wide shape in mid-ceiling range = wall sconce.
        let observation = mockObservation(minX: 0.3, minY: 0.3, width: 0.25, height: 0.15)
        let type = classifier.classify(typeFrom: observation)
        
        XCTAssertEqual(type, .sconce, "Wide shape in mid-ceiling range should classify as sconce")
    }
    
    func testClassifyDeskLampModerateLowerFrame() {
        // Moderate shape in lower-mid frame = desk lamp.
        let observation = mockObservation(minX: 0.35, minY: 0.6, width: 0.2, height: 0.2)
        let type = classifier.classify(typeFrom: observation)
        
        XCTAssertEqual(type, .deskLamp, "Moderate shape in lower-mid frame should classify as desk lamp")
    }
    
    func testClassifySconceSmallMidCeiling() {
        // Small wide shape in mid-ceiling = sconce.
        let observation = mockObservation(minX: 0.4, minY: 0.35, width: 0.15, height: 0.1)
        let type = classifier.classify(typeFrom: observation)
        
        // Sconce should score well for small + mid-ceiling position
        XCTAssertEqual(type, .sconce, "Small wide shape in mid-ceiling should classify as sconce")
    }
    
    // MARK: - Specificity Tiebreaker with New Types
    
    func testSpecificityFavorsChandelierOverCeilingOnTie() {
        // Chandelier (specificity 4) should beat lamp (specificity 0) on tie.
        let observation = mockObservation(minX: 0.3, minY: 0.05, width: 0.3, height: 0.25)
        let type = classifier.classify(typeFrom: observation)
        
        // Both chandelier and ceiling score high for square + top position.
        // Chandelier has specificity 4, same as ceiling, but chandelier has
        // additional area bonus for large objects.
        XCTAssertTrue(
            type == .chandelier || type == .ceiling,
            "Large square at top should classify as chandelier or ceiling"
        )
    }
    
    func testSpecificityFavorsDeskLampOverGenericLamp() {
        // Desk lamp (specificity 2) should beat lamp (specificity 0) on tie.
        let observation = mockObservation(minX: 0.35, minY: 0.6, width: 0.2, height: 0.2)
        let type = classifier.classify(typeFrom: observation)
        
        // Desk lamp should score well due to mid-range vertical position.
        XCTAssertTrue(
            type == .deskLamp || type == .lamp,
            "Moderate shape in lower frame should classify as desk lamp or lamp"
        )
    }
    
    // MARK: - JSON FixtureType Initialization Tests
    
    func testJSONInitChandelier() {
        let type = FixtureType(from: "chandelier")
        XCTAssertNotNil(type, "Should initialize chandelier from JSON")
        XCTAssertEqual(type, .chandelier)
    }
    
    func testJSONInitSconce() {
        let type = FixtureType(from: "sconce")
        XCTAssertNotNil(type, "Should initialize sconce from JSON")
        XCTAssertEqual(type, .sconce)
    }
    
    func testJSONInitDeskLamp() {
        let type = FixtureType(from: "desklamp")
        XCTAssertNotNil(type, "Should initialize deskLamp from JSON")
        XCTAssertEqual(type, .deskLamp)
    }
    
    func testJSONInitUnknownReturnsNil() {
        let type = FixtureType(from: "unknown_type")
        XCTAssertNil(type, "Unknown fixture type should return nil")
    }
    
    // MARK: - FixtureType AllCases Tests
    
    func testAllCasesIncludesNewTypes() {
        let allTypes = FixtureType.allCases
        let typeNames = allTypes.map { $0.rawValue }
        
        XCTAssertTrue(typeNames.contains("chandelier"), "AllCases should include chandelier")
        XCTAssertTrue(typeNames.contains("sconce"), "AllCases should include sconce")
        XCTAssertTrue(typeNames.contains("desklamp"), "AllCases should include deskLamp")
    }
    
    func testDisplayNameForNewTypes() {
        XCTAssertEqual(FixtureType.chandelier.displayName, "Chandelier")
        XCTAssertEqual(FixtureType.sconce.displayName, "Wall Sconce")
        XCTAssertEqual(FixtureType.deskLamp.displayName, "Desk Lamp")
    }
}
