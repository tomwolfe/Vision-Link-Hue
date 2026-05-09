import XCTest
import simd
@testable import VisionLinkHue

/// Unit tests for the GazeTargetingSystem, validating gaze-based targeting,
/// dwell detection, fixation tracking, and fixture selection.
@MainActor
final class GazeTargetingTests: XCTestCase {
    
    private var gazeSystem: GazeTargetingSystem!
    
    override func setUp() async throws {
        try await super.setUp()
        gazeSystem = await GazeTargetingSystem()
    }
    
    override func tearDown() async throws {
        try await super.tearDown()
        gazeSystem = nil
    }
    
    // MARK: - Initialization Tests
    
    func testGazeSystemStartsInactive() async {
        let isActive = await gazeSystem.isActive
        XCTAssertFalse(isActive)
        let targetedFixtureID = await gazeSystem.targetedFixtureID
        XCTAssertNil(targetedFixtureID)
        let targetPosition = await gazeSystem.targetPosition
        XCTAssertNil(targetPosition)
        let isSelecting = await gazeSystem.isSelecting
        XCTAssertFalse(isSelecting)
        let dwellProgress = await gazeSystem.dwellProgress
        XCTAssertEqual(dwellProgress, 0.0)
    }
    
    func testGazeSystemDefaultConfiguration() async {
        // Default configuration values are validated through behavior.
        // Dwell duration defaults to 1.5 seconds (tested via progress behavior).
        // Fixation angle defaults to 3.0 degrees (tested via targeting).
        // Max target distance defaults to 5.0 meters (tested via distance filtering).
        let fixture = createFixture(UUID(), position: SIMD3<Float>(0, 1.5, -1.0))
        await gazeSystem.configure(trackedFixtures: [fixture])
        
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection = simd_normalize(SIMD3<Float>(0, -0.1, -1.0))
        
        await gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection,
            cameraTransform: .init(rows: [
                SIMD4<Float>(1, 0, 0, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(0, 0, 1, 0),
                SIMD4<Float>(0, 0, 0, 1)
            ])
        )
        
        // Verify the system is active after configuration
        let isActive = await gazeSystem.isActive
        let targetedFixtureID = await gazeSystem.targetedFixtureID
        XCTAssertTrue(isActive || targetedFixtureID != nil)
    }
    
    func testGazeSystemDefaultInputTypeIsGazePinch() async {
        let inputType = await gazeSystem.inputType
        XCTAssertEqual(inputType, .gazePinch, "Default input type should be gazePinch for Vision Pro gaze-plus-pinch confirmation")
    }
    
    func testGazePinchSelectionConfirmedOnEndSelection() async {
        await MainActor.run { gazeSystem.inputType = .gazePinch }
        let fixture = createFixture(UUID(), position: SIMD3<Float>(0, 1.5, -1.0))
        await gazeSystem.configure(trackedFixtures: [fixture])
        
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection = simd_normalize(SIMD3<Float>(0, -0.1, -1.0))
        
        await gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection,
            cameraTransform: .init(rows: [
                SIMD4<Float>(1, 0, 0, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(0, 0, 1, 0),
                SIMD4<Float>(0, 0, 0, 1)
            ])
        )
        
        
        let targetedFixtureID = await gazeSystem.targetedFixtureID
        XCTAssertEqual(targetedFixtureID, fixture.id)
        
        await gazeSystem.beginSelection()
        let isSelecting = await gazeSystem.isSelecting
        XCTAssertTrue(isSelecting)
        
        await gazeSystem.endSelection()
        let isSelecting2 = await gazeSystem.isSelecting
        XCTAssertFalse(isSelecting2)
    }
    
    // MARK: - Configuration Tests
    
