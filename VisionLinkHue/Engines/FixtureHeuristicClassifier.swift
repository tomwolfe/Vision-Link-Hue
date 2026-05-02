import Vision
import Foundation

// MARK: - Scoring Rules

/// A single declarative scoring rule that assigns points to a fixture type
/// when an observation matches the rule's aspect ratio, vertical position,
/// and area ranges.
struct ScoringRule: Sendable {
    /// The fixture type this rule scores.
    let type: FixtureType
    
    /// Aspect ratio range that triggers this rule. `nil` matches any aspect ratio.
    let aspectRange: ClosedRange<Float>?
    
    /// Normalized Y position range (0=top, 1=bottom) that triggers this rule.
    /// `nil` matches any vertical position.
    let yRange: ClosedRange<Double>?
    
    /// Bounding box area range that triggers this rule. `nil` matches any area.
    let areaRange: ClosedRange<Double>?
    
    /// Weight to add to the fixture type's score when all active ranges match.
    let weight: Double
}

/// Configuration presets for heuristic fixture classification scoring.
struct ScoringConfig {
    
    // MARK: - Aspect Ratio Ranges
    
    struct AspectRatio {
        static let squareRange = 0.2...0.8
        static let moderateRange = 0.5...1.5
        static let wideRange = 1.2...3.0
        static let stripRange = 2.0...8.0
    }
    
    // MARK: - Vertical Position Ranges
    
    struct VerticalPosition {
        static let ceilingRange = 0.0...0.25
        static let midCeilingRange = 0.25...0.5
        static let midRange = 0.5...0.75
    }
    
    // MARK: - Area Ranges
    
    struct Area {
        static let largeThreshold: Double = 0.15
        static let mediumThreshold: Double = 0.05
        static let largeAreaRange: ClosedRange<Double> = 0.15...Double.infinity
        static let mediumAreaRange: ClosedRange<Double> = 0.05..<0.15
        static let smallAreaRange: ClosedRange<Double> = 0.0..<0.05
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

/// Declarative scoring rules for fixture classification.
/// Organized by aspect ratio category, then vertical position, then area.
/// The classifier iterates these rules to compute scores for each fixture type.
let classificationRules: [ScoringRule] = [
    // Square aspect ratio (0.2-0.8)
    ScoringRule(type: .ceiling, aspectRange: ScoringConfig.AspectRatio.squareRange, yRange: nil, areaRange: nil, weight: 3.0),
    ScoringRule(type: .recessed, aspectRange: ScoringConfig.AspectRatio.squareRange, yRange: nil, areaRange: nil, weight: 2.5),
    ScoringRule(type: .pendant, aspectRange: ScoringConfig.AspectRatio.squareRange, yRange: nil, areaRange: nil, weight: 1.0),
    
    // Moderate aspect ratio (0.5-1.5)
    ScoringRule(type: .pendant, aspectRange: ScoringConfig.AspectRatio.moderateRange, yRange: nil, areaRange: nil, weight: 3.0),
    ScoringRule(type: .lamp, aspectRange: ScoringConfig.AspectRatio.moderateRange, yRange: nil, areaRange: nil, weight: 2.5),
    ScoringRule(type: .ceiling, aspectRange: ScoringConfig.AspectRatio.moderateRange, yRange: nil, areaRange: nil, weight: 1.0),
    
    // Wide aspect ratio (1.2-3.0)
    ScoringRule(type: .lamp, aspectRange: ScoringConfig.AspectRatio.wideRange, yRange: nil, areaRange: nil, weight: 2.0),
    ScoringRule(type: .pendant, aspectRange: ScoringConfig.AspectRatio.wideRange, yRange: nil, areaRange: nil, weight: 1.5),
    
    // Strip aspect ratio (2.0-8.0)
    ScoringRule(type: .strip, aspectRange: ScoringConfig.AspectRatio.stripRange, yRange: nil, areaRange: nil, weight: 4.0),
    ScoringRule(type: .lamp, aspectRange: ScoringConfig.AspectRatio.stripRange, yRange: nil, areaRange: nil, weight: 0.5),
    
    // Default lamp weight for unmatched aspect ratios
    ScoringRule(type: .lamp, aspectRange: nil, yRange: nil, areaRange: nil, weight: 1.0),
    
    // Vertical position: ceiling (top of frame, 0.0-0.25)
    ScoringRule(type: .ceiling, aspectRange: nil, yRange: ScoringConfig.VerticalPosition.ceilingRange, areaRange: nil, weight: 3.0),
    ScoringRule(type: .pendant, aspectRange: nil, yRange: ScoringConfig.VerticalPosition.ceilingRange, areaRange: nil, weight: 2.0),
    ScoringRule(type: .recessed, aspectRange: nil, yRange: ScoringConfig.VerticalPosition.ceilingRange, areaRange: nil, weight: 1.5),
    
    // Vertical position: mid-ceiling (0.25-0.5)
    ScoringRule(type: .pendant, aspectRange: nil, yRange: ScoringConfig.VerticalPosition.midCeilingRange, areaRange: nil, weight: 2.0),
    ScoringRule(type: .recessed, aspectRange: nil, yRange: ScoringConfig.VerticalPosition.midCeilingRange, areaRange: nil, weight: 2.0),
    ScoringRule(type: .lamp, aspectRange: nil, yRange: ScoringConfig.VerticalPosition.midCeilingRange, areaRange: nil, weight: 1.0),
    
    // Vertical position: mid (0.5-0.75)
    ScoringRule(type: .lamp, aspectRange: nil, yRange: ScoringConfig.VerticalPosition.midRange, areaRange: nil, weight: 2.5),
    ScoringRule(type: .recessed, aspectRange: nil, yRange: ScoringConfig.VerticalPosition.midRange, areaRange: nil, weight: 2.0),
    ScoringRule(type: .strip, aspectRange: nil, yRange: ScoringConfig.VerticalPosition.midRange, areaRange: nil, weight: 0.5),
    
    // Default weights for bottom-of-frame (y > 0.75)
    ScoringRule(type: .lamp, aspectRange: nil, yRange: 0.75...1.0, areaRange: nil, weight: 3.0),
    ScoringRule(type: .strip, aspectRange: nil, yRange: 0.75...1.0, areaRange: nil, weight: 1.5),
    
    // Area: large (> 0.15)
    ScoringRule(type: .ceiling, aspectRange: nil, yRange: nil, areaRange: ScoringConfig.Area.largeAreaRange, weight: 1.5),
    ScoringRule(type: .strip, aspectRange: nil, yRange: nil, areaRange: ScoringConfig.Area.largeAreaRange, weight: 1.0),
    
    // Area: medium (0.05-0.15)
    ScoringRule(type: .pendant, aspectRange: nil, yRange: nil, areaRange: ScoringConfig.Area.mediumAreaRange, weight: 1.0),
    ScoringRule(type: .lamp, aspectRange: nil, yRange: nil, areaRange: ScoringConfig.Area.mediumAreaRange, weight: 1.0),
    ScoringRule(type: .recessed, aspectRange: nil, yRange: nil, areaRange: ScoringConfig.Area.mediumAreaRange, weight: 1.0),
    
    // Area: small (< 0.05)
    ScoringRule(type: .recessed, aspectRange: nil, yRange: nil, areaRange: ScoringConfig.Area.smallAreaRange, weight: 1.5),
    ScoringRule(type: .lamp, aspectRange: nil, yRange: nil, areaRange: ScoringConfig.Area.smallAreaRange, weight: 0.5),
]

// MARK: - Classifier

/// Heuristic classifier that determines lighting fixture type and detection
/// confidence from Vision framework rectangle observations.
///
/// Uses a declarative array of `ScoringRule` instances to compute weighted
/// scores for each fixture type based on aspect ratio, vertical position,
/// and bounding box area. This reduces cyclomatic complexity compared to
/// nested if/else chains and makes the scoring logic easily extensible.
struct FixtureHeuristicClassifier {
    
