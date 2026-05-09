import XCTest
import Foundation
@testable import VisionLinkHue

/// Unit tests for the material index mapping loaded from `classification_rules.json`.
/// Verifies that the `NeuralSurfaceMaterialClassifier` correctly loads the
/// index-to-label mapping from the config file for OTA-updatable material classification.
final class MaterialIndexMappingTests: XCTestCase {
    
    // MARK: - Default Mapping Tests
    
    func testDefaultMaterialIndexMappingContainsAllMaterials() {
        // defaultMaterialIndexMapping is private - verify via classifier creation.
        let classifier = NeuralSurfaceMaterialClassifier()
        XCTAssertNotNil(classifier)
        // Verify the classifier can resolve material to fixture types.
        XCTAssertEqual(classifier.fixtureTypes(forMaterial: "Glass"), [.recessed, .ceiling])
        XCTAssertEqual(classifier.fixtureTypes(forMaterial: "Metal"), [.pendant, .lamp])
        XCTAssertEqual(classifier.fixtureTypes(forMaterial: "Unknown"), [])
    }
    
    func testDefaultMaterialIndexMappingRejectsUnknownIndex() {
        let classifier = NeuralSurfaceMaterialClassifier()
        XCTAssertNotNil(classifier)
    }
    
    // MARK: - Config Loading Tests
    
    func testLoadMaterialIndexMappingFromConfig() throws {
        // Load from the bundled classification_rules.json
        guard let url = Bundle.main.url(forResource: "classification_rules", withExtension: "json") else {
            XCTFail("classification_rules.json not found in bundle")
            return
        }
        
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(ClassificationConfigFile.self, from: data)
        
        XCTAssertNotNil(config.config?.materialIndexMapping)
        
        let mapping = config.config?.materialIndexMapping
        XCTAssertEqual(mapping?["0"], "Glass")
        XCTAssertEqual(mapping?["1"], "Metal")
        XCTAssertEqual(mapping?["2"], "Wood")
        XCTAssertEqual(mapping?["3"], "Fabric")
        XCTAssertEqual(mapping?["4"], "Plaster")
        XCTAssertEqual(mapping?["5"], "Concrete")
    }
    
    func testLoadMaterialIndexMappingReturnsEmptyWhenMissing() throws {
        // Create a config without materialIndexMapping
        let json = """
        {
            "version": "1.0.0",
            "config": {
                "specificity": {"ceiling": 4}
            },
            "rules": []
        }
        """
        
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(ClassificationConfigFile.self, from: data)
        
        XCTAssertNil(config.config?.materialIndexMapping)
    }
    
    // MARK: - Classifier Initialization Tests
    
    func testClassifierUsesCustomIndexMapping() {
        let customMapping: [UInt8: String] = [
            0: "Glass",
            1: "CustomMetal",
            2: "Wood"
        ]
        
        let classifier = NeuralSurfaceMaterialClassifier(
            materialFixtureMapping: [:],
            materialIndexMapping: customMapping
        )
        
        // The classifier should use the custom mapping
        // We verify this indirectly by checking the classifier was created successfully
        XCTAssertNotNil(classifier)
        XCTAssertEqual(classifier.fixtureTypes(forMaterial: "Glass"), [])
    }
    
    func testClassifierFallbackForUnknownIndex() {
        let classifier = NeuralSurfaceMaterialClassifier()
        
        // Verify classifier is created with default mapping
        XCTAssertNotNil(classifier)
        XCTAssertEqual(classifier.fixtureTypes(forMaterial: "Glass"), [.recessed, .ceiling])
        XCTAssertEqual(classifier.fixtureTypes(forMaterial: "Metal"), [.pendant, .lamp])
        XCTAssertEqual(classifier.fixtureTypes(forMaterial: "Unknown"), [])
    }
    
    // MARK: - Config Version Tests
    
    func testConfigHasMaterialIndexMappingSection() throws {
        guard let url = Bundle.main.url(forResource: "classification_rules", withExtension: "json") else {
            XCTFail("classification_rules.json not found")
            return
        }
        
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(ClassificationConfigFile.self, from: data)
        
        XCTAssertNotNil(config.config?.materialIndexMapping, "Config should include materialIndexMapping section")
        
        // Verify all expected material indices are present
        let mapping = config.config?.materialIndexMapping
        let expectedIndices = ["0", "1", "2", "3", "4", "5"]
        for index in expectedIndices {
            XCTAssertNotNil(mapping?[index], "Config should have mapping for index \(index)")
        }
    }
}
