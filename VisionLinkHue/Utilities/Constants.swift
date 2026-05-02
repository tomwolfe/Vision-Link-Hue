import Foundation

/// Centralized constants for the detection pipeline.
enum DetectionConstants {
    
    /// Time between inference passes in seconds (500ms to avoid ANE backpressure).
    public static let inferenceInterval: TimeInterval = 0.5
    
    /// Minimum confidence threshold for returning detections.
    public static let minConfidence: Double = 0.6
}
