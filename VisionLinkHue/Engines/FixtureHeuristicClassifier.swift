import Vision
import Foundation

// MARK: - Observation Data

/// Sendable observation data extracted from VNRectangleObservation for cross-queue classification.
struct ObservationData: Sendable {
    let boundingBox: CGRect
}

// MARK: - Scoring Rules

/// A single declarative scoring rule that assigns points to a fixture type
/// when an observation matches the rule's aspect ratio, vertical position,
/// and area ranges.
struct ScoringRule: Sendable {
    /// The fixture type this rule scores.
    let type: FixtureType
    
    /// Aspect ratio range that triggers this rule. `nil` matches any aspect ratio.
    let aspectRange: ClosedRange<Double>?
    
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
        static let mediumAreaRange: ClosedRange<Double> = 0.05...0.1499
        static let smallAreaRange: ClosedRange<Double> = 0.0...0.0499
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

/// JSON-serializable representation of a scoring rule for config file loading.
struct JSONScoringRule: Sendable, Codable {
    let type: String
    let aspectRange: [Double]?
    let yRange: [Double]?
    let areaRange: [Double]?
    let weight: Double
}

/// JSON-serializable configuration for heuristic classification.
struct ClassificationConfigFile: Codable {
    let version: String?
    let description: String?
    let config: ConfigSection?
    let rules: [JSONScoringRule]
    
    struct ConfigSection: Codable {
        let specificity: [String: Int]?
        let materialFixtureMapping: [String: [String]]?
    }
}

// MARK: - Default Classification Rules

/// Declarative scoring rules for fixture classification.
/// Organized by aspect ratio category, then vertical position, then area.
/// The classifier iterates these rules to compute scores for each fixture type.
///
/// These are the bundled default rules. For OTA-updatable rules, use
/// `FixtureHeuristicClassifier.loadRules(from:)` to load from a JSON config.
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
///
/// Supports OTA-updatable rules via `loadRules(from:)` which loads scoring
/// rules from a JSON config file, enabling detection logic updates without
/// recompiling the binary.
struct FixtureHeuristicClassifier {
    
    /// Currently active classification rules. Defaults to the bundled
    /// `classificationRules` array. Replace with `loadRules(from:)` for
    /// OTA-updatable rules.
    private var rules: [ScoringRule]
    
    /// Specificity tiebreaker values.
    private var specificity: [FixtureType: Int]
    
    /// Default initializer using bundled classification rules.
    init() {
        self.rules = classificationRules
        self.specificity = ScoringConfig.Specificity.values
    }
    
    /// Load classification rules from a JSON config file.
    /// This enables OTA updates to detection logic without recompiling.
    /// Uses Swift 6.2 Resource trait for bundled resource access.
    /// - Parameter url: URL pointing to the JSON config file.
    /// - Returns: The loaded rules array.
    /// - Throws: `ClassificationConfigError` if the config is invalid or cannot be loaded.
    mutating func loadRules(from url: URL) throws {
        let data = try Data(contentsOf: url)
        
        let decoder = JSONDecoder()
        
        let configFile = try decoder.decode(ClassificationConfigFile.self, from: data)
        
        var loadedRules: [ScoringRule] = []
        for jsonRule in configFile.rules {
            guard let type = FixtureType(from: jsonRule.type) else { continue }
            
            let aspectRange = jsonRule.aspectRange.map {
                ClosedRange<Double>(uncheckedBounds: ($0[0], $0[1]))
            }
            
            let yRange = jsonRule.yRange.map {
                ClosedRange<Double>(uncheckedBounds: ($0[0], $0[1]))
            }
            
            let areaRange = jsonRule.areaRange.map {
                ClosedRange<Double>(uncheckedBounds: ($0[0], $0[1]))
            }
            
            loadedRules.append(ScoringRule(
                type: type,
                aspectRange: aspectRange,
                yRange: yRange,
                areaRange: areaRange,
                weight: jsonRule.weight
            ))
        }
        
        // Load specificity from config if available
        if let specificityConfig = configFile.config?.specificity {
            var loadedSpecificity: [FixtureType: Int] = [:]
            for (typeName, value) in specificityConfig {
                if let type = FixtureType(from: typeName) {
                    loadedSpecificity[type] = value
                }
            }
            self.specificity = loadedSpecificity
        }
        
        self.rules = loadedRules
    }
    
