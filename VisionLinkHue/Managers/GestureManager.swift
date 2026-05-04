import RealityKit
import Vision
import CoreHaptics
import Foundation
import os

/// Represents the state of a pinch gesture interaction with a fixture.
enum PinchGestureState: Sendable {
    /// No pinch gesture is active.
    case inactive
    /// Pinch gesture has begun; waiting for vertical movement data.
    case began
    /// Pinch gesture is actively moving; provides brightness delta.
    case active(brightnessDelta: Float)
    /// Pinch gesture has ended; holds the final brightness value.
    case ended(finalBrightness: Int)
}

/// Manages hand-tracking pinch gestures for spatial fixture control.
/// Detects pinch gestures when the user's hand is within 0.5m of a
/// `TrackedFixture` and maps vertical pinch movement to brightness
/// control via the `HueClient` API.
///
/// Conforms to `SpatialInputHandler` for unified input handling alongside
/// gaze-based targeting on Apple Vision Pro.
@MainActor
@Observable
final class GestureManager: SpatialInputHandler, Sendable {
    
    /// Whether hand tracking is currently enabled.
    var isHandTrackingEnabled: Bool = false
    
    /// Whether a pinch gesture is currently being recognized.
    var isPinching: Bool = false
    
    /// The currently targeted fixture for pinch control.
    var targetedFixtureID: UUID?
    
    /// The current pinch gesture state.
    var pinchState: PinchGestureState = .inactive
    
    /// Whether this input system is currently active.
    var isActive: Bool { isHandTrackingEnabled }
    
    /// The current target position in world space, if available.
    var targetPosition: SIMD3<Float>?
    
    /// Whether the user is actively selecting (pinching or gazing).
    var isSelecting: Bool { pinchState != .inactive }
    
    /// The last recognized brightness level from pinch control.
    var lastBrightness: Int = 100
    
    /// Callback invoked when brightness changes via pinch gesture.
    var onBrightnessChange: ((Int) -> Void)?
    
    /// Callback invoked when a fixture becomes targeted by pinch gesture.
    var onFixtureTargeted: ((UUID) -> Void)?
    
