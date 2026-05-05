import Foundation
import os

/// Monitors and reports the success rates of ARWorldMap vs ObjectAnchor
/// relocalization methods to guide production decisions on whether to
/// lean entirely into Extended Relocalization Mode (Object Anchors).
///
/// iOS 26 prefers `ARObjectAnchor` over `ARWorldMap` for persistent
/// relocalization. This service tracks which method succeeds more often
/// and provides metrics to inform the migration decision.
@MainActor
final class RelocalizationMonitoringService {
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "RelocalizationMonitoring"
    )
    
    // MARK: - Metrics
    
    /// Total number of ARWorldMap relocalization attempts.
    var worldMapAttempts: Int = 0
    
    /// Successful ARWorldMap relocalization count.
    var worldMapSuccesses: Int = 0
    
    /// Total number of ObjectAnchor relocalization attempts.
    var objectAnchorAttempts: Int = 0
    
    /// Successful ObjectAnchor relocalization count.
    var objectAnchorSuccesses: Int = 0
    
    /// Total time spent in ARWorldMap relocalization (seconds).
    var worldMapTotalTime: TimeInterval = 0.0
    
    /// Total time spent in ObjectAnchor relocalization (seconds).
    var objectAnchorTotalTime: TimeInterval = 0.0
    
    // MARK: - Computed Metrics
    
    /// ARWorldMap success rate as a percentage (0.0 - 1.0).
    var worldMapSuccessRate: Double {
        guard worldMapAttempts > 0 else { return 0.0 }
        return Double(worldMapSuccesses) / Double(worldMapAttempts)
    }
    
    /// ObjectAnchor success rate as a percentage (0.0 - 1.0).
    var objectAnchorSuccessRate: Double {
        guard objectAnchorAttempts > 0 else { return 0.0 }
        return Double(objectAnchorSuccesses) / Double(objectAnchorAttempts)
    }
    
    /// Average ARWorldMap relocalization time in seconds.
    var worldMapAverageTime: Double {
        guard worldMapSuccesses > 0 else { return 0.0 }
        return worldMapTotalTime / Double(worldMapSuccesses)
    }
    
    /// Average ObjectAnchor relocalization time in seconds.
    var objectAnchorAverageTime: Double {
        guard objectAnchorSuccesses > 0 else { return 0.0 }
        return objectAnchorTotalTime / Double(objectAnchorSuccesses)
    }
    
    /// Whether ObjectAnchor has a statistically better success rate.
    /// Returns true when ObjectAnchor has more than 10% higher success
    /// rate than ARWorldMap with at least 5 attempts of each type.
    var objectAnchorPreferred: Bool {
        guard worldMapAttempts >= 5 && objectAnchorAttempts >= 5 else { return false }
        let rateDiff = objectAnchorSuccessRate - worldMapSuccessRate
        return rateDiff > 0.1
    }
    
    /// A summary string for logging/telemetry.
    var summary: String {
        return """
        Relocalization Metrics:
          ARWorldMap: \(worldMapSuccesses)/\(worldMapAttempts) succeeded (\(String(format: "%.1f", worldMapSuccessRate * 100))%), avg \(String(format: "%.1f", worldMapAverageTime))s
          ObjectAnchor: \(objectAnchorSuccesses)/\(objectAnchorAttempts) succeeded (\(String(format: "%.1f", objectAnchorSuccessRate * 100))%), avg \(String(format: "%.1f", objectAnchorAverageTime))s
          Recommended: \(objectAnchorPreferred ? "ObjectAnchor (Extended Relocalization)" : "ARWorldMap (fallback)")
        """
    }
    
    // MARK: - Recording
    
    /// Record an ARWorldMap relocalization attempt.
    func recordWorldMapAttempt() {
        worldMapAttempts += 1
    }
    
    /// Record a successful ARWorldMap relocalization with elapsed time.
    func recordWorldMapSuccess(elapsedTime: TimeInterval) {
        worldMapSuccesses += 1
        worldMapTotalTime += elapsedTime
        let msg = "ARWorldMap relocalization succeeded in \(String(format: "%.1f", elapsedTime))s (total: \(worldMapSuccesses)/\(worldMapAttempts), rate: \(String(format: "%.1f", worldMapSuccessRate * 100))%)"
        logger.info("\(msg)")
    }
    
    /// Record a failed ARWorldMap relocalization attempt.
    func recordWorldMapFailure() {
        let msg = "ARWorldMap relocalization failed (total: \(worldMapSuccesses)/\(worldMapAttempts), rate: \(String(format: "%.1f", worldMapSuccessRate * 100))%)"
        logger.info("\(msg)")
    }
    
    /// Record an ObjectAnchor relocalization attempt.
    func recordObjectAnchorAttempt() {
        objectAnchorAttempts += 1
    }
    
    /// Record a successful ObjectAnchor relocalization with elapsed time.
    func recordObjectAnchorSuccess(elapsedTime: TimeInterval) {
        objectAnchorSuccesses += 1
        objectAnchorTotalTime += elapsedTime
        let msg = "ObjectAnchor relocalization succeeded in \(String(format: "%.1f", elapsedTime))s (total: \(objectAnchorSuccesses)/\(objectAnchorAttempts), rate: \(String(format: "%.1f", objectAnchorSuccessRate * 100))%)"
        logger.info("\(msg)")
    }
    
    /// Record a failed ObjectAnchor relocalization attempt.
    func recordObjectAnchorFailure() {
        let msg = "ObjectAnchor relocalization failed (total: \(objectAnchorSuccesses)/\(objectAnchorAttempts), rate: \(String(format: "%.1f", objectAnchorSuccessRate * 100))%)"
        logger.info("\(msg)")
    }
    
    /// Log the current metrics summary.
    func logSummary() {
        let msg = summary
        logger.info("\(msg)")
    }
}
