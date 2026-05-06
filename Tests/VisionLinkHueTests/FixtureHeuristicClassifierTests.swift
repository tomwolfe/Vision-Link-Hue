import XCTest
import Vision
import @testable VisionLinkHue

/// Unit tests for the heuristic fixture classifier.
/// Uses mocked `VNRectangleObservation` objects to validate classification
/// boundaries and confidence scoring without requiring ARKit/Vision hardware.
final class FixtureHeuristicClassifierTests: XCTestCase {
    
    private let classifier = FixtureHeuristicClassifier()
    
    // MARK: - Mock VNRectangleObservation
    
    /// Helper to create a mock `VNRectangleObservation` with a given bounding box.
    private func mockObservation(
        minX: Float, minY: Float, width: Float, height: Float
    ) -> VNRectangleObservation {
        let box = CGRect(x: Double(minX), y: Double(minY), width: Double(width), height: Double(height))
        return VNRectangleObservation(box: box)
    }
    
    // MARK: - Classification Tests
    
    func testClassifySquareCeilingFixture() {
        // Square shape near top of frame = ceiling fixture.
        let observation = mockObservation(minX: 0.4, minY: 0.05, width: 0.2, height: 0.2)
        let type = classifier.classify(typeFrom: observation)
        
        XCTAssertEqual(type, .ceiling, "Square shape near top should classify as ceiling")
    }
    
    func testClassifySmallSquareRecessedFixture() {
        // Small square shape = recessed fixture.
        let observation = mockObservation(minX: 0.4, minY: 0.1, width: 0.1, height: 0.1)
        let type = classifier.classify(typeFrom: observation)
        
        XCTAssertEqual(type, .recessed, "Small square should classify as recessed")
    }
    
    func testClassifyModerateRectangularPendant() {
        // Moderate aspect ratio in upper-mid frame = pendant.
        let observation = mockObservation(minX: 0.35, minY: 0.15, width: 0.25, height: 0.25)
        let type = classifier.classify(typeFrom: observation)
        
        XCTAssertEqual(type, .pendant, "Moderate rectangle in upper frame should classify as pendant")
    }
    
    func testClassifyWideLampFixture() {
        // Wide aspect ratio in lower-mid frame = lamp.
        let observation = mockObservation(minX: 0.3, minY: 0.6, width: 0.3, height: 0.15)
        let type = classifier.classify(typeFrom: observation)
        
        XCTAssertEqual(type, .lamp, "Wide shape in lower frame should classify as lamp")
    }
    
    func testClassifyStripLight() {
        // Very wide aspect ratio = strip light.
        let observation = mockObservation(minX: 0.1, minY: 0.05, width: 0.8, height: 0.05)
        let type = classifier.classify(typeFrom: observation)
        
        XCTAssertEqual(type, .strip, "Very wide shape should classify as strip light")
    }
    
    func testClassifyFiltersOutBottomOfFrame() {
        // Objects near the bottom of the frame should be filtered out.
        let observation = mockObservation(minX: 0.4, minY: 0.85, width: 0.2, height: 0.2)
        // DetectionEngine classifiesFixtures filters by minY < 0.8, so this
        // observation would never reach the classifier. We verify the classifier
        // still produces a reasonable result for completeness.
        let type = classifier.classify(typeFrom: observation)
        // The classifier defaults to .lamp when nothing matches well.
        XCTAssertEqual(type, .lamp, "Out-of-range observation should default to lamp")
    }
    
    // MARK: - Confidence Tests
    
    func testCalculateConfidenceForWellSizedObject() {
        // Object in the 0.01-0.5 area range gets +0.15 confidence.
        let observation = mockObservation(minX: 0.3, minY: 0.2, width: 0.15, height: 0.15)
        let confidence = classifier.calculateConfidence(from: observation)
        
        // Base 0.7 + 0.15 (area 0.0225 in 0.01-0.5 range) + 0.05 (area 0.0225 in 0.05-0.3 range? No, 0.0225 < 0.05)
        // Actually area = 0.0225, which is > 0.01 and < 0.5, so +0.15.
        // 0.0225 is NOT > 0.05, so no +0.05.
        // Distance from center: sqrt((0.375-0.5)^2 + (0.275-0.5)^2) = sqrt(0.015625 + 0.050625) = sqrt(0.06625) = 0.257 < 0.3, so +0.05.
        // Total: 0.7 + 0.15 + 0.05 = 0.9
        XCTAssertGreaterThan(confidence, 0.7, "Well-sized object should have confidence above base")
        XCTAssertLessThanOrEqual(confidence, 0.99, "Confidence should not exceed 0.99")
    }
    
    func testCalculateConfidenceForCenteredObject() {
        // Object at center gets +0.05 for proximity to center.
        let observation = mockObservation(minX: 0.4, minY: 0.4, width: 0.2, height: 0.2)
        let confidence = classifier.calculateConfidence(from: observation)
        
        XCTAssertGreaterThan(confidence, 0.7, "Centered object should have confidence above base")
    }
    
    func testCalculateConfidenceForTooSmallObject() {
        // Very small object gets no area bonus.
        let observation = mockObservation(minX: 0.45, minY: 0.45, width: 0.01, height: 0.01)
        let confidence = classifier.calculateConfidence(from: observation)
        
        // Base 0.7 only, no bonuses.
        XCTAssertEqual(confidence, 0.7, accuracy: 0.001, "Very small object should have base confidence only")
    }
    