    /// Callback invoked when a fixture is untargeted.
    var onFixtureUntargeted: (() -> Void)?
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "GestureManager"
    )
    
    /// Maximum distance (meters) from hand to fixture for gesture targeting.
    private let maxTargetDistance: Float = 0.5
    
    /// Pinch threshold: distance between thumb and index finger tips (normalized).
    /// Values below this indicate a pinch.
    private let pinchThreshold: Double = 0.08
    
    /// Minimum vertical movement (normalized) to register a brightness delta.
    private let minVerticalMovement: Double = 0.01
    
    /// Smoothing factor for vertical movement EMA.
    private let movementSmoothingFactor: Float = 0.3
    
    /// Previously smoothed vertical position.
    private var smoothedVerticalPosition: Float?
    
    /// Previous pinch state for delta calculation.
    private var previousPinchDistance: Double?
    
    /// Hue client for brightness control.
    private weak var hueClient: HueClientProtocol?
    
    /// Current tracked fixtures for distance calculation.
    private var trackedFixtures: [TrackedFixture] = []
    
    /// Initialize the gesture manager.
    init() {}
    
    /// Configure the gesture manager with dependencies.
    /// - Parameters:
    ///   - hueClient: The Hue client for brightness API calls.
    ///   - trackedFixtures: Currently tracked fixtures for proximity calculation.
    func configure(
        hueClient: HueClientProtocol,
        trackedFixtures: [TrackedFixture]
    ) {
        self.hueClient = hueClient
        self.trackedFixtures = trackedFixtures
    }
    
    /// Update the current target based on gaze direction (no-op for hand-tracking).
    /// GestureManager handles hand-based input only; gaze targeting is delegated
    /// to `GazeTargetingSystem`. This method satisfies the `SpatialInputHandler` protocol.
    func updateGazeTarget(gazeOrigin: SIMD3<Float>, gazeDirection: SIMD3<Float>, cameraTransform: simd_float4x4) {
        // No-op: hand-tracking gesture manager does not process gaze input.
        // Gaze targeting is handled by GazeTargetingSystem.
    }
    
    /// Begin a selection gesture. For hand-tracking, this starts the pinch sequence.
    func beginSelection() {
        pinchState = .began
        isPinching = true
        logger.debug("Selection gesture began via hand tracking")
    }
    
    /// End a selection gesture. For hand-tracking, this completes the pinch.
    func endSelection() {
        if pinchState != .inactive {
            let finalBrightness = clampBrightness(lastBrightness + Int(pinchState == .active(brightnessDelta: 0) ? 0 : 0))
            pinchState = .ended(finalBrightness: finalBrightness)
            lastBrightness = finalBrightness
            isPinching = false
            logger.debug("Selection gesture ended via hand tracking: brightness=\(finalBrightness)")
        }
    }
    
    /// Process a hand pose observation and update gesture state.
    /// - Parameters:
    ///   - handPose: The detected hand pose observation from Vision.
    ///   - cameraTransform: Current camera transform for distance calculation.
    /// - Returns: The updated pinch state.
    func processHandPose(
        _ handPose: VNHandPoseObservation,
        cameraTransform: simd_float4x4
    ) -> PinchGestureState {
        
        guard let thumbTip = handPose.landmarks.landmarks[.thumbTip],
              let indexTip = handPose.landmarks.landmarks[.indexFingerTip] else {
            return .inactive
        }
        
        // Calculate pinch distance (normalized).
        let pinchDistance = sqrt(
            pow(thumbTip.x - indexTip.x, 2) +
            pow(thumbTip.y - indexTip.y, 2)
        )
        
        // Calculate vertical position of pinch point.
        let pinchY = (thumbTip.y + indexTip.y) * 0.5
        
        // Check if we're in a pinch.
        let isPinching = pinchDistance < pinchThreshold
        
        // Calculate brightness delta from vertical movement.
        var brightnessDelta: Float = 0
        if let prevDistance = previousPinchDistance {
            let distanceChange = prevDistance - pinchDistance
            brightnessDelta = Float(distanceChange) * 200.0
        }
        
        // Apply EMA smoothing to vertical movement.
        let currentVertical = Float(pinchY)
        smoothedVerticalPosition = updateEMA(
            value: currentVertical,
            current: smoothedVerticalPosition,
            alpha: movementSmoothingFactor
        )
        
        // Update pinch state.
        if isPinching {
            if pinchState == .inactive || pinchState == .ended {
                pinchState = .began
                logger.debug("Pinch gesture began")
            } else if brightnessDelta.magnitude > minVerticalMovement {
                pinchState = .active(brightnessDelta: brightnessDelta)
            }
        } else {
            if pinchState != .inactive {
                let finalBrightness = clampBrightness(lastBrightness + Int(brightnessDelta))
                pinchState = .ended(finalBrightness: finalBrightness)
                lastBrightness = finalBrightness
                logger.debug("Pinch gesture ended: brightness=\(finalBrightness)")
            }
        }
        
        previousPinchDistance = pinchDistance
        
        return pinchState
    }
    
    /// Find the closest fixture to the hand pose for targeting.
    /// - Parameters:
    ///   - handPosition3D: 3D position of the hand in world space.
    /// - Returns: The closest fixture within range, or nil.
    func findTargetFixture(handPosition3D: SIMD3<Float>) -> TrackedFixture? {
        guard !trackedFixtures.isEmpty else { return nil }
        
        var closestFixture: TrackedFixture?
        var closestDistance: Float = maxTargetDistance
        
        for fixture in trackedFixtures {
            let distance = simd_length(
                SIMD3<Float>(
                    fixture.position.x - handPosition3D.x,
                    fixture.position.y - handPosition3D.y,
                    fixture.position.z - handPosition3D.z
                )
            )
            
            if distance < closestDistance {
                closestDistance = distance
                closestFixture = fixture
            }
        }
        
        return closestFixture
    }
    
    /// Update the list of tracked fixtures for proximity calculation.
    func updateTrackedFixtures(_ fixtures: [TrackedFixture]) {
        self.trackedFixtures = fixtures
    }
    
    /// Apply the current pinch brightness to the targeted fixture's Hue light.
    func applyPinchBrightness() async {
        guard let hueClient else { return }
        
        guard let fixtureID = targetedFixtureID,
              let fixture = trackedFixtures.first(where: { $0.id == fixtureID }),
              let lightId = fixture.mappedHueLightId else { return }
        
        let brightness = clampBrightness(lastBrightness)
        
        do {
            try await hueClient.setBrightness(resourceId: lightId, brightness: brightness, transitionDuration: 4)
            onBrightnessChange?(brightness)
        } catch {
            logger.error("Failed to set brightness via pinch: \(error.localizedDescription)")
        }
    }
    
    /// Set the targeted fixture for pinch control.
    func setTargetedFixture(_ fixture: TrackedFixture?) {
        if let fixture = fixture {
            targetedFixtureID = fixture.id
            onFixtureTargeted?(fixture.id)
            logger.debug("Targeted fixture \(fixture.id) for pinch control")
        } else {
            if targetedFixtureID != nil {
                onFixtureUntargeted?()
            }
            targetedFixtureID = nil
        }
    }
    
    /// Reset gesture state.
    func reset() {
        pinchState = .inactive
        isPinching = false
        targetedFixtureID = nil
        smoothedVerticalPosition = nil
        previousPinchDistance = nil
        lastBrightness = 100
    }
    
    // MARK: - Haptic Feedback
    
    /// Provide haptic feedback for a pinch state transition.
    /// Uses CoreHaptics for rich haptic patterns on supported devices.
    func provideHapticFeedback(for state: PinchGestureState) {
        switch state {
        case .began:
            provideImpactFeedback(style: .light)
        case .active:
            provideImpactFeedback(style: .soft)
        case .ended:
            provideImpactFeedback(style: .medium)
        case .inactive:
            break
        }
    }
    
    /// Provide a light haptic impact.
    private func provideImpactFeedback(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
        generator.prepare()
    }
    
    // MARK: - Private Helpers
    
    /// Clamp brightness to valid Hue range (1-254).
    private func clampBrightness(_ value: Int) -> Int {
        max(1, min(254, value))
    }
    
    /// Apply exponential moving average smoothing.
    private func updateEMA(value: Float, current: Float?, alpha: Float) -> Float {
        guard let current = current else { return value }
        return alpha * value + (1 - alpha) * current
    }
}
