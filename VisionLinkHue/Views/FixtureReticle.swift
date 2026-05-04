import SwiftUI
import RealityKit
import simd

/// Represents the visual state of the fixture reticle for gesture and session feedback.
enum ReticleVisualState: Sendable {
    /// Normal detection state.
    case normal
    /// Hand is near the fixture, ready for pinch gesture.
    case handNearby
    /// Pinch gesture is active, controlling brightness.
    case pinchActive(brightness: Int)
    /// AR session is relocalizing against a saved world map.
    case connecting(progress: Float)
    /// Relocalization failed, showing retry state.
    case relocalizationFailed
    /// User is gazing at the fixture (Vision Pro).
    case gazeTargeted
    /// User is fixating on the fixture with dwell selection in progress.
    case gazeDwell(progress: Float)
    /// User is actively selecting via gaze (pinch-confirm after gaze).
    case gazeSelecting
}

/// 3D reticle overlay shown at detected fixture positions.
/// Uses phaseAnimator to pulse when detection confidence is low.
/// Supports pinch gesture feedback and AR relocalization visual states.
struct FixtureReticle: View {
    
    let fixture: TrackedFixture
    let onSelect: () -> Void
    
    /// Visual state for gesture and session feedback.
    let visualState: ReticleVisualState
    
    /// Threshold below which the reticle pulses to indicate low certainty.
    private let lowCertaintyThreshold: Double = 0.85
    
    /// Whether the detection confidence is below the threshold.
    private var isLowCertainty: Bool {
        fixture.detection.confidence < lowCertaintyThreshold
    }
    
    /// Whether the reticle is in a connecting/relocalizing state.
    private var isConnecting: Bool {
        switch visualState {
        case .connecting: return true
        default: return false
        }
    }
    
    /// Whether a pinch gesture is active on this reticle.
    private var isPinching: Bool {
        switch visualState {
        case .pinchActive: return true
        default: return false
        }
    }
    
    /// Whether the reticle is being gazed at.
    private var isGazeTargeted: Bool {
        switch visualState {
        case .gazeTargeted, .gazeDwell, .gazeSelecting: return true
        default: return false
        }
    }
    
    /// Current dwell progress from gaze targeting.
    private var gazeDwellProgress: Float {
        switch visualState {
        case .gazeDwell(let progress): return progress
        default: return 0.0
        }
    }
    
    /// Current brightness value from pinch gesture.
    private var currentBrightness: Int {
        switch visualState {
        case .pinchActive(let brightness): return brightness
        default: return 100
        }
    }
    
    var body: some View {
        ZStack {
            // Connecting ring animation for relocalization state
            if isConnecting {
                ConnectingRingView(progress: connectingProgress)
            }
            
            // Gaze dwell ring animation for Vision Pro
            if isGazeTargeted {
                GazeDwellRingView(progress: gazeDwellProgress, isActive: isGazeTargeted)
            }
            
            // Outer ring - glass effect
            ReticleRingView(visualState: visualState)
            
            // Center dot
            ReticleDotView(visualState: visualState)
            
            // Crosshair
            CrosshairView()
            
            // Confidence indicator (arc at top)
            if fixture.detection.confidence > 0 {
                ConfidenceArcView(confidence: fixture.detection.confidence)
            }
            
            // Brightness indicator for pinch gesture
            if isPinching {
                brightnessIndicator
            }
        }
        .phaseAnimator([1.0, 1.15]) { content, phase in
            if isLowCertainty || isPinching {
                content
                    .scaleEffect(phase)
                    .opacity(isLowCertainty ? 0.5 + phase * 0.5 : 1.0)
            } else {
                content
            }
        } animation: { phase in
            if isLowCertainty {
                .easeInOut(duration: 1.5)
            } else if isPinching {
                .easeInOut(duration: 0.3)
            } else {
                .easeInOut(duration: 0.5)
            }
        }
        .onTapGesture(count: 1) {
            onSelect()
        }
        .rotation3DEffect(
            .degrees(0),
            axis: (x: 0, y: 1, z: 0)
        )
        .accessibilityLabel(Text(fixture.type.displayName))
        .accessibilityHint(Text("Detection confidence \(Int(fixture.detection.confidence * 100)) percent. Tap to select."))
        .accessibilityValue(Text("\(Int(fixture.detection.confidence * 100))% confidence"))
        #if !targetEnvironment(simulator)
        .glassEffect(.liquid, alignment: .center)
        #endif
    }
    
    // MARK: - Connecting Ring
    
    private var connectingProgress: Float {
        switch visualState {
        case .connecting(let progress):
            return progress
        default:
            return 0
        }
    }
    
    // MARK: - Pinch Gesture Visuals
    
    private var brightnessIndicator: some View {
        BrightnessIndicatorView(brightness: currentBrightness)
    }
}

// MARK: - Sub-Views

