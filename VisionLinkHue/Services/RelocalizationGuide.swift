import ARKit
import simd
import Foundation
import os

/// Represents one of the four quadrants of the depth map.
enum DepthQuadrant: Int, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    
    /// Human-readable label for the quadrant.
    var label: String {
        switch self {
        case .topLeft: return "upper left"
        case .topRight: return "upper right"
        case .bottomLeft: return "lower left"
        case .bottomRight: return "lower right"
        }
    }
    
    /// The opposite quadrant for directional guidance.
    var opposite: DepthQuadrant {
        switch self {
        case .topLeft: return .bottomRight
        case .topRight: return .bottomLeft
        case .bottomLeft: return .topRight
        case .bottomRight: return .topLeft
        }
    }
}

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
    
    /// Minimum valid depth value in millimeters (filters out invalid pixels).
    private let minValidDepth: Int32 = 100
    
    /// Maximum valid depth value in millimeters (filters out far-away pixels).
    private let maxValidDepth: Int32 = 10000
    
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
    /// Divides the depth map into four quadrants and computes feature density
    /// (valid depth pixel ratio) for each. Uses Shannon entropy to measure
    /// distribution uniformity. When entropy is low (highly uneven), generates
    /// specific environmental guidance directing the user toward the quadrant
    /// with the most visual features.
    ///
    /// - Parameters:
    ///   - depthMap: The ARKit depth map CVPixelBuffer.
    ///   - imageBufferSize: The dimensions of the captured image.
    /// - Returns: A LookDirection with specific guidance, or .none if distribution
    ///   is already uniform or analysis fails.
    private func analyzeDepthDistribution(_ depthMap: CVPixelBuffer, imageBufferSize: CGSize) -> LookDirection {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return .none
        }
        
        // Divide image into quadrants for entropy analysis.
        let midX = width / 2
        let midY = height / 2
        
        // Count valid depth pixels in each quadrant.
        var quadrantCounts = [DepthQuadrant: Int]()
        for quadrant in [DepthQuadrant.topLeft, .topRight, .bottomLeft, .bottomRight] {
            quadrantCounts[quadrant] = 0
        }
        
        // Sample every 2nd pixel per quadrant for performance.
        let sampleStride = 2
        
        for y in stride(from: 0, to: height, by: sampleStride) {
            for x in stride(from: 0, to: width, by: sampleStride) {
                let byteOffset = y * bytesPerRow + x * 4
                let depthValue = Int32(baseAddress.load(fromByteOffset: byteOffset, as: Int32.self))
                
                // Check if depth value is valid and within range.
                guard depthValue >= minValidDepth, depthValue <= maxValidDepth else {
                    continue
                }
                
                // Determine which quadrant this pixel belongs to.
                let quadrant: DepthQuadrant
                if x < midX {
                    quadrant = y < midY ? .topLeft : .bottomLeft
                } else {
                    quadrant = y < midY ? .topRight : .bottomRight
                }
                
                quadrantCounts[quadrant] = (quadrantCounts[quadrant] ?? 0) + 1
            }
        }
        
        // Compute total samples per quadrant for density calculation.
        let samplesPerQuadrant = (width / sampleStride / 2) * (height / sampleStride / 2)
        
        // Convert counts to densities (0.0 to 1.0).
        var densities: [DepthQuadrant: Float] = [:]
        for (quadrant, count) in quadrantCounts {
            densities[quadrant] = Float(count) / Float(samplesPerQuadrant)
        }
        
        // Compute Shannon entropy of the quadrant distribution.
        let entropy = computeQuadrantEntropy(densities: densities)
        
        // Find the quadrant with the lowest feature density.
        guard let sparsestQuadrant = densities.min(by: { $0.value < $1.value })?.key else {
            return .none
        }
        
        // Find the quadrant with the highest feature density.
        guard let richestQuadrant = densities.max(by: { $0.value < $1.value })?.key else {
            return .none
        }
        
        // If entropy is high (distribution is uniform), return conservative guidance.
        // High entropy means all quadrants have similar feature density.
        let maxEntropy = Float(log(4.0)) // Maximum entropy for 4 quadrants
        if entropy > maxEntropy * 0.85 {
            return .none
        }
        
        // Determine the directional guidance based on the sparsest quadrant.
        // Guide the user to look toward the richest quadrant (opposite of sparsest).
        let guidance = environmentalGuidance(from: sparsestQuadrant, richest: richestQuadrant, densities: densities)
        
        // Validate that the guidance is meaningful (enough density difference).
        let densitySpread = densities[richestQuadrant]! - densities[sparsestQuadrant]!
        if densitySpread < 0.15 {
            // Not enough difference to give specific guidance.
            return .none
        }
        
        return guidance
    }
    
    /// Compute Shannon entropy of the quadrant feature density distribution.
    /// Returns a value between 0.0 (all features in one quadrant) and
    /// log(4.0) ~ 1.386 (features evenly distributed across all quadrants).
    ///
    /// - Parameter densities: Map of quadrant to feature density (0.0-1.0).
    /// - Returns: Shannon entropy in bits.
    private func computeQuadrantEntropy(densities: [DepthQuadrant: Float]) -> Float {
        let totalDensity = densities.values.reduce(0.0, +)
        
        // Normalize densities to form a probability distribution.
        guard totalDensity > 0 else {
            return 0.0
        }
        
        var entropy: Float = 0.0
        
        for density in densities.values {
            let probability = Float(density) / totalDensity
            
            // Skip zero probabilities (0 * log(0) = 0 by convention).
            guard probability > 0 else { continue }
            
            entropy -= probability * log(probability)
        }
        
        return entropy
    }
    
    /// Generate environmental guidance based on quadrant analysis.
    /// Maps the sparsest quadrant to a specific directional instruction
    /// with a descriptive label (e.g., "Look toward the window to improve tracking").
    ///
    /// - Parameters:
    ///   - sparsestQuadrant: The quadrant with the fewest visual features.
    ///   - richest: The quadrant with the most visual features.
    ///   - densities: Full density map for all quadrants.
    /// - Returns: A LookDirection.environmental with specific guidance text.
    private func environmentalGuidance(
        from sparsestQuadrant: DepthQuadrant,
        richest: DepthQuadrant,
        densities: [DepthQuadrant: Float]
    ) -> LookDirection {
        // Generate specific guidance based on which quadrant is sparsest.
        // The user should look toward the opposite (richest) quadrant.
        let instruction: String
        let icon: String
        
        switch sparsestQuadrant {
        case .topLeft:
            instruction = "Look toward the upper right to improve tracking"
            icon = "arrow.up.right.circle.fill"
        case .topRight:
            instruction = "Look toward the upper left to improve tracking"
            icon = "arrow.up.left.circle.fill"
        case .bottomLeft:
            instruction = "Look toward the lower right to improve tracking"
            icon = "arrow.down.right.circle.fill"
        case .bottomRight:
            instruction = "Look toward the lower left to improve tracking"
            icon = "arrow.down.left.circle.fill"
        }
        
        // Enhance the instruction with environmental context if there's
        // a strong directional bias (entropy is very low).
        let totalDensity = densities.values.reduce(0.0, +)
        let richestDensity = densities[richest] ?? 0
        let dominanceRatio = Float(richestDensity) / totalDensity
        
        if dominanceRatio > 0.45 {
            // Strong bias toward one quadrant - provide room context hint.
            let contextHint = environmentalContextHint(for: richest)
            instruction = "\(instruction) — \(contextHint)"
        }
        
        return .environmental(description: instruction, icon: icon)
    }
    
    /// Generate an environmental context hint based on the richest quadrant.
    /// Uses heuristic rules to suggest common room features that may be
    /// located in that direction (e.g., windows, walls with texture).
    ///
    /// - Parameter quadrant: The richest quadrant.
    /// - Returns: A descriptive context hint string.
    private func environmentalContextHint(for quadrant: DepthQuadrant) -> String {
        switch quadrant {
        case .topLeft, .topRight:
            return "Ceiling or upper walls often have the best tracking features"
        case .bottomLeft, .bottomRight:
            return "Floor-level objects provide strong visual features for tracking"
        }
    }
}