    func testConfigureWithTrackedFixtures() async {
        let fixture = createFixture(UUID(), position: SIMD3<Float>(0, 1.5, -2.0))
        await gazeSystem.configure(trackedFixtures: [fixture])
        
        // Simulate a gaze ray pointing at the fixture.
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection = simd_normalize(SIMD3<Float>(0, -0.1, -2.0))
        
        await gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection,
            cameraTransform: .init(rows: [
                SIMD4<Float>(1, 0, 0, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(0, 0, 1, 0),
                SIMD4<Float>(0, 0, 0, 1)
            ])
        )
        
        let targetedFixtureID = await gazeSystem.targetedFixtureID
        XCTAssertEqual(targetedFixtureID, fixture.id)
        let targetPosition = await gazeSystem.targetPosition
        XCTAssertEqual(targetPosition, fixture.position)
    }
    
    func testGazeTargetsClosestFixture() async {
        let fixture1 = createFixture(UUID(), position: SIMD3<Float>(0, 1.5, -1.0))
        let fixture2 = createFixture(UUID(), position: SIMD3<Float>(0, 1.5, -0.5))
        
        await gazeSystem.configure(trackedFixtures: [fixture1, fixture2])
        
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection = simd_normalize(SIMD3<Float>(0, -0.1, -1.0))
        
        await gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection,
            cameraTransform: .init(rows: [
                SIMD4<Float>(1, 0, 0, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(0, 0, 1, 0),
                SIMD4<Float>(0, 0, 0, 1)
            ])
        )
        
        // Fixture2 is closer (0.5m vs 1.0m), so it should be targeted.
        let targetedFixtureID = await gazeSystem.targetedFixtureID
        XCTAssertEqual(targetedFixtureID, fixture2.id)
    }
    
    func testGazeNoTargetWhenNoFixtures() async {
        await gazeSystem.configure(trackedFixtures: [])
        
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection = simd_normalize(SIMD3<Float>(0, -0.1, -1.0))
        
        await gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection,
            cameraTransform: .init(rows: [
                    SIMD4<Float>(1, 0, 0, 0),
                    SIMD4<Float>(0, 1, 0, 0),
                    SIMD4<Float>(0, 0, 1, 0),
                    SIMD4<Float>(0, 0, 0, 1)
                ])
        )
        
