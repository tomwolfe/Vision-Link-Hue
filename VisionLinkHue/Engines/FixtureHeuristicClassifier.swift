import Vision
import Foundation

// MARK: - Observation Data

/// Sendable observation data extracted from VNRectangleObservation for cross-queue classification.
struct ObservationData: Sendable {
    let boundingBox: CGRect
    
    /// Optional world-space height in meters above the floor. When available,
    /// the classifier uses physical height instead of 2D normalized Y position
    /// to avoid errors when the camera points straight up at ceiling fixtures.
    let worldSpaceHeightMeters: Float?
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
    
    /// Physical height range in meters above the floor that triggers this rule.
    /// Only used when `worldSpaceHeightMeters` is available on the observation.
    /// `nil` matches any physical height.
    let heightRange: ClosedRange<Double>?
    
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
    
    // MARK: - Physical Height Ranges (meters above floor)
    
    /// World-space height ranges for fixture classification.
    /// These ranges are used when `worldSpaceHeightMeters` is available,
    /// providing camera-angle-independent classification.
    struct Height {
        /// Ceiling-mounted fixtures: flush with or near the ceiling (2.4m+)
        static let ceilingRange = 2.1...Double.greatestFiniteMagnitude
        /// Pendant lights: hanging from ceiling at mid-height (0.9m-2.4m)
        static let pendantRange = 0.9...2.1
        /// Wall sconces: mounted on walls at eye level or above (1.5m-2.4m)
        static let sconceRange = 1.5...2.4
        /// Floor/table lamps: on the floor or a low surface (0.0...1.5m)
        static let lampRange = 0.0...1.5
        /// Desk lamps: on a desk surface (0.4...0.8m)
        static let deskLampRange = 0.4...0.8
        /// Recessed lights: flush with ceiling (2.4m+)
        static let recessedRange = 2.1...Double.greatestFiniteMagnitude
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
            .ceiling: 5,
            .recessed: 4,
            .pendant: 3,
            .chandelier: 4,
            .sconce: 3,
            .deskLamp: 2,
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
    let heightRange: [Double]?
    let weight: Double
}

/// Configuration version for classification rules.
/// Bumping this forces apps to reload rules, preventing breaking changes
/// from old config files being applied to new classifier logic.
private let classificationConfigVersion = "1.2.0"

/// JSON-serializable configuration for heuristic classification.
struct ClassificationConfigFile: Codable {
    let version: String?
    let description: String?
    let config: ConfigSection?
    let rules: [JSONScoringRule]
    
    struct ConfigSection: Codable {
        let specificity: [String: Int]?
        let materialFixtureMapping: [String: [String]]?
        let materialIndexMapping: [String: String]?
        let spatial: SpatialConfig?
    }
    
    struct SpatialConfig: Codable {
        let raycastProjectionConfidence: Double?
        let depthProjectionConfidence: Double?
        let meshResultConfidence: Double?
        let fallbackDistanceMeters: Float?
        let fallbackConfidence: Double?
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
    ScoringRule(type: .ceiling, aspectRange: ScoringConfig.AspectRatio.squareRange, yRange: nil, areaRange: nil, heightRange: nil, weight: 3.0),
    ScoringRule(type: .recessed, aspectRange: ScoringConfig.AspectRatio.squareRange, yRange: nil, areaRange: nil, heightRange: nil, weight: 2.5),
    ScoringRule(type: .pendant, aspectRange: ScoringConfig.AspectRatio.squareRange, yRange: nil, areaRange: nil, heightRange: nil, weight: 1.0),
    ScoringRule(type: .chandelier, aspectRange: ScoringConfig.AspectRatio.squareRange, yRange: nil, areaRange: nil, heightRange: nil, weight: 2.0),
    
