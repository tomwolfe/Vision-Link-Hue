import Foundation
import simd
import Vision
import RealityKit
import os

/// Protocol abstraction for spatial input systems.
/// Enables unified handling of hand-tracking pinch (iPhone/iPad) and
/// gaze-based targeting (Apple Vision Pro) through a single interface.
@MainActor
protocol SpatialInputHandler: AnyObject {
    
    /// Whether this input system is currently active.
    var isActive: Bool { get }
    
    /// The currently targeted fixture, if any.
    var targetedFixtureID: UUID? { get }
    
    /// The current target position in world space, if available.
    var targetPosition: SIMD3<Float>? { get }
    
    /// Whether the user is actively selecting (pinching or gazing).
    var isSelecting: Bool { get }
    
    /// Callback invoked when a fixture becomes targeted.
    var onFixtureTargeted: ((UUID) -> Void)? { get set }
    
    /// Callback invoked when the target fixture is untargeted.
    var onFixtureUntargeted: (() -> Void)? { get set }
    
    /// Callback invoked when brightness changes via spatial input.
    var onBrightnessChange: ((Int) -> Void)? { get set }
    
    /// Configure the handler with tracked fixtures for proximity calculation.
    func configure(trackedFixtures: [TrackedFixture])
    
    /// Process a hand pose observation for pinch detection.
    func processHandPose(_ handPose: Any, cameraTransform: simd_float4x4) -> PinchGestureState
    
    /// Update the current target based on gaze direction.
    func updateGazeTarget(gazeOrigin: SIMD3<Float>, gazeDirection: SIMD3<Float>, cameraTransform: simd_float4x4)
    
    /// Begin a selection gesture (eye-dwell or pinch).
    func beginSelection()
    
    /// End a selection gesture.
    func endSelection()
    
    /// Reset the handler state.
    func reset()
}

/// Represents the type of spatial input being used.
enum SpatialInputType: Sendable {
    /// Hand-tracking pinch gesture (iPhone/iPad).
    case handPinch
    /// Eye gaze with dwell selection (Vision Pro).
    case gazeDwell
    /// Eye gaze with pinch confirmation (Vision Pro).
    case gazePinch
}

/// Configuration for gaze-based targeting on Apple Vision Pro.
struct GazeTargetingConfiguration: Sendable {
    /// Minimum dwell time (seconds) before a gaze target is selected.
    let dwellDuration: TimeInterval
    
    /// Maximum angular deviation (degrees) for gaze fixation.
    let fixationAngleDegrees: Double
    
    /// Maximum distance (meters) from gaze ray to fixture for targeting.
    let maxTargetDistance: Float
    
    /// Minimum detection confidence to be eligible for gaze targeting.
    let minConfidence: Double
    
    /// Visual feedback interval: how often to update gaze progress.
    let feedbackInterval: TimeInterval
    
    /// Hysteresis threshold (0.0 to 1.0) for dwell progress.
    /// When progress exceeds this value, any subsequent drop below it
    /// triggers a dwell timer reset. This prevents eye-tracking jitter
    /// from causing flicker near the selection threshold on Vision Pro hardware.
    /// Default: 0.95 (resets if progress drops below 95% once near completion).
    let hysteresisThreshold: Float
    
    static let `default` = GazeTargetingConfiguration(
        dwellDuration: 1.5,
        fixationAngleDegrees: 3.0,
        maxTargetDistance: 5.0,
        minConfidence: 0.5,
        feedbackInterval: 0.1,
        hysteresisThreshold: 0.95
    )
}

/// Manages gaze-based targeting for Apple Vision Pro spatial input.
/// Tracks where the user is looking and provides dwell-time selection
/// when the user fixates on a fixture. Supports both pure gaze selection
/// and gaze-plus-pinch (gaze to aim, pinch to confirm).
@MainActor
@Observable
final class GazeTargetingSystem: SpatialInputHandler, Sendable {
    
    var isActive: Bool = false
    var targetedFixtureID: UUID?
    var targetPosition: SIMD3<Float>?
    var isSelecting: Bool = false
    
    var onFixtureTargeted: ((UUID) -> Void)?
    var onFixtureUntargeted: (() -> Void)?
    var onBrightnessChange: ((Int) -> Void)?
    
    /// The type of gaze input currently in use.
    /// Defaults to `.gazePinch` for Vision Pro gaze-plus-pinch confirmation.
    var inputType: SpatialInputType = .gazePinch
    
    /// Configuration for gaze targeting behavior.
    private var configuration: GazeTargetingConfiguration
    
    /// Currently tracked fixtures for distance calculation.
    private var trackedFixtures: [TrackedFixture] = []
    
    /// The fixture currently under gaze.
    private var currentGazeTarget: TrackedFixture?
    
