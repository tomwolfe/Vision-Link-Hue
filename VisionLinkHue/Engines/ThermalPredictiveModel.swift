import Foundation
import os

/// Predictive thermal model that analyzes inference latency trends to
/// forecast device thermal state changes before they occur.
///
/// Uses an exponential weighted moving average (EWMA) of inference latency
/// combined with a linear trend slope to predict when the device will
/// enter a degraded thermal state. This allows proactive throttling
/// before the system thermal state transitions to "Serious".
///
/// The prediction model uses two configurable parameters:
/// - `latencyThresholdMs`: The EWMA latency above which throttling activates.
/// - `slopeThreshold`: The rate-of-change slope above which preemptive
///   throttling activates, even if absolute latency is below threshold.
@MainActor
final class ThermalPredictiveModel {
    
    /// Whether predictive throttling is currently active.
    var isPredictiveThrottling: Bool {
        latencyTrendSlope > configuration.slopeThreshold || ewmaLatency >= configuration.latencyThresholdMs
    }
    
    /// Predicted thermal state based on latency trends, potentially
    /// one level worse than the actual thermal state.
    var predictedThermalState: ThermalState {
        if latencyTrendSlope > configuration.slopeThreshold * 2 {
            return .critical
        } else if latencyTrendSlope > configuration.slopeThreshold {
            return .serious
        } else if ewmaLatency >= configuration.latencyThresholdMs {
            return .warning
        } else {
            return thermalState
        }
    }
    
    /// Current actual thermal state from the system.
    var thermalState: ThermalState
    
    /// Exponential weighted moving average of inference latency (milliseconds).
    var ewmaLatency: Double
    
    /// Current rate-of-change slope of the EWMA latency (ms per sample).
    var latencyTrendSlope: Double
    
    /// Configuration thresholds for predictive throttling.
    struct PredictiveConfiguration: Sendable {
        /// EWMA latency threshold (ms) that triggers throttling.
        let latencyThresholdMs: Double
        
        /// Rate-of-change slope (ms per sample) that triggers preemptive throttling.
        let slopeThreshold: Double
        
        /// EWMA smoothing factor (0.0 to 1.0). Higher values react faster
        /// to recent changes; lower values smooth out short-term spikes.
        let smoothingFactor: Double
        
        /// Number of samples to retain for slope calculation.
        let slopeWindow: Int
        
        static let `default` = PredictiveConfiguration(
            latencyThresholdMs: 300,
            slopeThreshold: 5.0,
            smoothingFactor: 0.3,
            slopeWindow: 8
        )
    }
    
    private var configuration: PredictiveConfiguration
    private var latencyHistory: [Double]
    private var sampleCount: Int = 0
    
    /// Initialize the predictive thermal model.
    /// - Parameters:
    ///   - thermalState: The current actual thermal state.
    ///   - configuration: Predictive model thresholds and parameters.
    init(thermalState: ThermalState = .nominal, configuration: PredictiveConfiguration = .default) {
        self.thermalState = thermalState
        self.configuration = configuration
        self.ewmaLatency = 0.0
        self.latencyTrendSlope = 0.0
        self.latencyHistory = []
    }
    
    /// Update the predictive model with a new inference latency measurement.
    /// - Parameter latencyMs: The inference latency in milliseconds.
    func update(withLatency latencyMs: Double) {
        sampleCount += 1
        
        // Update EWMA
        if ewmaLatency == 0.0 {
            ewmaLatency = latencyMs
        } else {
            let alpha = configuration.smoothingFactor
            ewmaLatency = alpha * latencyMs + (1 - alpha) * ewmaLatency
        }
        
        // Record latency for slope calculation
        latencyHistory.append(ewmaLatency)
        
        // Maintain sliding window for slope
        if latencyHistory.count > configuration.slopeWindow {
            latencyHistory.removeFirst()
        }
        
        // Compute trend slope using simple linear regression
        if latencyHistory.count >= 3 {
            latencyTrendSlope = computeSlope(latencyHistory)
        }
    }
    
    /// Reset the predictive model state.
    /// Called when thermal state changes or inference is paused.
    func reset() {
        ewmaLatency = 0.0
        latencyTrendSlope = 0.0
        latencyHistory.removeAll()
        sampleCount = 0
    }
    
    /// Update the model with a new actual thermal state.
    /// Resets latency tracking on state transitions.
    func updateThermalState(_ newState: ThermalState) {
        if newState != thermalState {
            logger.info("Predictive model: thermal state changed \(self.thermalState) -> \(newState)")
            thermalState = newState
            reset()
        }
    }
    
    /// Compute the slope of a linear regression over the latency history.
    /// Uses the standard least-squares formula:
    ///     slope = (n * sum(x*y) - sum(x) * sum(y)) / (n * sum(x^2) - (sum(x))^2)
    /// where x is the sample index and y is the EWMA latency.
    private func computeSlope(_ data: [Double]) -> Double {
        let n = Double(data.count)
        var sumX: Double = 0
        var sumY: Double = 0
        var sumXY: Double = 0
        var sumX2: Double = 0
        
        for (i, y) in data.enumerated() {
            let x = Double(i)
            sumX += x
            sumY += y
            sumXY += x * y
            sumX2 += x * x
        }
        
        let denominator = n * sumX2 - sumX * sumX
        
        if abs(denominator) < 1e-10 {
            return 0.0
        }
        
        return (n * sumXY - sumX * sumY) / denominator
    }
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "ThermalPredictive"
    )
}