    // Moderate aspect ratio (0.5-1.5)
    ScoringRule(type: .pendant, aspectRange: ScoringConfig.AspectRatio.moderateRange, yRange: nil, areaRange: nil, heightRange: nil, weight: 3.0),
    ScoringRule(type: .lamp, aspectRange: ScoringConfig.AspectRatio.moderateRange, yRange: nil, areaRange: nil, heightRange: nil, weight: 2.5),
    ScoringRule(type: .ceiling, aspectRange: ScoringConfig.AspectRatio.moderateRange, yRange: nil, areaRange: nil, heightRange: nil, weight: 1.0),
    ScoringRule(type: .deskLamp, aspectRange: ScoringConfig.AspectRatio.moderateRange, yRange: nil, areaRange: nil, heightRange: nil, weight: 2.0),
    
    // Wide aspect ratio (1.2-3.0)
    ScoringRule(type: .lamp, aspectRange: ScoringConfig.AspectRatio.wideRange, yRange: nil, areaRange: nil, heightRange: nil, weight: 2.0),
    ScoringRule(type: .pendant, aspectRange: ScoringConfig.AspectRatio.wideRange, yRange: nil, areaRange: nil, heightRange: nil, weight: 1.5),
    ScoringRule(type: .sconce, aspectRange: ScoringConfig.AspectRatio.wideRange, yRange: nil, areaRange: nil, heightRange: nil, weight: 1.5),
    
    // Strip aspect ratio (2.0-8.0)
    ScoringRule(type: .strip, aspectRange: ScoringConfig.AspectRatio.stripRange, yRange: nil, areaRange: nil, heightRange: nil, weight: 4.0),
    ScoringRule(type: .lamp, aspectRange: ScoringConfig.AspectRatio.stripRange, yRange: nil, areaRange: nil, heightRange: nil, weight: 0.5),
    
    // Default lamp weight for unmatched aspect ratios
    ScoringRule(type: .lamp, aspectRange: nil, yRange: nil, areaRange: nil, heightRange: nil, weight: 1.0),
    
    // Vertical position: ceiling (top of frame, 0.0-0.25)
    ScoringRule(type: .ceiling, aspectRange: nil, yRange: ScoringConfig.VerticalPosition.ceilingRange, areaRange: nil, heightRange: nil, weight: 3.0),
    ScoringRule(type: .pendant, aspectRange: nil, yRange: ScoringConfig.VerticalPosition.ceilingRange, areaRange: nil, heightRange: nil, weight: 2.0),
    ScoringRule(type: .recessed, aspectRange: nil, yRange: ScoringConfig.VerticalPosition.ceilingRange, areaRange: nil, heightRange: nil, weight: 1.5),
    ScoringRule(type: .chandelier, aspectRange: nil, yRange: ScoringConfig.VerticalPosition.ceilingRange, areaRange: nil, heightRange: nil, weight: 3.0),
    
    // Vertical position: mid-ceiling (0.25-0.5)
    ScoringRule(type: .pendant, aspectRange: nil, yRange: ScoringConfig.VerticalPosition.midCeilingRange, areaRange: nil, heightRange: nil, weight: 2.0),
    ScoringRule(type: .recessed, aspectRange: nil, yRange: ScoringConfig.VerticalPosition.midCeilingRange, areaRange: nil, heightRange: nil, weight: 2.0),
    ScoringRule(type: .lamp, aspectRange: nil, yRange: ScoringConfig.VerticalPosition.midCeilingRange, areaRange: nil, heightRange: nil, weight: 1.0),
    ScoringRule(type: .sconce, aspectRange: nil, yRange: ScoringConfig.VerticalPosition.midCeilingRange, areaRange: nil, heightRange: nil, weight: 2.5),
    