    func testCalculateConfidenceIsCappedAt099() {
        // Large, centered object should be capped at 0.99.
        let observation = mockObservation(minX: 0.35, minY: 0.35, width: 0.3, height: 0.3)
        let confidence = classifier.calculateConfidence(from: observation)
        
        XCTAssertEqual(confidence, 0.99, accuracy: 0.001, "Confidence should be capped at 0.99")
    }
    
    // MARK: - Specificity Tiebreaker Tests
    
    func testSpecificityFavorsCeilingOverRecessedOnTie() {
        // When scores are tied, ceiling (specificity 4) should beat recessed (specificity 3).
        let observation = mockObservation(minX: 0.4, minY: 0.05, width: 0.2, height: 0.2)
        let type = classifier.classify(typeFrom: observation)
        
        // Both ceiling and recessed score high for square + top position.
        // Ceiling has higher specificity, so it should win.
        XCTAssertEqual(type, .ceiling, "Tie should favor higher-specificity ceiling over recessed")
    }
    
    // MARK: - World-Space Height Classification Tests
    
    /// Helper to create `ObservationData` with optional world-space height.
    private func mockObservationData(
        minX: Float, minY: Float, width: Float, height: Float,
        worldSpaceHeightMeters: Float? = nil
    ) -> ObservationData {
        let box = CGRect(x: Double(minX), y: Double(minY), width: Double(width), height: Double(height))
        return ObservationData(boundingBox: box, worldSpaceHeightMeters: worldSpaceHeightMeters)
    }
    
    func testWorldSpaceHeightClassifiesCeilingFixtureCorrectly() {
        // When camera points straight up at ceiling light, the bounding box
        // center is at midY = 0.5 (center of frame). Without world-space height,
        // this would incorrectly score as a mid-range object. With world-space
        // height of 2.5m, it correctly classifies as ceiling.
        let observation = mockObservationData(minX: 0.4, minY: 0.4, width: 0.2, height: 0.2, worldSpaceHeightMeters: 2.5)
        let type = classifier.classify(typeFrom: observation)
        
        XCTAssertEqual(type, .ceiling, "World-space height 2.5m should classify as ceiling even when camera points straight up")
    }
    
    func testWorldSpaceHeightClassifiesPendantLightCorrectly() {
        // Pendant light at 1.5m above floor, even when centered in frame.
        let observation = mockObservationData(minX: 0.35, minY: 0.35, width: 0.25, height: 0.25, worldSpaceHeightMeters: 1.5)
        let type = classifier.classify(typeFrom: observation)
        
        XCTAssertEqual(type, .pendant, "World-space height 1.5m should classify as pendant")
    }
    
    func testWorldSpaceHeightClassifiesFloorLampCorrectly() {
        // Floor lamp at 0.5m above floor.
        let observation = mockObservationData(minX: 0.4, minY: 0.6, width: 0.2, height: 0.2, worldSpaceHeightMeters: 0.5)
        let type = classifier.classify(typeFrom: observation)
        
        XCTAssertEqual(type, .lamp, "World-space height 0.5m should classify as lamp")
    }
    
    func testWorldSpaceHeightClassifiesDeskLampCorrectly() {
        // Desk lamp at 0.6m above floor (on desk surface).
        let observation = mockObservationData(minX: 0.4, minY: 0.5, width: 0.15, height: 0.15, worldSpaceHeightMeters: 0.6)
        let type = classifier.classify(typeFrom: observation)
        
        XCTAssertEqual(type, .deskLamp, "World-space height 0.6m should classify as desk lamp")
    }
    
    func testWorldSpaceHeightClassifiesSconceCorrectly() {
        // Wall sconce at 1.8m above floor.
        let observation = mockObservationData(minX: 0.4, minY: 0.3, width: 0.15, height: 0.2, worldSpaceHeightMeters: 1.8)
        let type = classifier.classify(typeFrom: observation)
        
        XCTAssertEqual(type, .sconce, "World-space height 1.8m should classify as sconce")
    }
    
    func testWorldSpaceHeightClassifiesRecessedLightCorrectly() {
        // Recessed light flush with ceiling at 2.4m.
        let observation = mockObservationData(minX: 0.45, minY: 0.1, width: 0.1, height: 0.1, worldSpaceHeightMeters: 2.4)
        let type = classifier.classify(typeFrom: observation)
        
        XCTAssertEqual(type, .recessed, "World-space height 2.4m with small square should classify as recessed")
    }
    
    func testObservationWithoutWorldSpaceHeightStillWorks() {
        // When worldSpaceHeightMeters is nil, classification falls back to
        // 2D normalized Y position (existing behavior).
        let observation = mockObservationData(minX: 0.4, minY: 0.05, width: 0.2, height: 0.2, worldSpaceHeightMeters: nil)
        let type = classifier.classify(typeFrom: observation)
        
        XCTAssertEqual(type, .ceiling, "Observation without world-space height should still classify via 2D position")
    }
    
    func testObservationWithoutWorldSpaceHeightIgnoresHeightRules() {
        // When worldSpaceHeightMeters is nil and a rule specifies heightRange,
        // that rule should be skipped (not matched).
        let classifier = FixtureHeuristicClassifier()
        let observation = mockObservationData(minX: 0.4, minY: 0.5, width: 0.2, height: 0.2, worldSpaceHeightMeters: nil)
        let type = classifier.classify(typeFrom: observation)
        
        // Should not be classified as lamp (height rule) since no world-space height available
        // The 2D position rules should still apply
        XCTAssertNotEqual(type, .lamp, "Without world-space height, height-based rules should be skipped")
    }
}