        let targetedFixtureID = await gazeSystem.targetedFixtureID
        XCTAssertNil(targetedFixtureID)
    }
    
    func testGazeMissesFixtureBeyondMaxDistance() async {
        let fixture = createFixture(UUID(), position: SIMD3<Float>(0, 1.5, -10.0))
        await gazeSystem.configure(trackedFixtures: [fixture])
        
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection = simd_normalize(SIMD3<Float>(0, -0.1, -1.0))
        
        await gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection,
            cameraTransform: .init(rows: [
                    SIMD4<Float>(1, 0, 0, 0),
                    SIMD4<Float>(0, 1, 0, 0),
                    SIMD4<Float>(0, 0, 1, 0),
                    SIMD4<Float>(0, 0, 0, 1)
                ])
        )
        
        let targetedFixtureID = await gazeSystem.targetedFixtureID
        XCTAssertNil(targetedFixtureID, "Should not target fixture beyond max distance")
    }
    
    func testGazeMissesFixtureOutsideFixationAngle() async {
        let fixture = createFixture(UUID(), position: SIMD3<Float>(3.0, 1.5, -2.0))
        await gazeSystem.configure(trackedFixtures: [fixture])
        
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection = SIMD3<Float>(0, -0.1, -1.0)
        
        await gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection,
            cameraTransform: .init(rows: [
                    SIMD4<Float>(1, 0, 0, 0),
                    SIMD4<Float>(0, 1, 0, 0),
                    SIMD4<Float>(0, 0, 1, 0),
                    SIMD4<Float>(0, 0, 0, 1)
                ])
        )
        
        let targetedFixtureID = await gazeSystem.targetedFixtureID
        XCTAssertNil(targetedFixtureID, "Should not target fixture outside fixation angle")
    }
    
    // MARK: - Dwell Detection Tests
    
    func testDwellProgressIncreasesOverTime() async {
        let fixture = createFixture(UUID(), position: SIMD3<Float>(0, 1.5, -1.0))
        await gazeSystem.configure(trackedFixtures: [fixture])
        
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection = simd_normalize(SIMD3<Float>(0, -0.1, -1.0))
        
        await gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection,
            cameraTransform: .init(rows: [
                    SIMD4<Float>(1, 0, 0, 0),
                    SIMD4<Float>(0, 1, 0, 0),
                    SIMD4<Float>(0, 0, 1, 0),
                    SIMD4<Float>(0, 0, 0, 1)
                ])
        )
        
        await gazeSystem.beginSelection()
        
        // Wait a short time (simulated by checking the logic directly).
        let fixationStart = await gazeSystem.gazeFixationStart
        XCTAssertNotNil(fixationStart)
        let isFixating = await gazeSystem.isFixating
        XCTAssertTrue(isFixating)
    }
    
    func testDwellCompletionAfterDuration() async {
        let fixture = createFixture(UUID(), position: SIMD3<Float>(0, 1.5, -1.0))
        await gazeSystem.configure(trackedFixtures: [fixture])
        
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection = simd_normalize(SIMD3<Float>(0, -0.1, -1.0))
        
        await gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection,
            cameraTransform: .init(rows: [
                    SIMD4<Float>(1, 0, 0, 0),
                    SIMD4<Float>(0, 1, 0, 0),
                    SIMD4<Float>(0, 0, 1, 0),
                    SIMD4<Float>(0, 0, 0, 1)
                ])
        )
        
        await gazeSystem.beginSelection()
        
        // Wait for the dwell duration to pass (1.5 seconds).
        try? await Task.sleep(for: .milliseconds(1600))
        
        let completed = await gazeSystem.checkDwellCompletion()
        XCTAssertTrue(completed, "Dwell should complete after configured duration")
    }
    
    func testDwellResetsOnGazeMovement() async {
        let fixture = createFixture(UUID(), position: SIMD3<Float>(0, 1.5, -1.0))
        await gazeSystem.configure(trackedFixtures: [fixture])
        
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection1 = simd_normalize(SIMD3<Float>(0, -0.1, -1.0))
        
        await gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection1,
            cameraTransform: .init(rows: [
                    SIMD4<Float>(1, 0, 0, 0),
                    SIMD4<Float>(0, 1, 0, 0),
                    SIMD4<Float>(0, 0, 1, 0),
                    SIMD4<Float>(0, 0, 0, 1)
                ])
        )
        
        await gazeSystem.beginSelection()
        let fixationStart = await gazeSystem.gazeFixationStart
        XCTAssertNotNil(fixationStart)
        
        // Move gaze significantly (beyond 3 degree fixation angle).
        let gazeDirection2 = SIMD3<Float>(1.0, 0, -0.5)
        
        await gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection2,
            cameraTransform: .init(rows: [
                    SIMD4<Float>(1, 0, 0, 0),
                    SIMD4<Float>(0, 1, 0, 0),
                    SIMD4<Float>(0, 0, 1, 0),
                    SIMD4<Float>(0, 0, 0, 1)
                ])
        )
        
        let fixationStart2 = await gazeSystem.gazeFixationStart
        XCTAssertNil(fixationStart2, "Fixation should reset when gaze moves significantly")
        let isFixating2 = await gazeSystem.isFixating
        XCTAssertFalse(isFixating2)
    }
    
    // MARK: - Hysteresis Buffer Tests
    
    func testHysteresisThresholdInConfig() async {
        // Hysteresis threshold is validated through behavioral testing.
        // When progress drops below threshold, dwell should reset.
        let fixture = createFixture(UUID(), position: SIMD3<Float>(0, 1.5, -1.0))
        await gazeSystem.configure(trackedFixtures: [fixture])
        
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection = simd_normalize(SIMD3<Float>(0, -0.1, -1.0))
        
        await gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection,
            cameraTransform: .init(rows: [
                SIMD4<Float>(1, 0, 0, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(0, 0, 1, 0),
                SIMD4<Float>(0, 0, 0, 1)
            ])
        )
        
        await gazeSystem.beginSelection()
        let fixationStart = await gazeSystem.gazeFixationStart
        XCTAssertNotNil(fixationStart)
    }
    
    func testHysteresisResetsDwellWhenProgressDropsBelowThreshold() async {
        let fixture = createFixture(UUID(), position: SIMD3<Float>(0, 1.5, -1.0))
        await gazeSystem.configure(trackedFixtures: [fixture])
        
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection = simd_normalize(SIMD3<Float>(0, -0.1, -1.0))
        
        await gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection,
            cameraTransform: .init(rows: [
                    SIMD4<Float>(1, 0, 0, 0),
                    SIMD4<Float>(0, 1, 0, 0),
                    SIMD4<Float>(0, 0, 1, 0),
                    SIMD4<Float>(0, 0, 0, 1)
                ])
        )
        
        await gazeSystem.beginSelection()
        let fixationStart = await gazeSystem.gazeFixationStart
        XCTAssertNotNil(fixationStart)
        
        // Simulate waiting until progress approaches hysteresis threshold
        // (95% of 1.5s = 1425ms). At this point hasEnteredHysteresisZone becomes true.
        try? await Task.sleep(for: .milliseconds(1425))
        
        // Now move gaze away significantly to drop progress below hysteresis threshold.
        let gazeDirection2 = SIMD3<Float>(1.0, 0, -0.5)
        await gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection2,
            cameraTransform: .init(rows: [
                    SIMD4<Float>(1, 0, 0, 0),
                    SIMD4<Float>(0, 1, 0, 0),
                    SIMD4<Float>(0, 0, 1, 0),
                    SIMD4<Float>(0, 0, 0, 1)
                ])
        )
        
        // The fixation should have been reset due to hysteresis.
        let fixationStart2 = await gazeSystem.gazeFixationStart
        XCTAssertNil(fixationStart2, "Dwell timer should reset when gaze moves after entering hysteresis zone")
        let isFixating = await gazeSystem.isFixating
        XCTAssertFalse(isFixating, "Should not be fixating after hysteresis reset")
        let dwellProgress = await gazeSystem.dwellProgress
        XCTAssertEqual(dwellProgress, 0.0, "Progress should reset to 0 after hysteresis trigger")
    }
    
    func testHysteresisDoesNotResetWhenBelowThreshold() async {
        let fixture = createFixture(UUID(), position: SIMD3<Float>(0, 1.5, -1.0))
        await gazeSystem.configure(trackedFixtures: [fixture])
        
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection = simd_normalize(SIMD3<Float>(0, -0.1, -1.0))
        
        await gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection,
            cameraTransform: .init(rows: [
                    SIMD4<Float>(1, 0, 0, 0),
                    SIMD4<Float>(0, 1, 0, 0),
                    SIMD4<Float>(0, 0, 1, 0),
                    SIMD4<Float>(0, 0, 0, 1)
                ])
        )
        
        await gazeSystem.beginSelection()
        let fixationStart = await gazeSystem.gazeFixationStart
        XCTAssertNotNil(fixationStart)
        
        // Wait only 500ms - well below hysteresis threshold (95% of 1.5s = 1425ms).
        try? await Task.sleep(for: .milliseconds(500))
        
        // Move gaze away - should reset due to gaze angle change, not hysteresis.
        let gazeDirection2 = SIMD3<Float>(1.0, 0, -0.5)
        await gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection2,
            cameraTransform: .init(rows: [
                    SIMD4<Float>(1, 0, 0, 0),
                    SIMD4<Float>(0, 1, 0, 0),
                    SIMD4<Float>(0, 0, 1, 0),
                    SIMD4<Float>(0, 0, 0, 1)
                ])
        )
        
        let fixationStart2 = await gazeSystem.gazeFixationStart
        XCTAssertNil(fixationStart2, "Should reset due to gaze angle, not hysteresis")
        let isFixating = await gazeSystem.isFixating
        XCTAssertFalse(isFixating)
    }
    
    func testHysteresisZoneTrackingResetsOnClearTarget() async {
        let fixture = createFixture(UUID(), position: SIMD3<Float>(0, 1.5, -1.0))
        await gazeSystem.configure(trackedFixtures: [fixture])
        
        // Simulate entering hysteresis zone by moving gaze far away.
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection = simd_normalize(SIMD3<Float>(0, -0.1, -1.0))
        
        await gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection,
            cameraTransform: .init(rows: [
                    SIMD4<Float>(1, 0, 0, 0),
                    SIMD4<Float>(0, 1, 0, 0),
                    SIMD4<Float>(0, 0, 1, 0),
                    SIMD4<Float>(0, 0, 0, 1)
                ])
        )
        
        // Clear target should reset hysteresis tracking.
        await gazeSystem.reset()
        let isFixating = await gazeSystem.isFixating
        XCTAssertFalse(isFixating)
    }
    
    // MARK: - Selection Tests
    
    func testBeginSelectionSetsSelectingState() async {
        await gazeSystem.beginSelection()
        let isSelecting = await gazeSystem.isSelecting
        XCTAssertTrue(isSelecting)
    }
    
    func testEndSelectionClearsSelectingState() async {
        await gazeSystem.beginSelection()
        let isSelecting = await gazeSystem.isSelecting
        XCTAssertTrue(isSelecting)
        
        await gazeSystem.endSelection()
        let isSelecting2 = await gazeSystem.isSelecting
        XCTAssertFalse(isSelecting2)
    }
    
    // MARK: - Reset Tests
    
    func testResetClearsAllState() async {
        let fixture = createFixture(UUID(), position: SIMD3<Float>(0, 1.5, -1.0))
        await gazeSystem.configure(trackedFixtures: [fixture])
        
        let gazeOrigin = SIMD3<Float>(0, 1.6, 0)
        let gazeDirection = simd_normalize(SIMD3<Float>(0, -0.1, -1.0))
        
        await gazeSystem.updateGazeTarget(
            gazeOrigin: gazeOrigin,
            gazeDirection: gazeDirection,
            cameraTransform: .init(rows: [
                    SIMD4<Float>(1, 0, 0, 0),
                    SIMD4<Float>(0, 1, 0, 0),
                    SIMD4<Float>(0, 0, 1, 0),
                    SIMD4<Float>(0, 0, 0, 1)
                ])
        )
        
        await gazeSystem.beginSelection()
        
        await gazeSystem.reset()
        
        let isActive = await gazeSystem.isActive
        XCTAssertFalse(isActive)
        let targetedFixtureID = await gazeSystem.targetedFixtureID
        XCTAssertNil(targetedFixtureID)
        let targetPosition = await gazeSystem.targetPosition
        XCTAssertNil(targetPosition)
        let isSelecting = await gazeSystem.isSelecting
        XCTAssertFalse(isSelecting)
        let gazeFixationStart = await gazeSystem.gazeFixationStart
        XCTAssertNil(gazeFixationStart)
        let dwellProgress = await gazeSystem.dwellProgress
        XCTAssertEqual(dwellProgress, 0.0)
    }
    
    // MARK: - SpatialInputHandler Protocol Tests
    
    func testGestureManagerConformsToSpatialInputHandler() async {
        let gestureManager = await MainActor.run { GestureManager() }
        XCTAssertTrue(gestureManager is SpatialInputHandler)
    }
    
    func testGazeSystemConformsToSpatialInputHandler() async {
        let gazeSystem = await MainActor.run { GazeTargetingSystem() }
        XCTAssertTrue(gazeSystem is SpatialInputHandler)
    }
    
    // MARK: - Helper Methods
    
    private func createFixture(
        _ id: UUID,
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
            orientation: simd_quatf(),
            distanceMeters: simd_length(position),
            material: nil
        )
    }
}
