import Foundation

/// Centralized constants for the detection pipeline.
enum DetectionConstants {
    
    /// Time between inference passes in seconds (500ms to avoid ANE backpressure).
    public static let inferenceInterval: TimeInterval = 0.5
    
    /// Minimum confidence threshold for returning detections.
    public static let minConfidence: Double = 0.6
    
    // MARK: - Vision Detection
    
    /// Minimum confidence for VNRectangleObservation results.
    public static let rectangleMinimumConfidence: Float = 0.2
    
    /// Maximum normalized Y position for valid detections (filters out bottom-of-frame).
    public static let maxDetectionY: Double = 0.8
    
    /// Minimum bounding box width/height as fraction of frame (filters tiny detections).
    public static let minBoundingBoxSize: Double = 0.05
    
    /// IoU threshold for non-maximum suppression.
    public static let nmsIoUThreshold: Float = 0.3
    
    // MARK: - Confidence Scoring
    
    /// Base confidence value for any detection.
    public static let baseConfidence: Double = 0.7
    
    /// Area-based confidence bonus for well-sized objects.
    public static let areaBonusWellSized: Double = 0.15
    
    /// Secondary area-based confidence bonus for medium objects.
    public static let areaBonusMedium: Double = 0.15
    
    /// Area lower bound for well-sized bonus (0.01).
    public static let areaBonusLowerBound: Double = 0.01
    
    /// Area upper bound for well-sized bonus (0.5).
    public static let areaBonusUpperBoundLarge: Double = 0.5
    
    /// Area lower bound for medium bonus (0.05).
    public static let areaBonusMediumLowerBound: Double = 0.05
    
    /// Area upper bound for medium bonus (0.3).
    public static let areaBonusMediumUpperBound: Double = 0.3
    
    /// Maximum distance from center for proximity bonus.
    public static let centerProximityThreshold: Double = 0.3
    
    /// Proximity bonus for objects near frame center.
    public static let proximityBonus: Double = 0.05
    
    /// Maximum confidence cap.
    public static let maxConfidence: Double = 0.99
    
    // MARK: - Spatial
    
    /// Singularity threshold for lookAt quaternion computation.
    public static let singularityThreshold: Float = 1e-6
    
    // MARK: - Persistence Validation
    
    /// Maximum acceptable quaternion norm deviation from 1.0.
    public static let maxQuaternionNormDelta: Float = 0.01
    
    /// Maximum valid fixture distance in meters.
    public static let maxDistanceMeters: Float = 100
    
    /// Maximum valid position magnitude from origin in meters.
    public static let maxPositionMagnitude: Float = 1000
}
