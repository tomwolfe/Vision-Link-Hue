import Vision
import Foundation

/// Configuration presets for heuristic fixture classification scoring.
struct ScoringConfig {
    
    // MARK: - Aspect Ratio Scoring
    
    struct AspectRatio {
        static let squareRange = 0.2...0.8
        static let squareCeilingWeight: Double = 3.0
        static let squareRecessedWeight: Double = 2.5
        static let squarePendantWeight: Double = 1.0
        
        static let moderateRange = 0.5...1.5
        static let moderatePendantWeight: Double = 3.0
        static let moderateLampWeight: Double = 2.5
        static let moderateCeilingWeight: Double = 1.0
        
        static let wideRange = 1.2...3.0
        static let wideLampWeight: Double = 2.0
        static let widePendantWeight: Double = 1.5
        
        static let stripRange = 2.0...8.0
        static let stripWeight: Double = 4.0
        static let stripLampWeight: Double = 0.5
        
        static let defaultLampWeight: Double = 1.0
    }
    
    // MARK: - Vertical Position Scoring
    
    struct VerticalPosition {
        static let ceilingRangeEnd: Double = 0.25
        static let ceilingCeilingWeight: Double = 3.0
        static let ceilingPendantWeight: Double = 2.0
        static let ceilingRecessedWeight: Double = 1.5
        
        static let midCeilingRangeEnd: Double = 0.5
        static let midCeilingPendantWeight: Double = 2.0
        static let midCeilingRecessedWeight: Double = 2.0
        static let midCeilingLampWeight: Double = 1.0
        
        static let midRangeEnd: Double = 0.75
        static let midLampWeight: Double = 2.5
        static let midRecessedWeight: Double = 2.0
        static let midStripWeight: Double = 0.5
        
        static let defaultLampWeight: Double = 3.0
        static let defaultStripWeight: Double = 1.5
    }
    
    // MARK: - Area Scoring
    
    struct Area {
        static let largeThreshold: Double = 0.15
        static let largeCeilingWeight: Double = 1.5
        static let largeStripWeight: Double = 1.0
        
        static let mediumThreshold: Double = 0.05
        static let mediumPendantWeight: Double = 1.0
        static let mediumLampWeight: Double = 1.0
        static let mediumRecessedWeight: Double = 1.0
        
        static let smallRecessedWeight: Double = 1.5
        static let smallLampWeight: Double = 0.5
    }
    
    // MARK: - Specificity Tiebreaker
    
    struct Specificity {
        static let values: [FixtureType: Int] = [
            .ceiling: 4,
            .recessed: 3,
            .pendant: 2,
            .strip: 1,
            .lamp: 0
        ]
    }
}

/// Heuristic classifier that determines lighting fixture type and detection
/// confidence from Vision framework rectangle observations.
///
/// Extracted from DetectionEngine to reduce cyclomatic complexity and enable
/// isolated unit testing of classification boundaries.
struct FixtureHeuristicClassifier {
    
