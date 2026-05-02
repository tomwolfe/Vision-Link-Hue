import Vision
import Foundation

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
        case 0.2...0.8:
            scores[.ceiling]! += 3.0
            scores[.recessed]! += 2.5
            scores[.pendant]! += 1.0
        case 0.5...1.5:
            scores[.pendant]! += 3.0
            scores[.lamp]! += 2.5
            scores[.ceiling]! += 1.0
        case 1.2...3.0:
            scores[.lamp]! += 2.0
            scores[.pendant]! += 1.5
        case 2.0...8.0:
            scores[.strip]! += 4.0
            scores[.lamp]! += 0.5
        default:
            scores[.lamp]! += 1.0
        }
        
        if normalizedY < 0.25 {
            scores[.ceiling]! += 3.0
            scores[.pendant]! += 2.0
            scores[.recessed]! += 1.5
        } else if normalizedY < 0.5 {
            scores[.pendant]! += 2.0
            scores[.recessed]! += 2.0
            scores[.lamp]! += 1.0
        } else if normalizedY < 0.75 {
            scores[.lamp]! += 2.5
            scores[.recessed]! += 2.0
            scores[.strip]! += 0.5
        } else {
            scores[.lamp]! += 3.0
            scores[.strip]! += 1.5
        }
        
        if area > 0.15 {
            scores[.ceiling]! += 1.5
            scores[.strip]! += 1.0
        } else if area > 0.05 {
            scores[.pendant]! += 1.0
            scores[.lamp]! += 1.0
            scores[.recessed]! += 1.0
        } else {
            scores[.recessed]! += 1.5
            scores[.lamp]! += 0.5
        }
        
        let specificity: [FixtureType: Int] = [.ceiling: 4, .recessed: 3, .pendant: 2, .strip: 1, .lamp: 0]
        
        let sorted = scores.sorted { a, b in
            if a.value == b.value {
                return specificity[a.key, default: 0] > specificity[b.key, default: 0]
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