    /// Time when gaze fixation began on the current target.
    var gazeFixationStart: ContinuousClock.Instant?
    
    /// Last gaze direction vector (normalized).
    private var lastGazeDirection: SIMD3<Float>?
    
    /// Last gaze origin in world space.
    private var lastGazeOrigin: SIMD3<Float>?
    
    /// Previous gaze target for dwell tracking continuity.
    private var previousGazeTargetID: UUID?
    
    /// Dwell progress (0.0 to 1.0) for visual feedback.
    var dwellProgress: Float = 0.0
    
    /// Whether the user is currently fixating (within fixation angle).
    var isFixating: Bool = false
    
    /// Whether gaze progress has previously exceeded the hysteresis threshold.
    /// Once true, any drop below hysteresisThreshold resets the dwell timer.
    private var hasEnteredHysteresisZone: Bool = false
    
    /// Last timestamp when UI feedback properties were updated.
    /// Throttles @Observable mutations to the feedbackInterval rate
    /// to prevent excessive SwiftUI view invalidations during high-frequency
    /// AR frame processing (typically 60-120fps).
    private var lastFeedbackTime: ContinuousClock.Instant?
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "GazeTargeting"
    )
    
    /// Initialize with default configuration.
    init(configuration: GazeTargetingConfiguration = .default) {
        self.configuration = configuration
    }
    
    func configure(trackedFixtures: [TrackedFixture]) {
        self.trackedFixtures = trackedFixtures
    }
    
    func processHandPose(_ handPose: Any, cameraTransform: simd_float4x4) -> PinchGestureState {
        // Gaze system delegates pinching to GestureManager;
        // this is a no-op stub to satisfy the protocol.
        return .inactive
    }
    
    func updateGazeTarget(gazeOrigin: SIMD3<Float>, gazeDirection: SIMD3<Float>, cameraTransform: simd_float4x4) {
        guard !trackedFixtures.isEmpty else {
            clearTarget()
            return
        }
        
        let normalizedDirection = simd_normalize(gazeDirection)
        
        // Check if gaze direction has changed significantly from last frame.
        if let lastDir = lastGazeDirection {
            let dotProduct = simd_dot(normalizedDirection, lastDir)
            let clampedDot = max(min(dotProduct, Float(1.0)), Float(-1.0))
            let angleDiff = acos(clampedDot) * Float(180.0) / Float(Double.pi)
            
            // If gaze has moved beyond fixation angle, clear fixation timer.
            // This is a state change that must be reflected immediately in UI.
            if angleDiff > Float(configuration.fixationAngleDegrees) {
                gazeFixationStart = nil
                isFixating = false
                dwellProgress = 0.0
            }
        }
        
        // Find the closest fixture within the gaze cone.
        var closestFixture: TrackedFixture?
        var closestDistance: Float = configuration.maxTargetDistance
        var closestAngle: Float = .infinity
        
        for fixture in trackedFixtures {
            let toFixture = fixture.position - gazeOrigin
            let distance = simd_length(toFixture)
            
            // Skip fixtures behind the camera or too far away.
            guard distance > Float(0.1), distance < configuration.maxTargetDistance else { continue }
            
            let fixtureDirection = simd_normalize(toFixture)
            let fixtureDot = simd_dot(normalizedDirection, fixtureDirection)
            let clampedFixtureDot = max(min(fixtureDot, Float(1.0)), Float(-1.0))
            let angle = acos(clampedFixtureDot) * Float(180.0) / Float(Double.pi)
            
            // Skip fixtures below confidence threshold.
            guard fixture.detection.confidence >= configuration.minConfidence else { continue }
            
            if angle < closestAngle && angle < Float(configuration.fixationAngleDegrees) {
                closestAngle = angle
                closestFixture = fixture
                closestDistance = distance
            }
        }
        
        lastGazeDirection = normalizedDirection
        lastGazeOrigin = gazeOrigin
        
        // Update target if gaze has shifted to a different fixture.
        let newTargetID = closestFixture?.id
        
        if newTargetID != currentGazeTarget?.id {
            clearTarget()
            currentGazeTarget = closestFixture
            
            if let fixture = closestFixture {
                targetedFixtureID = fixture.id
                targetPosition = fixture.position
                currentGazeTarget = fixture
                onFixtureTargeted?(fixture.id)
                logger.debug("Gaze target acquired: \(fixture.id) at \(String(format: "%.2f", closestDistance))m, angle: \(String(format: "%.1f", closestAngle))°")
            }
        }
        
        // Compute dwell progress internally each frame for state tracking,
        // but only update the @Observable properties at the feedbackInterval
        // rate to prevent excessive SwiftUI view invalidations.
        let now = ContinuousClock.now
        
        if let _ = closestFixture, gazeFixationStart != nil {
            let elapsed = now - gazeFixationStart!
            let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let computedProgress = min(Float(elapsedSeconds / configuration.dwellDuration), 1.0)
            
            // Apply hysteresis buffer to prevent gaze jitter flicker near
            // the selection threshold. Once progress enters the hysteresis
            // zone (e.g., >= 0.95), any drop below it resets the dwell timer.
            // This is critical for Vision Pro hardware where eye-tracking
            // micro-saccades can cause visible UI flicker at high progress values.
            if hasEnteredHysteresisZone && computedProgress < configuration.hysteresisThreshold {
                gazeFixationStart = nil
                hasEnteredHysteresisZone = false
                isFixating = false
                dwellProgress = 0.0
            } else if computedProgress >= configuration.hysteresisThreshold {
                hasEnteredHysteresisZone = true
            }
            
            // Throttle UI updates to feedbackInterval rate.
            let shouldUpdateUI = shouldUpdateUIFeedback(now: now)
            
            if shouldUpdateUI {
                isFixating = true
                dwellProgress = computedProgress
                lastFeedbackTime = now
            }
            // Store computed progress without triggering @Observable mutation
            // when throttled - the next UI update will use the latest value.
            if !shouldUpdateUI {
                // Only update if the value would actually change when we next refresh
                let progressDiff = abs(computedProgress - dwellProgress)
                if progressDiff >= 0.01 {
                    // Queue an immediate update if progress changed meaningfully
                    dwellProgress = computedProgress
                    lastFeedbackTime = now
                }
            }
        } else {
            // Only update UI when transitioning out of fixation
            if isFixating {
                isFixating = false
                dwellProgress = 0.0
            }
            hasEnteredHysteresisZone = false
        }
    }
    
    /// Determine whether UI feedback properties should be updated.
    /// Respects the feedbackInterval to throttle @Observable mutations
    /// during high-frequency AR frame processing.
    private func shouldUpdateUIFeedback(now: ContinuousClock.Instant) -> Bool {
        guard let lastTime = lastFeedbackTime else {
            return true
        }
        
        let elapsed = now - lastTime
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return elapsedSeconds >= configuration.feedbackInterval
    }
    
    func beginSelection() {
        isSelecting = true
        
        switch inputType {
        case .gazeDwell:
            // For dwell selection, start the timer when gaze begins.
            if currentGazeTarget != nil {
                gazeFixationStart = .now
                logger.debug("Gaze dwell selection started")
            }
        case .gazePinch:
            // For gaze-plus-pinch, selection begins on pinch gesture.
            logger.debug("Gaze-pinch selection started")
        case .handPinch:
            break
        }
    }
    
    func endSelection() {
        isSelecting = false
        
        switch inputType {
        case .gazeDwell:
            // Check if dwell duration was met.
            if let start = gazeFixationStart, let targetID = targetedFixtureID {
                let elapsed = ContinuousClock.now - start
                let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                if elapsedSeconds >= configuration.dwellDuration {
                    logger.info("Gaze dwell selection confirmed on \(targetID)")
                    // Selection confirmed - the caller handles the action.
                } else {
                    logger.debug("Gaze dwell cancelled (insufficient dwell time: \(String(format: "%.2f", elapsedSeconds))s)")
                }
            }
            gazeFixationStart = nil
        case .gazePinch:
            if let targetID = targetedFixtureID {
                logger.info("Gaze-pinch selection confirmed on \(targetID)")
            }
        case .handPinch:
            break
        }
    }
    
    func reset() {
        isActive = false
        targetedFixtureID = nil
        targetPosition = nil
        isSelecting = false
        currentGazeTarget = nil
        previousGazeTargetID = nil
        gazeFixationStart = nil
        lastGazeDirection = nil
        lastGazeOrigin = nil
        dwellProgress = 0.0
        isFixating = false
        lastFeedbackTime = nil
        hasEnteredHysteresisZone = false
    }
    
    /// Check if the current dwell selection has completed.
    func checkDwellCompletion() -> Bool {
        guard let start = gazeFixationStart,
              let targetID = targetedFixtureID else {
            return false
        }
        
        let elapsed = ContinuousClock.now - start
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        
        if elapsedSeconds >= configuration.dwellDuration {
            logger.info("Gaze dwell completed on fixture \(targetID)")
            gazeFixationStart = nil
            return true
        }
        
        return false
    }
    
    private func clearTarget() {
        if currentGazeTarget != nil {
            onFixtureUntargeted?()
        }
        currentGazeTarget = nil
        targetedFixtureID = nil
        targetPosition = nil
        dwellProgress = 0.0
        isFixating = false
        hasEnteredHysteresisZone = false
    }
}
