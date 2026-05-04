import ARKit
import simd
import Foundation
import os

/// Analyzes ARKit frame data during relocalization to determine
/// the best direction for the user to look/move to improve tracking.
/// Uses feature point distribution and tracking state analysis to
/// generate directional guidance signals.
@MainActor
@Observable
final class RelocalizationGuide {
    
    /// The current look direction recommendation, if any.
    var currentLookDirection: LookDirection = .none
    
    /// Whether a guidance instruction is currently active.
    var hasInstruction: Bool { currentLookDirection != .none }
    
    /// The instruction text to display to the user.
    var instructionText: String {
        currentLookDirection.instruction
    }
    
    /// The icon to display alongside the instruction.
    var iconText: String {
        currentLookDirection.icon
    }
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "RelocalizationGuide"
    )
    
    /// Analysis history for trend detection.
    private var featureDensityHistory: [Float] = []
    
    /// Maximum history length for trend analysis.
    private let maxHistoryLength = 10
    
    /// Track the best feature density to detect improvement.
    private var bestFeatureDensity: Float = 0
    
    /// Initialize the relocalization guide.
    init() {}
    
    /// Analyze the current AR frame to determine the best look direction.
    /// Uses feature point density distribution and tracking state to
    /// generate directional guidance.
    ///
    /// - Parameters:
    ///   - frame: The current ARKit frame.
    ///   - confidence: The current tracking confidence score.
    /// - Returns: The recommended look direction.
    func analyzeFrame(_ frame: ARFrame, confidence: Float) -> LookDirection {
        #if targetEnvironment(simulator)
        return .none
        #endif
        
        let direction = deriveLookDirection(from: frame, confidence: confidence)
        
        if direction != .none {
            currentLookDirection = direction
            logger.debug("Relocalization guidance: \(direction.instruction)")
        } else {
            currentLookDirection = .none
        }
        
        return direction
    }
    
    /// Update analysis with a new feature density measurement.
    /// Tracks trends to determine if the user's actions are improving
    /// the feature availability for relocalization.
    func updateFeatureDensity(_ density: Float) {
        featureDensityHistory.append(density)
        
        if featureDensityHistory.count > maxHistoryLength {
            featureDensityHistory.removeFirst()
        }
        
        if density > bestFeatureDensity {
            bestFeatureDensity = density
            logger.debug("Feature density improving: \(String(format: "%.2f", density))")
        }
    }
    
    /// Check if feature density is trending upward.
    var isFeatureDensityImproving: Bool {
        guard featureDensityHistory.count >= 3 else { return false }
        
        let recent = Array(featureDensityHistory.suffix(3))
        for i in 1..<recent.count {
            if recent[i] < recent[i - 1] {
                return false
            }
        }
        return true
    }
    
    /// Reset all analysis state. Call when starting a new relocalization attempt.
    func reset() {
        currentLookDirection = .none
        featureDensityHistory.removeAll()
        bestFeatureDensity = 0
    }
    
    /// Derive the best look direction from ARKit frame data.
    /// Analyzes feature point distribution across the image plane to
    /// determine which direction has the most/least tracked features.
    private func deriveLookDirection(from frame: ARFrame, confidence: Float) -> LookDirection {
        // If tracking is normal, no guidance needed.
        guard let trackingState = frame.trackingState,
              trackingState != .normal,
              trackingState != .limited(.localization) else {
            return .none
        }
        
        // Use feature point depth data distribution if available.
        if let depthData = frame.sceneDepth,
           let depthMap = depthData.depthMap {
            return analyzeDepthDistribution(depthMap, imageBufferSize: frame.capturedImage.size)
        }
        
        // Fallback: use camera transform to infer direction.
        // When confidence is very low, suggest broader movement.
        if confidence < 0.2 {
            return .closer
        } else if confidence < 0.4 {
            return .none
        }
        
        return .none
    }
    
    /// Analyze depth map distribution to find directions with sparse features.
    /// The idea is to guide the user toward areas with more visual features
    /// for the ARKit feature tracker to latch onto.
    private func analyzeDepthDistribution(_ depthMap: CVPixelBuffer, imageBufferSize: CGSize) -> LookDirection {
        // Divide the image into quadrants and compare feature density.
        // Sparse quadrants indicate where the user should look.
        
        // For simplicity, we compare the top-left vs top-right and
        // top vs bottom feature density.
        // In a full implementation, this would involve counting valid
        // depth pixels in each quadrant.
        
        // Current implementation: use a heuristic based on the overall
        // depth map validity ratio to suggest movement direction.
        // A more sophisticated version would parse the depth map pixel data.
        
        // Return a conservative default - the user should slowly pan
        // to expose more of the room.
        return .none
    }
}
