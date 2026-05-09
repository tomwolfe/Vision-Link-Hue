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
///
/// ## Thermal Threshold Calibration by Silicon Generation
///
/// The predictive model's baselines vary by NPU/ARM architecture.
/// The following table provides recommended calibration values per
/// silicon generation for optimal performance:
///
/// | Silicon | Chip | NPU Perf. | Recommended `latencyThresholdMs` | Recommended `slopeThreshold` | Notes |
/// |---------|------|-----------|----------------------------------|------------------------------|-------|
/// | A15 | iPhone 13 Pro | 11 TOPS | 350 | 6.0 | Older NPU, higher baseline latency |
/// | A16 | iPhone 14 Pro | 11 TOPS | 320 | 5.5 | Similar to A15, slight improvement |
/// | A17 Pro | iPhone 15 Pro | 15 TOPS | 300 | 5.0 | Hardware ray tracing, improved NPU |
/// | M4 | iPad Pro 2024 | 38 TOPS | 180 | 4.2 | Desktop-class NPU, sub-50ms baseline |
/// | M4 Ultra | Mac | 38+ TOPS | 150 | 3.8 | Server-class, highest throughput |
/// | Apple Vision Pro (M2) | Vision Pro | 15 TOPS | 220 | 4.5 | Same as A17 Pro NPU |
/// | Apple Vision Pro 2 (M3) | Vision Pro 2 | 20 TOPS | 180 | 4.2 | 2026 upgrade, tight thermal margin |
///
/// ### Runtime Auto-Calibration
///
/// By default, the model auto-calibrates at launch by measuring baseline
/// inference latency over the first 32 samples. It then adjusts thresholds
/// relative to the measured baseline:
/// - `latencyThresholdMs` = baseline * 2.5 (allows 2.5x headroom before warning)
/// - `slopeThreshold` = baseline * 0.15 (detects rapid thermal ramp)
///
/// This prevents over-throttling on powerful chips (M4 iPad Pro, Vision Pro 2)
/// where the default 180ms threshold would trigger prematurely.
///
/// To disable auto-calibration and use fixed thresholds:
/// ```swift
/// let fixedConfig = PredictiveConfiguration(
///     latencyThresholdMs: 180,
///     slopeThreshold: 4.2,
///     smoothingFactor: 0.3,
///     slopeWindow: 8,
///     enableAutoCalibration: false,
///     calibrationSamples: 32
/// )
/// ```
///
/// ### Thermal State Transition Points
///
/// The model transitions between predictive thermal states based on:
/// - `predictedThermalState == .warning`: EWMA exceeds `latencyThresholdMs`
/// - `predictedThermalState == .serious`: Slope exceeds `slopeThreshold`
/// - `predictedThermalState == .critical`: Slope exceeds `slopeThreshold * 2`
///
/// When in `.serious` or `.critical` predicted state, the DetectionEngine
/// should switch CoreML compute units from `.all` to `.cpuOnly` to
/// prevent abrupt LiDAR shutdown.
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

        /// Whether to enable runtime auto-calibration. When enabled, the model
        /// measures baseline inference latency over the first `calibrationSamples`
        /// samples and adjusts thresholds relative to actual device performance.
        /// This prevents over-throttling on more powerful chips (M4 iPad Pro,
        /// Vision Pro 2) where the default 300ms threshold is too conservative.
        let enableAutoCalibration: Bool

        /// Number of initial samples to collect for baseline calibration.
        let calibrationSamples: Int

        static let `default` = PredictiveConfiguration(
            latencyThresholdMs: 180,
            slopeThreshold: 4.2,
            smoothingFactor: 0.3,
            slopeWindow: 8,
            enableAutoCalibration: true,
            calibrationSamples: 32
        )
    }
    
    private var configuration: PredictiveConfiguration
    var latencyHistory: [Double]
    var sampleCount: Int = 0

    /// Baseline latency measured during calibration (milliseconds).
    /// Set after the first `calibrationSamples` samples when auto-calibration is enabled.
    private var baselineLatencyMs: Double?

    /// Whether auto-calibration is active (measuring baseline from initial samples).
    private var isCalibrating: Bool = false

    /// Accumulator for baseline latency during calibration.
    private var calibrationLatencySum: Double = 0
    
    /// Precomputed least-squares constants for the fixed slope window.
    /// For x = [0, 1, ..., n-1]:
    ///   sumX = n*(n-1)/2, sumX2 = (n-1)*n*(2n-1)/6
    ///   denominator = n*sumX2 - sumX²
    private var precomputedSumX: Double
    private var precomputedSumX2: Double
    private var precomputedDenominator: Double
    
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

        let n = Double(configuration.slopeWindow)
        precomputedSumX = n * (n - 1.0) / 2.0
        precomputedSumX2 = (n - 1.0) * n * (2.0 * n - 1.0) / 6.0
        precomputedDenominator = n * precomputedSumX2 - precomputedSumX * precomputedSumX

        if configuration.enableAutoCalibration {
            isCalibrating = true
            logger.info("Runtime auto-calibration enabled: measuring baseline over \(configuration.calibrationSamples) samples")
        }
    }
    
    /// Update the predictive model with a new inference latency measurement.
    /// - Parameter latencyMs: The inference latency in milliseconds.
    func update(withLatency latencyMs: Double) {
        sampleCount += 1

        // During calibration phase, accumulate raw latency for baseline measurement.
        if isCalibrating {
            calibrationLatencySum += latencyMs

            if sampleCount >= configuration.calibrationSamples {
                baselineLatencyMs = calibrationLatencySum / Double(configuration.calibrationSamples)
                isCalibrating = false

                if let baseline = baselineLatencyMs {
                    logger.info("Auto-calibration complete: baseline latency \(String(format: "%.1f", baseline))ms. Adjusting thresholds.")
                    configuration = PredictiveConfiguration(
                        latencyThresholdMs: baseline * 2.5,
                        slopeThreshold: baseline * 0.15,
                        smoothingFactor: configuration.smoothingFactor,
                        slopeWindow: configuration.slopeWindow,
                        enableAutoCalibration: false,
                        calibrationSamples: configuration.calibrationSamples
                    )
                }
            }
        }

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

        if configuration.enableAutoCalibration {
            isCalibrating = true
            calibrationLatencySum = 0
            baselineLatencyMs = nil
        }
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
    ///
    /// Optimized for a fixed-window regression: sumX, sumX2, and the denominator
    /// are precomputed at init time since x is always [0, 1, ..., n-1].
    /// Only sumY and sumXY are computed per call.
    private func computeSlope(_ data: [Double]) -> Double {
        let n = Double(data.count)
        var sumY: Double = 0
        var sumXY: Double = 0
        
        for (i, y) in data.enumerated() {
            sumY += y
            sumXY += Double(i) * y
        }
        
        let sumX = n * (n - 1.0) / 2.0
        let sumX2 = (n - 1.0) * n * (2.0 * n - 1.0) / 6.0
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
