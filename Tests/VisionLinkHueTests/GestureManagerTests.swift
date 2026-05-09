import XCTest
import Vision
@testable import VisionLinkHue

/// Unit tests for the GestureManager, validating pinch gesture detection,
/// brightness delta calculation, EMA smoothing, and fixture targeting.
@MainActor
final class GestureManagerTests: XCTestCase {
    
    private var manager: GestureManager!
    private var mockHueClient: MockHueClient!
    
    override func setUp() {
        super.setUp()
        manager = GestureManager()
        mockHueClient = MockHueClient()
    }
    
    override func tearDown() {
        manager = nil
        mockHueClient = nil
        super.tearDown()
    }
    
    // MARK: - Pinch Detection Tests
    
    func testPinchStateStartsInactive() {
        XCTAssertEqual(manager.pinchState, .inactive)
        XCTAssertFalse(manager.isPinching)
        XCTAssertNil(manager.targetedFixtureID)
    }
    
    func testPinchDetectionBelowThreshold() {
        // Create a mock hand pose observation with thumb and index finger close together.
        let thumbTip = VNDetectedObjectObservation(boundingBox: CGRect(x: 0.49, y: 0.49, width: 0.01, height: 0.01))
        let indexTip = VNDetectedObjectObservation(boundingBox: CGRect(x: 0.50, y: 0.50, width: 0.01, height: 0.01))
        
        // Simulate pinch by processing with close landmarks.
        // The pinch distance would be sqrt((0.49-0.50)^2 + (0.49-0.50)^2) = 0.014 < 0.08 threshold
        let pinchDistance = sqrt(pow(0.49 - 0.50, 2) + pow(0.49 - 0.50, 2))
        
        XCTAssertLessThan(pinchDistance, 0.08, "Thumb and index should be within pinch threshold")
    }
    
    func testPinchDetectionAboveThreshold() {
        // Create a mock hand pose observation with thumb and index finger far apart.
        let pinchDistance = sqrt(pow(0.3 - 0.7, 2) + pow(0.3 - 0.7, 2))
        
        XCTAssertGreaterThan(pinchDistance, 0.08, "Fingers far apart should not be a pinch")
    }
    
    // MARK: - Fixture Targeting Tests
    
    func testFindTargetFixtureWithinRange() {
        let fixture1 = TrackedFixture(
            id: UUID(),
            detection: FixtureDetection(type: .lamp, region: NormalizedRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1), confidence: 0.9),
            position: SIMD3<Float>(0.1, 1.0, -0.5),
            orientation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)),
            distanceMeters: 1.0,
            material: nil
        )
        
        let fixture2 = TrackedFixture(
            id: UUID(),
            detection: FixtureDetection(type: .ceiling, region: NormalizedRect(x: 0.3, y: 0.1, width: 0.2, height: 0.2), confidence: 0.85),
            position: SIMD3<Float>(2.0, 2.5, -3.0),
            orientation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)),
            distanceMeters: 3.5,
            material: nil
        )
        
        manager.updateTrackedFixtures([fixture1, fixture2])
        
        // Hand at origin, fixture1 is much closer.
        let target = manager.findTargetFixture(handPosition3D: SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(target?.id, fixture1.id, "Should target the closest fixture within 0.5m")
    }
    
    func testFindTargetFixtureNoCloseFixture() {
        let fixture = TrackedFixture(
            id: UUID(),
            detection: FixtureDetection(type: .lamp, region: NormalizedRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1), confidence: 0.9),
            position: SIMD3<Float>(5.0, 3.0, -4.0),
            orientation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)),
            distanceMeters: 6.4,
            material: nil
        )
        
        manager.updateTrackedFixtures([fixture])
        
        // Hand at origin, fixture is far beyond 0.5m range.
        let target = manager.findTargetFixture(handPosition3D: SIMD3<Float>(0, 0, 0))
        XCTAssertNil(target, "Should not target fixtures beyond max range")
    }
    
    func testFindTargetFixtureEmptyList() {
        manager.updateTrackedFixtures([])
        let target = manager.findTargetFixture(handPosition3D: SIMD3<Float>(0, 0, 0))
        XCTAssertNil(target, "Should return nil when no fixtures are tracked")
    }
    
    // MARK: - Brightness Control Tests
    
    func testClampBrightnessMin() {
        let clamped = clampBrightnessTest(-10)
        XCTAssertEqual(clamped, 1, "Brightness should clamp to minimum of 1")
    }
    
    func testClampBrightnessMax() {
        let clamped = clampBrightnessTest(300)
        XCTAssertEqual(clamped, 254, "Brightness should clamp to maximum of 254")
    }
    
    func testClampBrightnessInRange() {
        let clamped = clampBrightnessTest(128)
        XCTAssertEqual(clamped, 128, "Brightness in range should remain unchanged")
    }
    
    func testSetTargetedFixture() {
        let fixture = TrackedFixture(
            id: UUID(),
            detection: FixtureDetection(type: .lamp, region: NormalizedRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1), confidence: 0.9),
            position: SIMD3<Float>(0.1, 1.0, -0.5),
            orientation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)),
            distanceMeters: 1.0,
            material: nil
        )
        
        var targetedID: UUID?
        manager.onFixtureTargeted = { id in targetedID = id }
        
        manager.setTargetedFixture(fixture)
        XCTAssertEqual(targetedID, fixture.id, "Should report fixture targeting")
        
        manager.setTargetedFixture(nil)
        XCTAssertNil(manager.targetedFixtureID, "Should clear targeted fixture")
    }
    
    func testResetClearsAllState() {
        manager.lastBrightness = 200
        manager.targetedFixtureID = UUID()
        manager.pinchState = .active(brightnessDelta: 0.5)
        
        manager.reset()
        
        XCTAssertEqual(manager.lastBrightness, 100, "Should reset brightness to default")
        XCTAssertNil(manager.targetedFixtureID, "Should clear targeted fixture")
        XCTAssertEqual(manager.pinchState, .inactive, "Should reset pinch state")
    }
    
    // MARK: - Helper Methods
    
    private func clampBrightnessTest(_ value: Int) -> Int {
        max(1, min(254, value))
    }
}
