import Foundation
import AVFoundation
import Vision
import ARKit
import os

/// ARKit 2026 Neural Surface Synthesis material classifier.
/// Samples material labels from AR frames to identify fixture surfaces
/// as Glass, Metal, Wood, Fabric, Plaster, or Concrete.
///
/// This classifier complements the heuristic classifier by providing
/// material-based classification that is more robust for fixture types
/// with distinctive surface properties.
///
/// Uses ARKit 2026's `ARFrame.sceneDepth.materialLabel` API to sample
/// material classifications at normalized pixel coordinates. Supports
/// multi-point sampling with voting for improved accuracy.
///
/// Material-to-fixture-type mapping is loaded from `classification_rules.json`
/// to enable OTA updates without recompiling.
struct NeuralSurfaceMaterialClassifier: Sendable {
    
    /// Known material labels supported by ARKit 2026 Neural Surface Synthesis.
    static let supportedMaterials: [String] = [
        "Glass", "Metal", "Wood", "Fabric", "Plaster", "Concrete"
    ]
    
    /// Default material-to-fixture-type mapping (used when config is unavailable).
    private static let defaultMaterialFixtureMapping: [String: [FixtureType]] = [
        "Glass": [.recessed, .ceiling],
        "Metal": [.pendant, .lamp],
        "Wood": [.ceiling, .recessed],
        "Fabric": [.lamp, .pendant],
        "Plaster": [.ceiling, .recessed],
        "Concrete": [.ceiling, .recessed]
    ]
    
    /// Default material index to label mapping (used when config is unavailable).
    private static let defaultMaterialIndexMapping: [UInt8: String] = [
        0: "Glass",
        1: "Metal",
        2: "Wood",
        3: "Fabric",
        4: "Plaster",
        5: "Concrete"
    ]
    
    /// Material-to-fixture-type mapping loaded from classification_rules.json.
    private let materialFixtureMapping: [String: [FixtureType]]
    
    /// Material index to label mapping loaded from classification_rules.json.
    private let materialIndexMapping: [UInt8: String]
    
    /// Number of sample points to use for voting-based material classification.
    private static let sampleRadius: Float = 0.03
    
    /// Initialize with material mappings from the classification config.
    /// - Parameters:
    ///   - materialFixtureMapping: Material-to-fixture-type mapping loaded from `classification_rules.json`.
    ///   - materialIndexMapping: Material index-to-label mapping loaded from `classification_rules.json`.
    init(
        materialFixtureMapping: [String: [FixtureType]] = NeuralSurfaceMaterialClassifier.defaultMaterialFixtureMapping,
        materialIndexMapping: [UInt8: String] = NeuralSurfaceMaterialClassifier.defaultMaterialIndexMapping
    ) {
        self.materialFixtureMapping = materialFixtureMapping
        self.materialIndexMapping = materialIndexMapping
    }
    
