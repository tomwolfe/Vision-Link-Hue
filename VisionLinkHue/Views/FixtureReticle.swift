import SwiftUI
import RealityKit
import simd

/// 3D reticle overlay shown at detected fixture positions.
/// Uses phaseAnimator to pulse when detection confidence is low.
struct FixtureReticle: View {
    
    let fixture: TrackedFixture
    let onSelect: () -> Void
    
    /// Threshold below which the reticle pulses to indicate low certainty.
    private let lowCertaintyThreshold: Double = 0.85
    
    /// Whether the detection confidence is below the threshold.
    private var isLowCertainty: Bool {
        fixture.detection.confidence < lowCertaintyThreshold
    }
    
    var body: some View {
        ZStack {
            // Outer ring - glass effect
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.6),
                            .blue.opacity(0.3),
                            .white.opacity(0.1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 2
                )
                .frame(width: 60, height: 60)
            
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
                    .fill(.white.opacity(0.9))
                    .frame(width: 4, height: 4)
                
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
        }
        .phaseAnimator([1.0, 1.15]) { content, phase in
            content
                .scaleEffect(phase)
                .opacity(isLowCertainty ? 0.5 + phase * 0.5 : 1.0)
        } animation: { phase in
            if isLowCertainty {
                .easeInOut(duration: 1.5)
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
}
