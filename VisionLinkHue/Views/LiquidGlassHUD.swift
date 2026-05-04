import SwiftUI

/// Liquid glass styling utilities for the HUD overlay components.
/// Provides reusable color schemes and padding configurations for the
/// glass effect aesthetic used across `FixtureReticle`, `HueControlPanel`, and `SceneRecallButton`.
enum LiquidGlassHUD {
    
    /// Confidence-based color gradient for HUD indicators.
    static func confidenceGradient(for confidence: Double) -> [Color] {
        switch confidence {
        case 0.9...:
            return [.green, .green.opacity(0.3)]
        case 0.85...:
            return [.green.opacity(0.8), .yellow.opacity(0.3)]
        case 0.7...:
            return [.yellow, .orange.opacity(0.3)]
        default:
            return [.red, .orange.opacity(0.3)]
        }
    }
    
    /// Confidence-based solid color for HUD badges.
    static func confidenceColor(for confidence: Double) -> Color {
        switch confidence {
        case 0.9...:
            return .green
        case 0.85...:
            return .green.opacity(0.8)
        case 0.7...:
            return .yellow
        default:
            return .red
        }
    }
    
    /// Gradient for the "Connecting" / relocalization state indicator.
    static let connectingGradient = LinearGradient(
        colors: [.blue.opacity(0.8), .blue.opacity(0.3), .clear],
        startPoint: .leading,
        endPoint: .trailing
    )
    
    /// Solid color for the relocalization progress bar.
    static let connectingProgressColor: Color = .blue
    
    /// Gradient for the pinch gesture brightness indicator.
    static let pinchGradient = LinearGradient(
        colors: [.orange.opacity(0.8), .yellow.opacity(0.5)],
        startPoint: .bottom,
        endPoint: .top
    )
    
    /// Standard padding configuration for HUD panels.
    static let panelPadding = EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    
    /// Standard panel width for control panels.
    static let panelWidth: CGFloat = 220
}
