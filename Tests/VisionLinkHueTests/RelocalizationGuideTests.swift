import XCTest
import ARKit
@testable import VisionLinkHue

/// Unit tests for the RelocalizationGuide, validating directional
/// guidance generation, feature density tracking, and trend analysis.
final class RelocalizationGuideTests: XCTestCase {
    
    private var guide: RelocalizationGuide!
    
    override func setUp() async throws {
        try await super.setUp()
        guide = await MainActor.run {
            RelocalizationGuide()
        }
    }
    
    override func tearDown() async throws {
        try await super.tearDown()
        guide = nil
    }
    
    // MARK: - Helper Methods
    
    private func mockFrame() -> ARFrame {
        // ARFrame cannot be directly initialized - use a placeholder approach
        // In actual testing, frames would come from an ARSession
        fatalError("ARFrame creation not supported in unit tests")
    }
    
    // MARK: - Initial State Tests
    
    @MainActor
    func testGuideStartsWithNoInstruction() async {
        XCTAssertFalse(guide.hasInstruction)
        XCTAssertEqual(guide.currentLookDirection, .none)
        XCTAssertEqual(guide.instructionText, "Move your device slowly to help reconnect")
    }
    
    // MARK: - LookDirection Tests
    
    func testLookDirectionInstructions() {
        XCTAssertEqual(LookDirection.left.instruction, "Look to your left to help reconnect")
        XCTAssertEqual(LookDirection.right.instruction, "Look to your right to help reconnect")
        XCTAssertEqual(LookDirection.up.instruction, "Look up to help reconnect")
        XCTAssertEqual(LookDirection.down.instruction, "Look down to help reconnect")
        XCTAssertEqual(LookDirection.closer.instruction, "Move your device closer to the room")
        XCTAssertEqual(LookDirection.farther.instruction, "Move your device farther from the room")
        XCTAssertEqual(LookDirection.lowLight.instruction, "Turn on a light to improve tracking")
        XCTAssertEqual(LookDirection.none.instruction, "Move your device slowly to help the app reconnect")
    }
    
    func testLookDirectionIcons() {
        XCTAssertEqual(LookDirection.left.icon, "arrow.left.circle.fill")
        XCTAssertEqual(LookDirection.right.icon, "arrow.right.circle.fill")
        XCTAssertEqual(LookDirection.up.icon, "arrow.up.circle.fill")
        XCTAssertEqual(LookDirection.down.icon, "arrow.down.circle.fill")
        XCTAssertEqual(LookDirection.closer.icon, "arrow.inward.circle.fill")
        XCTAssertEqual(LookDirection.farther.icon, "arrow.outward.circle.fill")
        XCTAssertEqual(LookDirection.lowLight.icon, "lightbulb.circle.fill")
        XCTAssertEqual(LookDirection.none.icon, "arrow.forward.circle")
    }
    
    func testLookDirectionEnvironmentalCase() {
        let description = "Look toward the upper right to improve tracking"
        let icon = "arrow.up.right.circle.fill"
        let direction = LookDirection.environmental(description: description, icon: icon)
        
        XCTAssertEqual(direction.instruction, description)
        XCTAssertEqual(direction.icon, icon)
    }
    
    func testLookDirectionEnvironmentalCaseWithHint() {
        let description = "Look toward the upper right to improve tracking — Ceiling or upper walls often have the best tracking features"
        let icon = "arrow.up.right.circle.fill"
        let direction = LookDirection.environmental(description: description, icon: icon)

        
        XCTAssertEqual(direction.instruction, description)
        XCTAssertEqual(direction.icon, icon)
    }
    
    // MARK: - Feature Density Tracking Tests
    
    func testUpdateFeatureDensityStoresValue() async {
        await guide.updateFeatureDensity(0.5)
        
        // The property is private, but we can verify via the improving check.
        // A single value shouldn't show improvement (needs 3+).
        let isImproving = await guide.isFeatureDensityImproving
        XCTAssertFalse(isImproving)
    }
    
    func testFeatureDensityTrendDetection() async {
        // Simulate improving feature density over 3 samples.
        await guide.updateFeatureDensity(0.2)
        await guide.updateFeatureDensity(0.4)
        await guide.updateFeatureDensity(0.6)
        
        let isImproving = await guide.isFeatureDensityImproving
        XCTAssertTrue(isImproving, "Should detect improving trend with 3 ascending values")
    }
    
    func testFeatureDensityNoTrendWithDecrease() async {
        await guide.updateFeatureDensity(0.6)
        await guide.updateFeatureDensity(0.4)
        await guide.updateFeatureDensity(0.5)
        
        let isImproving = await guide.isFeatureDensityImproving
        XCTAssertFalse(isImproving, "Should not detect improvement when density decreases")
    }
    
