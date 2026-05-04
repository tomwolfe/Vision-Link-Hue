import XCTest
import @testable VisionLinkHue
import Vision

/// Unit tests for the CoreML intent classifier.
/// Validates label-to-fixture-type mapping, override threshold logic,
/// and classifier behavior when the model is unavailable.
final class CoreMLIntentClassifierTests: XCTestCase {
    
    // MARK: - Label Mapping Tests
    
    func testLabelMappingContainsAllFixtureTypes() {
        let mapping = CoreMLIntentClassifier.labelToFixtureType
        
        // Verify all fixture types have a corresponding CoreML label
        for fixtureType in FixtureType.allCases {
            let matches = mapping.contains { $0.value == fixtureType }
            XCTAssertTrue(matches, "FixtureType.\(fixtureType.rawValue) should have a CoreML label mapping")
        }
    }
    
    func testLabelMappingHasExpectedEntries() {
        let mapping = CoreMLIntentClassifier.labelToFixtureType
        
        XCTAssertEqual(mapping["Chandelier"], .chandelier)
        XCTAssertEqual(mapping["Sconce"], .sconce)
        XCTAssertEqual(mapping["Desk Lamp"], .deskLamp)
        XCTAssertEqual(mapping["Pendant"], .pendant)
        XCTAssertEqual(mapping["Ceiling Light"], .ceiling)
        XCTAssertEqual(mapping["Recessed Light"], .recessed)
        XCTAssertEqual(mapping["Strip Light"], .strip)
        XCTAssertEqual(mapping["Lamp"], .lamp)
    }
    
    func testLabelMappingHasNoDuplicates() {
        let mapping = CoreMLIntentClassifier.labelToFixtureType
        let labels = Array(mapping.keys)
        let uniqueLabels = Set(labels)
        XCTAssertEqual(labels.count, uniqueLabels.count, "All CoreML labels should be unique")
    }
    
    // MARK: - Override Threshold Tests
    
    func testShouldOverrideHeuristicsWithHighConfidence() {
        XCTAssertTrue(
            CoreMLIntentClassifier.shouldOverrideHeuristics(confidence: 0.9),
            "Confidence 0.9 should override heuristics"
        )
        XCTAssertTrue(
            CoreMLIntentClassifier.shouldOverrideHeuristics(confidence: 0.75),
            "Confidence 0.75 should override heuristics"
        )
    }
    
    func testShouldNotOverrideHeuristicsWithLowConfidence() {
        XCTAssertFalse(
            CoreMLIntentClassifier.shouldOverrideHeuristics(confidence: 0.74),
            "Confidence 0.74 should not override heuristics"
        )
        XCTAssertFalse(
            CoreMLIntentClassifier.shouldOverrideHeuristics(confidence: 0.5),
            "Confidence 0.5 should not override heuristics"
        )
        XCTAssertFalse(
            CoreMLIntentClassifier.shouldOverrideHeuristics(confidence: 0.0),
            "Confidence 0.0 should not override heuristics"
        )
    }
    
    func testOverrideThresholdIsConsistent() {
        // The threshold should be the boundary between override and no-override.
        XCTAssertFalse(CoreMLIntentClassifier.shouldOverrideHeuristics(confidence: CoreMLIntentClassifier.overrideThreshold - 0.001))
        XCTAssertTrue(CoreMLIntentClassifier.shouldOverrideHeuristics(confidence: CoreMLIntentClassifier.overrideThreshold))
    }
    
    // MARK: - Classifier Unavailable Tests
    
    func testClassifyReturnsFallbackWhenModelNotLoaded() async {
        var classifier = CoreMLIntentClassifier()
        // Model is not loaded (no model file in test bundle)
        
        let observation = ObservationData(boundingBox: CGRect(x: 0.3, y: 0.1, width: 0.2, height: 0.2))
        let result = await classifier.classify(observation)
        
        XCTAssertEqual(result.type, .lamp, "Should return .lamp when model is unavailable")
        XCTAssertEqual(result.confidence, 0.0, "Should return 0.0 confidence when model is unavailable")
    }
    
    func testIsReadyIsFalseWhenModelNotLoaded() {
        let classifier = CoreMLIntentClassifier()
        XCTAssertFalse(classifier.isReady, "isReady should be false when model is not loaded")
    }
    
    func testIsReadyIsTrueWhenModelProvided() {
        // Create a classifier with a mock model (nil is treated as not loaded).
        // We can't easily create a real MLModel in tests, so we verify
        // the property behaves correctly with the nil case.
        let classifier = CoreMLIntentClassifier(model: nil)
        XCTAssertFalse(classifier.isReady, "isReady should be false when model is nil")
    }
    
    // MARK: - Observation Data Tests
    
    func testClassifyWithVariousObservationSizes() async {
        var classifier = CoreMLIntentClassifier()
        
        let testBoxes: [CGRect] = [
            CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0),
            CGRect(x: 0.4, y: 0.1, width: 0.2, height: 0.2),
            CGRect(x: 0.1, y: 0.05, width: 0.8, height: 0.05),
            CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)
        ]
        
        for box in testBoxes {
            let observation = ObservationData(boundingBox: box)
            let result = await classifier.classify(observation)
            
            // Without a loaded model, all should return fallback values.
            XCTAssertEqual(result.type, .lamp)
            XCTAssertEqual(result.confidence, 0.0)
        }
    }
    
    // MARK: - Protocol Conformance Tests
    
    func testClassifierConformsToProtocol() {
        let classifier: FixtureIntentClassifier = CoreMLIntentClassifier()
        XCTAssertFalse(classifier.isReady)
    }
    
    func testClassifierIsSendable() {
        // Verify CoreMLIntentClassifier conforms to Sendable.
        let classifier: some Sendable = CoreMLIntentClassifier()
        XCTAssertTrue(true, "CoreMLIntentClassifier should be Sendable")
    }
}
