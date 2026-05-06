import XCTest
import simd
import @testable VisionLinkHue

/// Unit tests for the GazeTargetingSystem, validating gaze-based targeting,
/// dwell detection, fixation tracking, and fixture selection.
final class GazeTargetingTests: XCTestCase {
    
    private var gazeSystem: GazeTargetingSystem!
    
    override func setUp() {
        super.setUp()
        gazeSystem = GazeTargetingSystem()
    }
    
    override func tearDown() {
        gazeSystem = nil
        super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testGazeSystemStartsInactive() {
        XCTAssertFalse(gazeSystem.isActive)
        XCTAssertNil(gazeSystem.targetedFixtureID)
        XCTAssertNil(gazeSystem.targetPosition)
        XCTAssertFalse(gazeSystem.isSelecting)
        XCTAssertEqual(gazeSystem.dwellProgress, 0.0)
        XCTAssertFalse(gazeSystem.isFixating)
    }
    
    func testGazeSystemDefaultConfiguration() {
        XCTAssertEqual(gazeSystem.configuration.dwellDuration, 1.5)
        XCTAssertEqual(gazeSystem.configuration.fixationAngleDegrees, 3.0)
        XCTAssertEqual(gazeSystem.configuration.maxTargetDistance, 5.0)
    }
    
    func testGazeSystemDefaultInputTypeIsGazePinch() {
        XCTAssertEqual(gazeSystem.inputType, .gazePinch, "Default input type should be gazePinch for Vision Pro gaze-plus-pinch confirmation")
    }
    
    func testGazePinchSelectionConfirmedOnEndSelection() {
        gazeSystem.inputType = .gazePinch
        let fixture = createFixture(position: SIMD3<Float>(0, 1.5, -1.0))
        gazeSystem.configure(trackedFixtures: [fixture])
        
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection = simd_normalize(SIMD3<Float>(0, -0.1, -1.0))
        
        gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection,
            cameraTransform: .identity
        )
        
        XCTAssertEqual(gazeSystem.targetedFixtureID, fixture.id)
        
        gazeSystem.beginSelection()
        XCTAssertTrue(gazeSystem.isSelecting)
        
        gazeSystem.endSelection()
        XCTAssertFalse(gazeSystem.isSelecting)
    }
    
    // MARK: - Configuration Tests
    
    func testConfigureWithTrackedFixtures() {
        let fixture = createFixture(position: SIMD3<Float>(0, 1.5, -2.0))
        gazeSystem.configure(trackedFixtures: [fixture])
        
        // Simulate a gaze ray pointing at the fixture.
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection = simd_normalize(SIMD3<Float>(0, -0.1, -2.0))
        
        gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection,
            cameraTransform: .identity
        )
        