    // Vertical position: mid (0.5-0.75)
    ScoringRule(type: .lamp, aspectRange: nil, yRange: ScoringConfig.VerticalPosition.midRange, areaRange: nil, heightRange: nil, weight: 2.5),
    ScoringRule(type: .recessed, aspectRange: nil, yRange: ScoringConfig.VerticalPosition.midRange, areaRange: nil, heightRange: nil, weight: 2.0),
    ScoringRule(type: .strip, aspectRange: nil, yRange: ScoringConfig.VerticalPosition.midRange, areaRange: nil, heightRange: nil, weight: 0.5),
    ScoringRule(type: .deskLamp, aspectRange: nil, yRange: ScoringConfig.VerticalPosition.midRange, areaRange: nil, heightRange: nil, weight: 2.0),
    
    // Default weights for bottom-of-frame (y > 0.75)
    ScoringRule(type: .lamp, aspectRange: nil, yRange: 0.75...1.0, areaRange: nil, heightRange: nil, weight: 3.0),
    ScoringRule(type: .strip, aspectRange: nil, yRange: 0.75...1.0, areaRange: nil, heightRange: nil, weight: 1.5),
    ScoringRule(type: .deskLamp, aspectRange: nil, yRange: 0.75...1.0, areaRange: nil, heightRange: nil, weight: 2.5),
    
    // Area: large (> 0.15)
    ScoringRule(type: .ceiling, aspectRange: nil, yRange: nil, areaRange: ScoringConfig.Area.largeAreaRange, heightRange: nil, weight: 1.5),
    ScoringRule(type: .strip, aspectRange: nil, yRange: nil, areaRange: ScoringConfig.Area.largeAreaRange, heightRange: nil, weight: 1.0),
    ScoringRule(type: .chandelier, aspectRange: nil, yRange: nil, areaRange: ScoringConfig.Area.largeAreaRange, heightRange: nil, weight: 2.0),
    
    // Area: medium (0.05-0.15)
    ScoringRule(type: .pendant, aspectRange: nil, yRange: nil, areaRange: ScoringConfig.Area.mediumAreaRange, heightRange: nil, weight: 1.0),
    ScoringRule(type: .lamp, aspectRange: nil, yRange: nil, areaRange: ScoringConfig.Area.mediumAreaRange, heightRange: nil, weight: 1.0),
    ScoringRule(type: .recessed, aspectRange: nil, yRange: nil, areaRange: ScoringConfig.Area.mediumAreaRange, heightRange: nil, weight: 1.0),
    ScoringRule(type: .sconce, aspectRange: nil, yRange: nil, areaRange: ScoringConfig.Area.mediumAreaRange, heightRange: nil, weight: 1.5),
    
    // Area: small (< 0.05)
    ScoringRule(type: .recessed, aspectRange: nil, yRange: nil, areaRange: ScoringConfig.Area.smallAreaRange, heightRange: nil, weight: 1.5),
    ScoringRule(type: .lamp, aspectRange: nil, yRange: nil, areaRange: ScoringConfig.Area.smallAreaRange, heightRange: nil, weight: 0.5),
    ScoringRule(type: .sconce, aspectRange: nil, yRange: nil, areaRange: ScoringConfig.Area.smallAreaRange, heightRange: nil, weight: 1.0),
    
    // World-space height rules: ceiling fixtures (2.1m+) - camera-angle independent
    ScoringRule(type: .ceiling, aspectRange: nil, yRange: nil, areaRange: nil, heightRange: ScoringConfig.Height.ceilingRange, weight: 4.0),
    ScoringRule(type: .recessed, aspectRange: nil, yRange: nil, areaRange: nil, heightRange: ScoringConfig.Height.recessedRange, weight: 4.0),
    ScoringRule(type: .chandelier, aspectRange: nil, yRange: nil, areaRange: nil, heightRange: ScoringConfig.Height.ceilingRange, weight: 3.0),
    
    // World-space height rules: pendant lights (0.9m-2.1m)
    ScoringRule(type: .pendant, aspectRange: nil, yRange: nil, areaRange: nil, heightRange: ScoringConfig.Height.pendantRange, weight: 4.0),
    
    // World-space height rules: wall sconces (1.5m-2.4m)
    ScoringRule(type: .sconce, aspectRange: nil, yRange: nil, areaRange: nil, heightRange: ScoringConfig.Height.sconceRange, weight: 3.5),
    