    /// Reset to the bundled default classification rules.
    mutating func resetToDefaults() {
        self.rules = classificationRules
        self.specificity = ScoringConfig.Specificity.values
    }
    
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
        
        // Iterate declarative rules and accumulate weights.
        for rule in rules {
            var matches = true
            
            if let aspectRange = rule.aspectRange {
                guard aspectRange.contains(aspectRatio) else { matches = false; continue }
            }
            
            if matches, let yRange = rule.yRange {
                guard yRange.contains(normalizedY) else { matches = false; continue }
            }
            
            if matches, let areaRange = rule.areaRange {
                guard areaRange.contains(area) else { matches = false; continue }
            }
            
            if matches {
                scores[rule.type]! += rule.weight
            }
        }
        
        // Sort by score descending, then by specificity as tiebreaker.
        let sorted = scores.sorted { a, b in
            if a.value == b.value {
                return specificity[a.key, default: 0] > specificity[b.key, default: 0]
            }
            return a.value > b.value
        }
        
        return sorted.first?.key ?? .lamp
    }
    
    /// Classify observation data into a fixture type using weighted scoring.
    func classify(typeFrom data: ObservationData) -> FixtureType {
        let aspectRatio = data.boundingBox.width / max(data.boundingBox.height, 0.001)
        let normalizedY = data.boundingBox.midY
        let area = data.boundingBox.width * data.boundingBox.height
        
        var scores: [FixtureType: Double] = [:]
        for fixture in FixtureType.allCases {
            scores[fixture] = 0.0
        }
        
        for rule in rules {
            var matches = true
            
            if let aspectRange = rule.aspectRange {
                guard aspectRange.contains(aspectRatio) else { matches = false; continue }
            }
            
            if matches, let yRange = rule.yRange {
                guard yRange.contains(normalizedY) else { matches = false; continue }
            }
            
            if matches, let areaRange = rule.areaRange {
                guard areaRange.contains(area) else { matches = false; continue }
            }
            
            if matches {
                scores[rule.type]! += rule.weight
            }
        }
        
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
    
    /// Calculate detection confidence from observation data.
    func calculateConfidence(from data: ObservationData) -> Double {
        var confidence: Double = 0.7
        
        let area = data.boundingBox.width * data.boundingBox.height
        if area > 0.01 && area < 0.5 {
            confidence += 0.15
        }
        if area > 0.05 && area < 0.3 {
            confidence += 0.05
        }
        
        let centerX = data.boundingBox.midX
        let centerY = data.boundingBox.midY
        let distanceFromCenter = sqrt(
            pow(centerX - 0.5, 2) + pow(centerY - 0.5, 2)
        )
        if distanceFromCenter < 0.3 {
            confidence += 0.05
        }
        
        return min(confidence, 0.99)
    }
}

// MARK: - FixtureType JSON Initialization

extension FixtureType {
    /// Initialize a fixture type from a JSON string name.
    /// Used for loading rules from JSON config files.
    init?(from jsonName: String) {
        switch jsonName.lowercased() {
        case "lamp": self = .lamp
        case "recessed": self = .recessed
        case "pendant": self = .pendant
        case "ceiling": self = .ceiling
        case "strip": self = .strip
        default: return nil
        }
    }
}

// MARK: - Classification Config Errors

/// Errors that can occur when loading classification config.
enum ClassificationConfigError: Error, LocalizedError {
    case invalidJSON
    case unknownFixtureType(String)
    case invalidRange(String)
    case fileNotFound(URL)
    
    var errorDescription: String? {
        switch self {
        case .invalidJSON: return "Invalid JSON in classification config"
        case .unknownFixtureType(let type): return "Unknown fixture type in config: \(type)"
        case .invalidRange(let desc): return "Invalid range in config: \(desc)"
        case .fileNotFound(let url): return "Config file not found: \(url.path)"
        }
    }
}