    /// Classify a rectangle observation into a fixture type using weighted
    /// scoring across aspect ratio, vertical position, and bounding box area.
    func classify(typeFrom observation: VNRectangleObservation) -> FixtureType {
        let aspectRatio = observation.boundingBox.width / max(observation.boundingBox.height, 0.001)
        let normalizedY = observation.boundingBox.midY
        let area = observation.boundingBox.width * observation.boundingBox.height
        
        var scores: [FixtureType: Double] = [:]
        
        for fixture in FixtureType.allCases {
            scores[fixture] = 0.0
        }
        
        switch aspectRatio {
        case ScoringConfig.AspectRatio.squareRange:
            scores[.ceiling]! += ScoringConfig.AspectRatio.squareCeilingWeight
            scores[.recessed]! += ScoringConfig.AspectRatio.squareRecessedWeight
            scores[.pendant]! += ScoringConfig.AspectRatio.squarePendantWeight
        case ScoringConfig.AspectRatio.moderateRange:
            scores[.pendant]! += ScoringConfig.AspectRatio.moderatePendantWeight
            scores[.lamp]! += ScoringConfig.AspectRatio.moderateLampWeight
            scores[.ceiling]! += ScoringConfig.AspectRatio.moderateCeilingWeight
        case ScoringConfig.AspectRatio.wideRange:
            scores[.lamp]! += ScoringConfig.AspectRatio.wideLampWeight
            scores[.pendant]! += ScoringConfig.AspectRatio.widePendantWeight
        case ScoringConfig.AspectRatio.stripRange:
            scores[.strip]! += ScoringConfig.AspectRatio.stripWeight
            scores[.lamp]! += ScoringConfig.AspectRatio.stripLampWeight
        default:
            scores[.lamp]! += ScoringConfig.AspectRatio.defaultLampWeight
        }
        
        if normalizedY < ScoringConfig.VerticalPosition.ceilingRangeEnd {
            scores[.ceiling]! += ScoringConfig.VerticalPosition.ceilingCeilingWeight
            scores[.pendant]! += ScoringConfig.VerticalPosition.ceilingPendantWeight
            scores[.recessed]! += ScoringConfig.VerticalPosition.ceilingRecessedWeight
        } else if normalizedY < ScoringConfig.VerticalPosition.midCeilingRangeEnd {
            scores[.pendant]! += ScoringConfig.VerticalPosition.midCeilingPendantWeight
            scores[.recessed]! += ScoringConfig.VerticalPosition.midCeilingRecessedWeight
            scores[.lamp]! += ScoringConfig.VerticalPosition.midCeilingLampWeight
        } else if normalizedY < ScoringConfig.VerticalPosition.midRangeEnd {
            scores[.lamp]! += ScoringConfig.VerticalPosition.midLampWeight
            scores[.recessed]! += ScoringConfig.VerticalPosition.midRecessedWeight
            scores[.strip]! += ScoringConfig.VerticalPosition.midStripWeight
        } else {
            scores[.lamp]! += ScoringConfig.VerticalPosition.defaultLampWeight
            scores[.strip]! += ScoringConfig.VerticalPosition.defaultStripWeight
        }
        
        if area > ScoringConfig.Area.largeThreshold {
            scores[.ceiling]! += ScoringConfig.Area.largeCeilingWeight
            scores[.strip]! += ScoringConfig.Area.largeStripWeight
        } else if area > ScoringConfig.Area.mediumThreshold {
            scores[.pendant]! += ScoringConfig.Area.mediumPendantWeight
            scores[.lamp]! += ScoringConfig.Area.mediumLampWeight
            scores[.recessed]! += ScoringConfig.Area.mediumRecessedWeight
        } else {
            scores[.recessed]! += ScoringConfig.Area.smallRecessedWeight
            scores[.lamp]! += ScoringConfig.Area.smallLampWeight
        }
        
        let sorted = scores.sorted { a, b in
            if a.value == b.value {
                return ScoringConfig.Specificity.values[a.key, default: 0] > ScoringConfig.Specificity.values[b.key, default: 0]
            }
            return a.value > b.value
        }
        
        return sorted.first?.key ?? .lamp
    }
    
    /// Calculate detection confidence from observation quality metrics.
    func calculateConfidence(from observation: VNRectangleObservation) -> Double {
        var confidence: Double = 0.7
        
        let area = observation.boundingBox.width * observation.boundingBox.height
        if area > 0.01 && area < 0.5 {
            confidence += 0.15
        }
        if area > 0.05 && area < 0.3 {
            confidence += 0.05
        }
        
        let centerX = observation.boundingBox.midX
        let centerY = observation.boundingBox.midY
        let distanceFromCenter = sqrt(
            pow(centerX - 0.5, 2) + pow(centerY - 0.5, 2)
        )
        if distanceFromCenter < 0.3 {
            confidence += 0.05
        }
        
        return min(confidence, 0.99)
    }
}