    // World-space height rules: floor/table lamps (0.0m-1.5m)
    ScoringRule(type: .lamp, aspectRange: nil, yRange: nil, areaRange: nil, heightRange: ScoringConfig.Height.lampRange, weight: 3.5),
    ScoringRule(type: .deskLamp, aspectRange: nil, yRange: nil, areaRange: nil, heightRange: ScoringConfig.Height.deskLampRange, weight: 4.0),
]

/// Safely creates a `ClosedRange<Double>` from a two-element array,
/// handling inverted bounds (e.g., `[0.8, 0.2]`) by using min/max.
/// This prevents crashes from server-side JSON typos in OTA config.
/// - Parameter bounds: A two-element array of doubles.
/// - Returns: A `ClosedRange<Double>` with correctly ordered bounds, or `nil` if
///   the array doesn't have exactly 2 elements.
@inline(__always)
private func safeClosedRange(_ bounds: [Double]) -> ClosedRange<Double>? {
    guard bounds.count == 2 else { return nil }
    return ClosedRange(uncheckedBounds: (min(bounds[0], bounds[1]), max(bounds[0], bounds[1])))
}

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
    /// - Parameters:
    ///   - url: URL pointing to the JSON config file.
    ///   - signature: Optional ECDSA signature for verifying config authenticity.
    ///   - keyID: Optional key identifier for multi-key rotation support.
    /// - Returns: The loaded rules array.
    /// - Throws: `ClassificationConfigError` if the config is invalid or cannot be loaded.
    mutating func loadRules(from url: URL, signature: Data? = nil, keyID: String? = nil) async throws {
        let (data, response): (Data, URLResponse)
        
        if url.scheme == "http" || url.scheme == "https" {
            (data, response) = try await URLSession.shared.data(from: url)
        } else {
            data = try await Task.detached { try Data(contentsOf: url) }.value
        }
        
        if let signature {
            do {
                try ECDSASignatureValidator.verifySignature(payload: data, signature: signature, keyID: keyID)
            } catch {
                throw ClassificationConfigError.signatureInvalid(error.localizedDescription)
            }
        }
        
        let decoder = JSONDecoder()
        
        let configFile = try decoder.decode(ClassificationConfigFile.self, from: data)
        
        // Validate config version to prevent breaking changes from stale config files.
        if let configVersion = configFile.version,
           configVersion != classificationConfigVersion {
            throw ClassificationConfigError.versionMismatch(
                expected: classificationConfigVersion,
                actual: configVersion
            )
        }
        
        var loadedRules: [ScoringRule] = []
        for jsonRule in configFile.rules {
            guard let type = FixtureType(from: jsonRule.type) else { continue }
            
            let aspectRange = jsonRule.aspectRange.flatMap { safeClosedRange($0) }
            
            let yRange = jsonRule.yRange.flatMap { safeClosedRange($0) }
            
            let areaRange = jsonRule.areaRange.flatMap { safeClosedRange($0) }
            
            let heightRange = jsonRule.heightRange.flatMap { safeClosedRange($0) }
            
            loadedRules.append(ScoringRule(
                type: type,
                aspectRange: aspectRange,
                yRange: yRange,
                areaRange: areaRange,
                heightRange: heightRange,
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
        
        // Apply spatial/projection thresholds from config if available
        if let spatial = configFile.config?.spatial {
            let configData = DetectionConstants.SpatialConfigData(
                raycastProjectionConfidence: spatial.raycastProjectionConfidence ?? DetectionConstants.defaultRaycastProjectionConfidence,
                depthProjectionConfidence: spatial.depthProjectionConfidence ?? DetectionConstants.defaultDepthProjectionConfidence,
                meshResultConfidence: spatial.meshResultConfidence ?? DetectionConstants.defaultMeshResultConfidence,
                fallbackDistanceMeters: spatial.fallbackDistanceMeters ?? DetectionConstants.defaultFallbackDistanceMeters,
                fallbackConfidence: spatial.fallbackConfidence ?? DetectionConstants.defaultFallbackConfidence
            )
            DetectionConstants.setSpatialConfig(configData)
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
        
        return scoreObservation(aspectRatio: aspectRatio, normalizedY: normalizedY, area: area, worldSpaceHeightMeters: nil)
    }
    
    /// Classify observation data into a fixture type using weighted scoring.
    /// When `worldSpaceHeightMeters` is available, uses physical height instead
    /// of 2D normalized Y position for camera-angle-independent classification.
    func classify(typeFrom data: ObservationData) -> FixtureType {
        let aspectRatio = data.boundingBox.width / max(data.boundingBox.height, 0.001)
        let normalizedY = data.boundingBox.midY
        let area = data.boundingBox.width * data.boundingBox.height
        
        return scoreObservation(aspectRatio: aspectRatio, normalizedY: normalizedY, area: area, worldSpaceHeightMeters: data.worldSpaceHeightMeters)
    }
    
    /// Calculate detection confidence from observation quality metrics.
    func calculateConfidence(from observation: VNRectangleObservation) -> Double {
        let area = observation.boundingBox.width * observation.boundingBox.height
        let centerX = observation.boundingBox.midX
        let centerY = observation.boundingBox.midY
        
        return computeConfidence(area: area, centerX: centerX, centerY: centerY)
    }
    
    /// Calculate detection confidence from observation data.
    func calculateConfidence(from data: ObservationData) -> Double {
        let area = data.boundingBox.width * data.boundingBox.height
        let centerX = data.boundingBox.midX
        let centerY = data.boundingBox.midY
        
        return computeConfidence(area: area, centerX: centerX, centerY: centerY)
    }
    
    private func scoreObservation(aspectRatio: Double, normalizedY: Double, area: Double, worldSpaceHeightMeters: Float?) -> FixtureType {
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
            
            if matches, let heightRange = rule.heightRange {
                guard let worldHeight = worldSpaceHeightMeters,
                      heightRange.contains(Double(worldHeight)) else {
                    // If the rule specifies a height range but we don't have world-space height,
                    // skip this rule to avoid incorrect 2D-based scoring
                    matches = false; continue
                }
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
    
    private func computeConfidence(area: Double, centerX: Double, centerY: Double) -> Double {
        var confidence: Double = DetectionConstants.baseConfidence
        
        if area > DetectionConstants.areaBonusMediumLowerBound && area < DetectionConstants.areaBonusMediumUpperBound {
            confidence += DetectionConstants.areaBonusMedium
        } else if area > DetectionConstants.areaBonusLowerBound && area < DetectionConstants.areaBonusUpperBoundLarge {
            confidence += DetectionConstants.areaBonusWellSized
        }
        
        let distanceFromCenter = sqrt(
            pow(centerX - 0.5, 2) + pow(centerY - 0.5, 2)
        )
        if distanceFromCenter < DetectionConstants.centerProximityThreshold {
            confidence += DetectionConstants.proximityBonus
        }
        
        return min(confidence, DetectionConstants.maxConfidence)
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
        case "chandelier": self = .chandelier
        case "sconce": self = .sconce
        case "desklamp": self = .deskLamp
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
    case versionMismatch(expected: String, actual: String)
    case signatureInvalid(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidJSON: return "Invalid JSON in classification config"
        case .unknownFixtureType(let type): return "Unknown fixture type in config: \(type)"
        case .invalidRange(let desc): return "Invalid range in config: \(desc)"
        case .fileNotFound(let url): return "Config file not found: \(url.path)"
        case .versionMismatch(let expected, let actual):
            return "Classification config version mismatch: expected \(expected), got \(actual)"
        case .signatureInvalid(let reason):
            return "Configuration signature invalid: \(reason)"
        }
    }
}

