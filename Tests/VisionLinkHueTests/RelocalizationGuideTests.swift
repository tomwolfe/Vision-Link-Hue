import XCTest
import @testable VisionLinkHue

/// Unit tests for the RelocalizationGuide, validating directional
/// guidance generation, feature density tracking, and trend analysis.
final class RelocalizationGuideTests: XCTestCase {
    
    private var guide: RelocalizationGuide!
    
    override func setUp() {
        super.setUp()
        guide = RelocalizationGuide()
    }
    
    override func tearDown() {
        guide = nil
        super.tearDown()
    }
    
    // MARK: - Initial State Tests
    
    func testGuideStartsWithNoInstruction() {
        XCTAssertFalse(guide.hasInstruction)
        XCTAssertEqual(guide.currentLookDirection, .none)
        XCTAssertEqual(guide.instructionText, "Move your device slowly to help the app reconnect")
    }
    
    // MARK: - LookDirection Tests
    
    func testLookDirectionInstructions() {
        XCTAssertEqual(LookDirection.left.instruction, "Look to your left to help reconnect")
        XCTAssertEqual(LookDirection.right.instruction, "Look to your right to help reconnect")
        XCTAssertEqual(LookDirection.up.instruction, "Look up to help reconnect")
        XCTAssertEqual(LookDirection.down.instruction, "Look down to help reconnect")
        XCTAssertEqual(LookDirection.closer.instruction, "Move your device closer to the room")
        XCTAssertEqual(LookDirection.farther.instruction, "Move your device farther from the room")
        XCTAssertEqual(LookDirection.none.instruction, "Move your device slowly to help the app reconnect")
    }
    
    func testLookDirectionIcons() {
        XCTAssertEqual(LookDirection.left.icon, "arrow.left.circle.fill")
        XCTAssertEqual(LookDirection.right.icon, "arrow.right.circle.fill")
        XCTAssertEqual(LookDirection.up.icon, "arrow.up.circle.fill")
        XCTAssertEqual(LookDirection.down.icon, "arrow.down.circle.fill")
        XCTAssertEqual(LookDirection.closer.icon, "arrow.inward.circle.fill")
        XCTAssertEqual(LookDirection.farther.icon, "arrow.outward.circle.fill")
        XCTAssertEqual(LookDirection.none.icon, "arrow.forward.circle")
    }
    
    // MARK: - Feature Density Tracking Tests
    
    func testUpdateFeatureDensityStoresValue() {
        guide.updateFeatureDensity(0.5)
        
        // The property is private, but we can verify via the improving check.
        // A single value shouldn't show improvement (needs 3+).
        XCTAssertFalse(guide.isFeatureDensityImproving)
    }
    
    func testFeatureDensityTrendDetection() {
        // Simulate improving feature density over 3 samples.
        guide.updateFeatureDensity(0.2)
        guide.updateFeatureDensity(0.4)
        guide.updateFeatureDensity(0.6)
        
        XCTAssertTrue(guide.isFeatureDensityImproving, "Should detect improving trend with 3 ascending values")
    }
    
    func testFeatureDensityNoTrendWithDecrease() {
        guide.updateFeatureDensity(0.6)
        guide.updateFeatureDensity(0.4)
        guide.updateFeatureDensity(0.5)
        
        XCTAssertFalse(guide.isFeatureDensityImproving, "Should not detect improvement when density decreases")
    }
    
    func testFeatureDensityNeedsMinimumSamples() {
        guide.updateFeatureDensity(0.6)
        guide.updateFeatureDensity(0.8)
        
        XCTAssertFalse(guide.isFeatureDensityImproving, "Needs at least 3 samples to detect trend")
    }
    
    // MARK: - Reset Tests
    
    func testResetClearsAllState() {
        guide.updateFeatureDensity(0.5)
        guide.updateFeatureDensity(0.7)
        guide.updateFeatureDensity(0.9)
        
        // Verify trend is detected before reset.
        XCTAssertTrue(guide.isFeatureDensityImproving)
        
        guide.reset()
        
        XCTAssertFalse(guide.hasInstruction)
        XCTAssertFalse(guide.isFeatureDensityImproving)
    }
    
    // MARK: - Simulator Tests
    
    func testAnalyzeFrameReturnsNoneOnSimulator() {
        let direction = guide.analyzeFrame(mockFrame(), confidence: 0.3)
        XCTAssertEqual(direction, .none, "Should return .none on simulator")
    }
    
    // MARK: - Helper Methods
    
    private func mockFrame() -> ARFrame {
        // Create a minimal mock ARFrame for testing.
        // In unit tests without ARKit hardware, we can only verify
        // the simulator path or basic logic.
        return ARFrame()
    }
}