/// Extracted sub-view for the connecting ring animation during relocalization.
private struct ConnectingRingView: View {
    let progress: Float
    
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.6)
            .stroke(
                LinearGradient(
                    colors: [.blue.opacity(0.8), .blue.opacity(0.2)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
            .frame(width: 80, height: 80)
            .rotationEffect(.degrees(progress * 360.0))
            .opacity(0.8)
    }
}

/// Extracted sub-view for the gaze dwell ring animation on Vision Pro.
private struct GazeDwellRingView: View {
    let progress: Float
    let isActive: Bool
    
    var body: some View {
        Circle()
            .trim(from: 0, to: progress)
            .stroke(
                LinearGradient(
                    colors: [.purple.opacity(0.8), .purple.opacity(0.3)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
            .frame(width: 80, height: 80)
            .rotationEffect(.degrees(progress * 360.0))
            .opacity(isActive ? 0.8 : 0.0)
    }
}

/// Extracted sub-view for the crosshair overlay at the reticle center.
private struct CrosshairView: View {
    var body: some View {
        ZStack {
            // Vertical crosshair
            VStack(spacing: 0) {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.8), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 1.5, height: 12)
                    .offset(y: -8)
                
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.8), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 1.5, height: 12)
                    .offset(y: 8)
            }
            
            // Horizontal crosshair
            HStack(spacing: 0) {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.8), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 12, height: 1.5)
                    .offset(x: -8)
                
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 12, height: 1.5)
                    .offset(x: 8)
            }
        }
    }
}

/// Extracted sub-view for the confidence arc indicator.
private struct ConfidenceArcView: View {
    let confidence: Double
    
    var body: some View {
        Circle()
            .trim(from: 0, to: 1.0)
            .stroke(
                LinearGradient(
                    colors: LiquidGlassHUD.confidenceGradient(for: confidence),
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
            .rotation3DEffect(.degrees(-90), axis: (x: 0, y: 1, z: 0))
            .frame(width: 70, height: 70)
            .opacity(0.7)
    }
}

/// Extracted sub-view for the brightness indicator during pinch gesture.
private struct BrightnessIndicatorView: View {
    let brightness: Int
    
    var body: some View {
        VStack(spacing: 2) {
            Text("\(brightness)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Rectangle()
                        .fill(.white.opacity(0.15))
                        .frame(width: geo.size.width, height: geo.size.height)
                    
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.orange, .yellow.opacity(0.6)],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(
                            width: geo.size.width,
                            height: geo.size.height * (Double(brightness) / 254.0)
                        )
                }
                .cornerRadius(2)
            }
            .frame(width: 16, height: 30)
        }
    }
}

/// Extracted sub-view for the outer ring with state-dependent styling.
private struct ReticleRingView: View {
    let visualState: ReticleVisualState
    
    private var ringColors: [Color] {
        switch visualState {
        case .pinchActive:
            return [.orange.opacity(0.7), .yellow.opacity(0.4), .orange.opacity(0.2)]
        case .gazeSelecting:
            return [.purple.opacity(0.7), .indigo.opacity(0.4), .purple.opacity(0.2)]
        case .gazeTargeted, .gazeDwell:
            return [.purple.opacity(0.6), .indigo.opacity(0.3), .purple.opacity(0.1)]
        case .handNearby:
            return [.white.opacity(0.7), .blue.opacity(0.4), .white.opacity(0.2)]
        default:
            return [.white.opacity(0.6), .blue.opacity(0.3), .white.opacity(0.1)]
        }
    }
    
    private var lineWidth: CGFloat {
        switch visualState {
        case .pinchActive, .gazeSelecting: return 3
        case .handNearby, .gazeTargeted, .gazeDwell: return 2.5
        default: return 2
        }
    }
    
    private var ringSize: CGFloat {
        switch visualState {
        case .pinchActive: return 68
        case .gazeSelecting: return 72
        case .handNearby, .gazeTargeted, .gazeDwell: return 64
        default: return 60
        }
    }
    
    var body: some View {
        Circle()
            .strokeBorder(
                LinearGradient(
                    colors: ringColors,
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                lineWidth: lineWidth
            )
            .frame(width: ringSize, height: ringSize)
    }
}

/// Extracted sub-view for the center dot with state-dependent styling.
private struct ReticleDotView: View {
    let visualState: ReticleVisualState
    
    private var dotColor: Color {
        switch visualState {
        case .pinchActive: return .orange.opacity(0.9)
        case .gazeSelecting, .gazeTargeted, .gazeDwell: return .purple.opacity(0.9)
        case .handNearby: return .blue.opacity(0.7)
        default: return .white.opacity(0.9)
        }
    }
    
    private var dotSize: CGFloat {
        switch visualState {
        case .pinchActive: return 6
        case .gazeSelecting: return 7
        case .handNearby, .gazeTargeted, .gazeDwell: return 5
        default: return 4
        }
    }
    
    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: dotSize, height: dotSize)
    }
}