    func testFeatureDensityNeedsMinimumSamples() async {
        await guide.updateFeatureDensity(0.6)
        await guide.updateFeatureDensity(0.8)
        
        let isImproving = await guide.isFeatureDensityImproving
        XCTAssertFalse(isImproving, "Needs at least 3 samples to detect trend")
    }
    
    // MARK: - Reset Tests
    
    func testResetClearsAllState() async {
        await guide.updateFeatureDensity(0.5)
        await guide.updateFeatureDensity(0.7)
        await guide.updateFeatureDensity(0.9)
        
        // Verify trend is detected before reset.
        let isImproving = await guide.isFeatureDensityImproving
        XCTAssertTrue(isImproving)
        
        await guide.reset()
        
        let hasInstruction = await guide.hasInstruction
        let isImproving2 = await guide.isFeatureDensityImproving
        XCTAssertFalse(hasInstruction)
        XCTAssertFalse(isImproving2)
    }
    
    // MARK: - Depth Quadrant Tests
    
    func testDepthQuadrantLabels() {
        XCTAssertEqual(DepthQuadrant.topLeft.label, "upper left")
        XCTAssertEqual(DepthQuadrant.topRight.label, "upper right")
        XCTAssertEqual(DepthQuadrant.bottomLeft.label, "lower left")
        XCTAssertEqual(DepthQuadrant.bottomRight.label, "lower right")
    }
    
    func testDepthQuadrantOpposites() {
        XCTAssertEqual(DepthQuadrant.topLeft.opposite, .bottomRight)
        XCTAssertEqual(DepthQuadrant.topRight.opposite, .bottomLeft)
        XCTAssertEqual(DepthQuadrant.bottomLeft.opposite, .topRight)
        XCTAssertEqual(DepthQuadrant.bottomRight.opposite, .topLeft)
    }
    
    // MARK: - MPS Fallback Tests
    
    func testQuadrantCountsInitialization() {
        let counts = QuadrantCounts()
        for quadrant in DepthQuadrant.allCases {
            XCTAssertEqual(counts[quadrant], 0, "All quadrant counts should start at zero")
        }
    }
    
    func testQuadrantCountsIncrement() {
        var counts = QuadrantCounts()
        counts[.topLeft] += 1
        counts[.topRight] += 5
        counts[.bottomLeft] += 10
        counts[.bottomRight] += 15
        
        XCTAssertEqual(counts[.topLeft], 1)
        XCTAssertEqual(counts[.topRight], 5)
        XCTAssertEqual(counts[.bottomLeft], 10)
        XCTAssertEqual(counts[.bottomRight], 15)
        XCTAssertEqual(counts.total(), 31)
    }
    
    func testQuadrantDensitiesInitialization() {
        let densities = QuadrantDensities()
        for quadrant in DepthQuadrant.allCases {
            XCTAssertEqual(densities[quadrant], 0.0, accuracy: 0.0001, "All densities should start at zero")
        }
    }
    
    func testQuadrantDensitiesEntropy() {
        var densities = QuadrantDensities()
        densities[.topLeft] = 1.0
        densities[.topRight] = 1.0
        densities[.bottomLeft] = 1.0
        densities[.bottomRight] = 1.0
        
        let entropy = densities.entropy()
        let maxEntropy = Float(log(4.0))
        XCTAssertEqual(entropy, maxEntropy, accuracy: 0.0001, "Uniform distribution should have maximum entropy")
    }
    
    func testQuadrantDensitiesZeroEntropy() {
        var densities = QuadrantDensities()
        densities[.topLeft] = 1.0
        
        let entropy = densities.entropy()
        XCTAssertEqual(entropy, 0.0, accuracy: 0.0001, "Single-quadrant distribution should have zero entropy")
    }
    
    func testQuadrantCountsSparsest() {
        var counts = QuadrantCounts()
        counts[.topLeft] = 10
        counts[.topRight] = 5
        counts[.bottomLeft] = 20
        counts[.bottomRight] = 15
        
        XCTAssertEqual(counts.sparsest(), 1, "topRight (index 1) should be sparsest")
    }
    
    func testQuadrantDensitiesRichest() {
        var densities = QuadrantDensities()
        densities[.topLeft] = 0.3
        densities[.topRight] = 0.1
        densities[.bottomLeft] = 0.4
        densities[.bottomRight] = 0.2
        
        XCTAssertEqual(densities.richest(), 2, "bottomLeft (index 2) should be richest")
    }
}
