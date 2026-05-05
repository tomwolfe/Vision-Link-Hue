import XCTest
import Vision
import @testable VisionLinkHue

/// Unit tests for the safe ClosedRange helper in FixtureHeuristicClassifier.
/// Validates that inverted OTA JSON ranges are handled gracefully without crashes.
final class FixtureHeuristicClassifierSafeRangeTests: XCTestCase {
    
    func testSafeRangeHandlesInvertedBounds() {
        // Simulate an OTA JSON typo that ships an inverted range [0.8, 0.2].
        // The safeClosedRange helper should normalize this to [0.2, 0.8].
        let inverted = [0.8, 0.2]
        let range = safeClosedRange(inverted)
        
        XCTAssertNotNil(range, "Safe range should handle inverted bounds")
        XCTAssertEqual(range?.lowerBound, 0.2, "Lower bound should be the minimum")
        XCTAssertEqual(range?.upperBound, 0.8, "Upper bound should be the maximum")
    }
    
    func testSafeRangeHandlesNormalBounds() {
        // Normal ordered bounds should pass through unchanged.
        let normal = [0.2, 0.8]
        let range = safeClosedRange(normal)
        
        XCTAssertNotNil(range, "Safe range should handle normal bounds")
        XCTAssertEqual(range?.lowerBound, 0.2, "Lower bound should match")
        XCTAssertEqual(range?.upperBound, 0.8, "Upper bound should match")
    }
    
    func testSafeRangeHandlesEqualBounds() {
        // Equal bounds should create a single-value range.
        let equal = [0.5, 0.5]
        let range = safeClosedRange(equal)
        
        XCTAssertNotNil(range, "Safe range should handle equal bounds")
        XCTAssertEqual(range?.lowerBound, 0.5, "Lower bound should be 0.5")
        XCTAssertEqual(range?.upperBound, 0.5, "Upper bound should be 0.5")
    }
    
    func testSafeRangeReturnsNilForInvalidCount() {
        let invalid = [0.2]
        XCTAssertNil(safeClosedRange(invalid), "Single element should return nil")
        
        let tooMany = [0.1, 0.5, 0.9]
        XCTAssertNil(safeClosedRange(tooMany), "Three elements should return nil")
    }
    
    func testClassifierHandlesInvertedRangeFromJSON() async throws {
        // Create a temporary JSON file with an inverted aspect range.
        let json = """
        {
            "version": "1.2.0",
            "rules": [
                {
                    "type": "lamp",
                    "aspectRange": [0.8, 0.2],
                    "weight": 5.0
                }
            ]
        }
        """
        
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_rules.json")
        try json.write(to: tempURL, atomically: true, encoding: .utf8)
        
        var classifier = FixtureHeuristicClassifier()
        
        // Should not crash when loading inverted range.
        try await classifier.loadRules(from: tempURL)
        
        // Classify a wide object that should match the normalized range [0.2, 0.8].
        let observation = VNRectangleObservation(
            box: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        )
        let type = classifier.classify(typeFrom: observation)
        
        // The wide aspect ratio (1.0) should match the normalized range.
        XCTAssertNotNil(type, "Classification should succeed with inverted OTA range")
        
        // Cleanup
        try? FileManager.default.removeItem(at: tempURL)
    }
}
