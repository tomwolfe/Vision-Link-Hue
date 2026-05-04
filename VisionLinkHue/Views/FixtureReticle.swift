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
                connectingRing
            }
            
            // Outer ring - glass effect
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: pinchRingColors,
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: pinchLineWidth
                )
                .frame(width: pinchRingSize, height: pinchRingSize)
            
            // Inner crosshair
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
                
                Circle()
                    .fill(pinchingDotColor)
                    .frame(width: pinchingDotSize, height: pinchingDotSize)
                
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
            
            // Confidence indicator (arc at top)
            if fixture.detection.confidence > 0 {
                Circle()
                    .trim(from: 0, to: 1.0)
                    .stroke(
                        LinearGradient(
                            colors: LiquidGlassHUD.confidenceGradient(for: fixture.detection.confidence),
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotation3DEffect(.degrees(-90), axis: (x: 0, y: 1, z: 0))
                    .frame(width: 70, height: 70)
                    .opacity(0.7)
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
        #if !targetEnvironment(simulator)
        .glassEffect(.liquid, alignment: .center)
        #endif
    }
    
    // MARK: - Connecting Ring
    
    private var connectingRing: some View {
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
            .rotationEffect(.degrees(connectingRotation))
            .opacity(connectingOpacity)
    }
    
    private var connectingRotation: Double {
        switch visualState {
        case .connecting(let progress):
            return progress * 360.0
        default:
            return 0
        }
    }
    
    private var connectingOpacity: Double {
        switch visualState {
        case .connecting: return 0.8
        default: return 0
        }
    }
    
    // MARK: - Pinch Gesture Visuals
    
    private var pinchRingColors: [Color] {
        switch visualState {
        case .pinchActive:
            return [.orange.opacity(0.7), .yellow.opacity(0.4), .orange.opacity(0.2)]
        case .handNearby:
            return [.white.opacity(0.7), .blue.opacity(0.4), .white.opacity(0.2)]
        default:
            return [.white.opacity(0.6), .blue.opacity(0.3), .white.opacity(0.1)]
        }
    }
    
    private var pinchLineWidth: CGFloat {
        switch visualState {
        case .pinchActive: return 3
        case .handNearby: return 2.5
        default: return 2
        }
    }
    
    private var pinchRingSize: CGFloat {
        switch visualState {
        case .pinchActive: return 68
        case .handNearby: return 64
        default: return 60
        }
    }
    
    private var pinchingDotColor: Color {
        switch visualState {
        case .pinchActive: return .orange.opacity(0.9)
        case .handNearby: return .blue.opacity(0.7)
        default: return .white.opacity(0.9)
        }
    }
    
    private var pinchingDotSize: CGFloat {
        switch visualState {
        case .pinchActive: return 6
        case .handNearby: return 5
        default: return 4
        }
    }
    
    // MARK: - Brightness Indicator
    
    private var brightnessIndicator: some View {
        VStack(spacing: 2) {
            Text("\(currentBrightness)")
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
                            height: geo.size.height * (Double(currentBrightness) / 254.0)
                        )
                }
                .cornerRadius(2)
            }
            .frame(width: 16, height: 30)
        }
    }
}