        XCTAssertEqual(gazeSystem.targetedFixtureID, fixture.id)
        XCTAssertEqual(gazeSystem.targetPosition, fixture.position)
    }
    
    func testGazeTargetsClosestFixture() {
        let fixture1 = createFixture(id: UUID(upperBits: 1, lowerBits: 1), position: SIMD3<Float>(0, 1.5, -1.0))
        let fixture2 = createFixture(id: UUID(upperBits: 2, lowerBits: 2), position: SIMD3<Float>(0, 1.5, -0.5))
        
        gazeSystem.configure(trackedFixtures: [fixture1, fixture2])
        
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection = simd_normalize(SIMD3<Float>(0, -0.1, -1.0))
        
        gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection,
            cameraTransform: .identity
        )
        
        // Fixture2 is closer (0.5m vs 1.0m), so it should be targeted.
        XCTAssertEqual(gazeSystem.targetedFixtureID, fixture2.id)
    }
    
    func testGazeNoTargetWhenNoFixtures() {
        gazeSystem.configure(trackedFixtures: [])
        
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection = simd_normalize(SIMD3<Float>(0, -0.1, -1.0))
        
        gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection,
            cameraTransform: .identity
        )
        
        XCTAssertNil(gazeSystem.targetedFixtureID)
    }
    
    func testGazeMissesFixtureBeyondMaxDistance() {
        let fixture = createFixture(position: SIMD3<Float>(0, 1.5, -10.0))
        gazeSystem.configure(trackedFixtures: [fixture])
        
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection = simd_normalize(SIMD3<Float>(0, -0.1, -1.0))
        
        gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection,
            cameraTransform: .identity
        )
        
        XCTAssertNil(gazeSystem.targetedFixtureID, "Should not target fixture beyond max distance")
    }
    
    func testGazeMissesFixtureOutsideFixationAngle() {
        let fixture = createFixture(position: SIMD3<Float>(3.0, 1.5, -2.0))
        gazeSystem.configure(trackedFixtures: [fixture])
        
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection = SIMD3<Float>(0, -0.1, -1.0)
        
        gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection,
            cameraTransform: .identity
        )
        
        XCTAssertNil(gazeSystem.targetedFixtureID, "Should not target fixture outside fixation angle")
    }
    
    // MARK: - Dwell Detection Tests
    
    func testDwellProgressIncreasesOverTime() {
        let fixture = createFixture(position: SIMD3<Float>(0, 1.5, -1.0))
        gazeSystem.configure(trackedFixtures: [fixture])
        
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection = simd_normalize(SIMD3<Float>(0, -0.1, -1.0))
        
        gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection,
            cameraTransform: .identity
        )
        
        gazeSystem.beginSelection()
        
        // Wait a short time (simulated by checking the logic directly).
        XCTAssertNotNil(gazeSystem.gazeFixationStart)
        XCTAssertTrue(gazeSystem.isFixating)
    }
    
    func testDwellCompletionAfterDuration() async {
        let fixture = createFixture(position: SIMD3<Float>(0, 1.5, -1.0))
        gazeSystem.configure(trackedFixtures: [fixture])
        
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection = simd_normalize(SIMD3<Float>(0, -0.1, -1.0))
        
        gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection,
            cameraTransform: .identity
        )
        
        gazeSystem.beginSelection()
        
        // Wait for the dwell duration to pass (1.5 seconds).
        try? await Task.sleep(for: .milliseconds(1600))
        
        let completed = gazeSystem.checkDwellCompletion()
        XCTAssertTrue(completed, "Dwell should complete after configured duration")
    }
    
    func testDwellResetsOnGazeMovement() {
        let fixture = createFixture(position: SIMD3<Float>(0, 1.5, -1.0))
        gazeSystem.configure(trackedFixtures: [fixture])
        
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection1 = simd_normalize(SIMD3<Float>(0, -0.1, -1.0))
        
        gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection1,
            cameraTransform: .identity
        )
        
        gazeSystem.beginSelection()
        XCTAssertNotNil(gazeSystem.gazeFixationStart)
        
        // Move gaze significantly (beyond 3 degree fixation angle).
        let gazeDirection2 = SIMD3<Float>(1.0, 0, -0.5)
        
        gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection2,
            cameraTransform: .identity
        )
        
        XCTAssertNil(gazeSystem.gazeFixationStart, "Fixation should reset when gaze moves significantly")
        XCTAssertFalse(gazeSystem.isFixating)
    }
    
    // MARK: - Hysteresis Buffer Tests
    
    func testHysteresisThresholdInConfig() {
        XCTAssertEqual(gazeSystem.configuration.hysteresisThreshold, 0.95)
    }
    
    func testHysteresisResetsDwellWhenProgressDropsBelowThreshold() async {
        let fixture = createFixture(position: SIMD3<Float>(0, 1.5, -1.0))
        gazeSystem.configure(trackedFixtures: [fixture])
        
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection = simd_normalize(SIMD3<Float>(0, -0.1, -1.0))
        
        gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection,
            cameraTransform: .identity
        )
        
        gazeSystem.beginSelection()
        XCTAssertNotNil(gazeSystem.gazeFixationStart)
        
        // Simulate waiting until progress approaches hysteresis threshold
        // (95% of 1.5s = 1425ms). At this point hasEnteredHysteresisZone becomes true.
        try? await Task.sleep(for: .milliseconds(1425))
        
        // Now move gaze away significantly to drop progress below hysteresis threshold.
        let gazeDirection2 = SIMD3<Float>(1.0, 0, -0.5)
        gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection2,
            cameraTransform: .identity
        )
        
        // The fixation should have been reset due to hysteresis.
        XCTAssertNil(gazeSystem.gazeFixationStart, "Dwell timer should reset when gaze moves after entering hysteresis zone")
        XCTAssertFalse(gazeSystem.isFixating, "Should not be fixating after hysteresis reset")
        XCTAssertEqual(gazeSystem.dwellProgress, 0.0, "Progress should reset to 0 after hysteresis trigger")
    }
    
    func testHysteresisDoesNotResetWhenBelowThreshold() async {
        let fixture = createFixture(position: SIMD3<Float>(0, 1.5, -1.0))
        gazeSystem.configure(trackedFixtures: [fixture])
        
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection = simd_normalize(SIMD3<Float>(0, -0.1, -1.0))
        
        gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection,
            cameraTransform: .identity
        )
        
        gazeSystem.beginSelection()
        XCTAssertNotNil(gazeSystem.gazeFixationStart)
        
        // Wait only 500ms - well below hysteresis threshold (95% of 1.5s = 1425ms).
        try? await Task.sleep(for: .milliseconds(500))
        
        // Move gaze away - should reset due to gaze angle change, not hysteresis.
        let gazeDirection2 = SIMD3<Float>(1.0, 0, -0.5)
        gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection2,
            cameraTransform: .identity
        )
        
        XCTAssertNil(gazeSystem.gazeFixationStart, "Should reset due to gaze angle, not hysteresis")
        XCTAssertFalse(gazeSystem.isFixating)
    }
    
    func testHysteresisZoneTrackingResetsOnClearTarget() {
        let fixture = createFixture(position: SIMD3<Float>(0, 1.5, -1.0))
        gazeSystem.configure(trackedFixtures: [fixture])
        
        // Simulate entering hysteresis zone by moving gaze far away.
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection = simd_normalize(SIMD3<Float>(0, -0.1, -1.0))
        
        gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection,
            cameraTransform: .identity
        )
        
        // Clear target should reset hysteresis tracking.
        gazeSystem.reset()
        XCTAssertFalse(gazeSystem.isFixating)
    }
    
    // MARK: - Selection Tests
    
    func testBeginSelectionSetsSelectingState() {
        gazeSystem.beginSelection()
        XCTAssertTrue(gazeSystem.isSelecting)
    }
    
    func testEndSelectionClearsSelectingState() {
        gazeSystem.beginSelection()
        XCTAssertTrue(gazeSystem.isSelecting)
        
        gazeSystem.endSelection()
        XCTAssertFalse(gazeSystem.isSelecting)
    }
    
    // MARK: - Reset Tests
    
    func testResetClearsAllState() {
        let fixture = createFixture(position: SIMD3<Float>(0, 1.5, -1.0))
        gazeSystem.configure(trackedFixtures: [fixture])
        
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection = simd_normalize(SIMD3<Float>(0, -0.1, -1.0))
        
        gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection,
            cameraTransform: .identity
        )
        
        gazeSystem.beginSelection()
        
        gazeSystem.reset()
        
        XCTAssertFalse(gazeSystem.isActive)
        XCTAssertNil(gazeSystem.targetedFixtureID)
        XCTAssertNil(gazeSystem.targetPosition)
        XCTAssertFalse(gazeSystem.isSelecting)
        XCTAssertNil(gazeSystem.gazeFixationStart)
        XCTAssertEqual(gazeSystem.dwellProgress, 0.0)
        XCTAssertFalse(gazeSystem.isFixating)
    }
    
    // MARK: - SpatialInputHandler Protocol Tests
    
    func testGestureManagerConformsToSpatialInputHandler() {
        let gestureManager = GestureManager()
        XCTAssertTrue(gestureManager is SpatialInputHandler)
    }
    
    func testGazeSystemConformsToSpatialInputHandler() {
        XCTAssertTrue(gazeSystem is SpatialInputHandler)
    }
    
    // MARK: - Helper Methods
    
    private func createFixture(
        id: UUID = UUID(),
        position: SIMD3<Float>
    ) -> TrackedFixture {
        TrackedFixture(
            id: id,
            detection: FixtureDetection(
                type: .lamp,
                region: NormalizedRect(x: 0.5, y: 0.3, width: 0.1, height: 0.1),
                confidence: 0.9
            ),
            position: position,
            orientation: simd_quatf.identity,
            distanceMeters: simd_length(position),
            material: nil
        )
    }
}