    /// Classify a rectangle observation into a fixture type using weighted
    /// scoring across aspect ratio, vertical position, and bounding box area.
    ///
    /// Iterates the global `classificationRules` array, accumulating weights
    /// for each fixture type whose rule ranges match the observation's
    /// aspect ratio, normalized Y position, and area. The type with the
    /// highest total weight wins, with specificity as a tiebreaker.
    func classify(typeFrom observation: VNRectangleObservation) -> FixtureType {
        let aspectRatio = observation.boundingBox.width / max(observation.boundingBox.height, 0.001)
        let normalizedY = observation.boundingBox.midY
        let area = observation.boundingBox.width * observation.boundingBox.height
        
        var scores: [FixtureType: Double] = [:]
        for fixture in FixtureType.allCases {
            scores[fixture] = 0.0
        }
        
        // Iterate declarative rules and accumulate weights.
        for rule in classificationRules {
            var matches = true
            
            if let aspectRange = rule.aspectRange {
                guard aspectRange.contains(aspectRatio) else { matches = false }
            }
            
            if matches, let yRange = rule.yRange {
                guard yRange.contains(normalizedY) else { matches = false }
            }
            
            if matches, let areaRange = rule.areaRange {
                guard areaRange.contains(area) else { matches = false }
            }
            
            if matches {
                scores[rule.type]! += rule.weight
            }
        }
        
        // Sort by score descending, then by specificity as tiebreaker.
        let sorted = scores.sorted { a, b in
            if a.value == b.value {
                return ScoringConfig.Specificity.values[a.key, default: 0] > ScoringConfig.Specificity.values[b.key, default: 0]
            }
            return a.value > b.value
        }
        
        return sorted.first?.key ?? .lamp
    }
    
    /// Calculate detection confidence from observation quality metrics.
    ///
    /// Base confidence is 0.7. Bonuses are added for:
    /// - Reasonable area (0.01-0.5): +0.15
    /// - Good area (0.05-0.3): +0.05
    /// - Near image center: +0.05
    ///
    /// Result is capped at 0.99.
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
