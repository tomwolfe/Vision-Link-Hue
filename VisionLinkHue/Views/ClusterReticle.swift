import SwiftUI
import RealityKit
import simd

/// Represents the visual state of a cluster reticle showing grouped fixtures.
enum ClusterReticleVisualState: Sendable {
    /// Normal cluster detection state.
    case normal
    /// Hand is near the cluster, ready for pinch gesture.
    case handNearby
    /// Pinch gesture is active, controlling brightness for all cluster members.
    case pinchActive(brightness: Int)
    /// User is gazing at the cluster (Vision Pro).
    case gazeTargeted
    /// User is fixating on the cluster with dwell selection in progress.
    case gazeDwell(progress: Float)
    /// User is actively selecting via gaze (pinch-confirm after gaze).
    case gazeSelecting
}

/// 3D reticle overlay shown at clustered fixture positions.
/// Displays a larger reticle with member count indicator.
struct ClusterReticle: View {
    
    let cluster: SpatialCluster
    let onSelect: () -> Void
    
    /// Visual state for gesture and session feedback.
    let visualState: ClusterReticleVisualState
    
    /// Whether the reticle is in a connecting/relocalizing state.
    private var isConnecting: Bool { false }
    
    /// Whether a pinch gesture is active on this cluster.
    private var isPinching: Bool {
        switch visualState {
        case .pinchActive: return true
        default: return false
        }
    }
    
    /// Whether the cluster is being gazed at.
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
                ConnectingRingView(progress: 0.5)
            }
            
            // Gaze dwell ring animation for Vision Pro
            if isGazeTargeted {
                GazeDwellRingView(progress: gazeDwellProgress, isActive: isGazeTargeted)
            }
            
            // Outer cluster ring - larger than single fixture
            ClusterRingView(visualState: visualState)
            
            // Center dot
            ClusterDotView(visualState: visualState)
            
            // Crosshair
            CrosshairView()
            
            // Fixture count badge
            fixtureCountBadge
            
            // Average confidence indicator
            if cluster.averageConfidence > 0 {
                ConfidenceArcView(confidence: cluster.averageConfidence)
            }
            
            // Brightness indicator for pinch gesture
            if isPinching {
                brightnessIndicator
            }
        }
        .phaseAnimator([1.0, 1.08]) { content, phase in
            if isPinching {
                content
                    .scaleEffect(phase)
            } else {
                content
            }
        } animation: { phase in
            if isPinching {
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
        .accessibilityLabel(Text("\(cluster.label) cluster"))
        .accessibilityHint(Text("\(cluster.lightCount) fixtures detected. Tap to control all."))
        .accessibilityValue(Text("\(cluster.lightCount) fixtures at \(String(format: "%.1f", cluster.averageConfidence * 100))% confidence"))
        #if !targetEnvironment(simulator)
        if #available(iOS 26, *) {
            .glassEffect(.liquid, alignment: .center)
        }
        #endif
    }
    
    // MARK: - Sub-Views
    
    private var fixtureCountBadge: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 28, height: 28)
            
            Text("\(cluster.lightCount)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .offset(y: -38)
    }
    
    private var brightnessIndicator: some View {
        BrightnessIndicatorView(brightness: currentBrightness)
    }
}

// MARK: - Cluster Reticle Sub-Views

/// Extracted sub-view for the cluster ring with state-dependent styling.
private struct ClusterRingView: View {
    let visualState: ClusterReticleVisualState
    
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
            return [.white.opacity(0.5), .blue.opacity(0.25), .white.opacity(0.1)]
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
        case .pinchActive: return 80
        case .gazeSelecting: return 84
        case .handNearby, .gazeTargeted, .gazeDwell: return 78
        default: return 74
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

/// Extracted sub-view for the cluster center dot with state-dependent styling.
private struct ClusterDotView: View {
    let visualState: ClusterReticleVisualState
    
    private var dotColor: Color {
        switch visualState {
        case .pinchActive: return .orange.opacity(0.9)
        case .gazeSelecting, .gazeTargeted, .gazeDwell: return .purple.opacity(0.9)
        case .handNearby: return .blue.opacity(0.7)
        default: return .white.opacity(0.8)
        }
    }
    
    private var dotSize: CGFloat {
        switch visualState {
        case .pinchActive: return 8
        case .gazeSelecting: return 9
        case .handNearby, .gazeTargeted, .gazeDwell: return 7
        default: return 6
        }
    }
    
    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: dotSize, height: dotSize)
    }
}