    /// Load the material-to-fixture-type mapping from classification_rules.json.
    /// Falls back to the default mapping if the config file is unavailable.
    static func loadMaterialMapping() -> [String: [FixtureType]] {
        // Try to load from the bundled classification_rules.json
        guard let url = Bundle.main.url(forResource: "classification_rules", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(ClassificationConfigFile.self, from: data),
              let mapping = config.config?.materialFixtureMapping else {
            return defaultMaterialFixtureMapping
        }
        
        var result: [String: [FixtureType]] = [:]
        for (material, fixtureNames) in mapping {
            result[material] = fixtureNames.compactMap { FixtureType(from: $0) }
        }
        
        return result.isEmpty ? defaultMaterialFixtureMapping : result
    }
    
    /// Load the material index-to-label mapping from classification_rules.json.
    /// Falls back to the default mapping if the config file is unavailable.
    static func loadMaterialIndexMapping() -> [UInt8: String] {
        // Try to load from the bundled classification_rules.json
        guard let url = Bundle.main.url(forResource: "classification_rules", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(ClassificationConfigFile.self, from: data),
              let indexMapping = config.config?.materialIndexMapping else {
            return defaultMaterialIndexMapping
        }
        
        var result: [UInt8: String] = [:]
        for (indexStr, label) in indexMapping {
            if let index = UInt8(indexStr) {
                result[index] = label
            }
        }
        
        return result.isEmpty ? defaultMaterialIndexMapping : result
    }
    
    /// Sample the material label at a normalized position in the AR frame.
    /// Uses multi-point sampling with a small radius and returns the most
    /// common material label (majority voting).
    ///
    /// - Parameters:
    ///   - normalizedPosition: Normalized [0,1] coordinates in the frame.
    ///   - frame: The current AR frame containing depth/material data.
    ///   - materialLabel: The raw material label pixel buffer from `sceneDepth.materialLabel`.
    /// - Returns: The dominant material label string, or `nil` if no valid data.
    func sampleMaterial(
        at normalizedPosition: SIMD2<Float>,
        in frame: ARFrame,
        materialLabel: CVPixelBuffer
    ) -> String? {
        sampleMaterial(region: NormalizedRect(
            topLeft: normalizedPosition - SIMD2<Float>(Self.sampleRadius, Self.sampleRadius),
            bottomRight: normalizedPosition + SIMD2<Float>(Self.sampleRadius, Self.sampleRadius)
        ), materialLabel: materialLabel)
    }
    
    /// Sample material labels across a normalized bounding region in the AR frame.
    /// Uses a grid spread across the entire region with majority voting for robust
    /// classification. This handles fixtures with empty centers (ring-pendants,
    /// chandeliers) that would otherwise sample the background behind the fixture.
    ///
    /// - Parameters:
    ///   - region: Normalized bounding box covering the fixture.
    ///   - materialLabel: The raw material label pixel buffer from `sceneDepth.materialLabel`.
    /// - Returns: The dominant material label string, or `nil` if no valid data.
    func sampleMaterial(region: NormalizedRect, materialLabel: CVPixelBuffer) -> String? {
        let pixelWidth = Int(CVPixelBufferGetWidth(materialLabel))
        let pixelHeight = Int(CVPixelBufferGetHeight(materialLabel))
        
        let topLeftPx = Int(region.topLeft.x * Float(pixelWidth))
        let topLeftPy = Int(region.topLeft.y * Float(pixelHeight))
        let bottomRightPx = Int(region.bottomRight.x * Float(pixelWidth))
        let bottomRightPy = Int(region.bottomRight.y * Float(pixelHeight))
        
        var voteCount: [String: Int] = [:]
        var totalSamples = 0
        
        CVPixelBufferLockBaseAddress(materialLabel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(materialLabel, .readOnly) }
        
        let step = max(1, min(bottomRightPx - topLeftPx, bottomRightPy - topLeftPy) / 5)
        
        for py in stride(from: topLeftPy, through: bottomRightPy, by: step) {
            for px in stride(from: topLeftPx, through: bottomRightPx, by: step) {
                guard px >= 0, px < pixelWidth, py >= 0, py < pixelHeight else { continue }
                
                let label = extractMaterialLabel(from: materialLabel, pixelX: px, pixelY: py, width: pixelWidth)
                if let label, !label.isEmpty, NeuralSurfaceMaterialClassifier.supportedMaterials.contains(label) {
                    voteCount[label, default: 0] += 1
                    totalSamples += 1
                }
            }
        }
        
        guard totalSamples > 0 else { return nil }
        
        return voteCount.max { $0.value < $1.value }?.key
    }
    
    /// Extract a material label string from the material label pixel buffer.
    /// Material labels are stored as uint8 values indexed by a lookup table
    /// provided by ARKit's Neural Surface Synthesis pipeline.
    private func extractMaterialLabel(
        from pixelBuffer: CVPixelBuffer,
        pixelX: Int,
        pixelY: Int,
        width: Int
    ) -> String? {
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let byteOffset = pixelY * bytesPerRow + pixelX
        let materialIndex = baseAddress.load(fromByteOffset: byteOffset, as: UInt8.self)
        
        return materialIndexToLabel(materialIndex)
    }
    
    /// Map an ARKit neural surface material index to its string label.
    /// ARKit 2026 assigns indices to material types in the depth/material pipeline.
    /// Uses the mapping loaded from `classification_rules.json` for OTA-updatable
    /// index-to-label associations.
    private func materialIndexToLabel(_ index: UInt8) -> String? {
        materialIndexMapping[index]
    }
    
    /// Get fixture types that are commonly associated with a material.
    /// Uses the mapping loaded from `classification_rules.json`.
    func fixtureTypes(forMaterial material: String) -> [FixtureType] {
        materialFixtureMapping[material, default: []]
    }
}
