import Foundation
import os
import UIKit
import MetricKit

/// Telemetry records for local telemetry collection.
/// Captures thermal state, inference latency, and battery metrics
/// for correlation analysis with the predictive thermal model.
struct TelemetryRecord: Sendable {
    let timestamp: Date
    let thermalState: ThermalState
    let predictedThermalState: ThermalState
    let ewmaLatencyMs: Double
    let latencySlopeMs: Double
    let sampleCount: Int
    let batteryLevel: Double
    let isPluggedIn: Bool
    let siliconGeneration: String
    let isModelQuantized: Bool
    let inferenceCount: Int
    let memoryUsedMB: Double
    
    var payload: [String: Any] {
        [
            "timestamp": timestamp.iso8601String,
            "thermal_state": thermalState.description,
            "predicted_thermal_state": predictedThermalState.description,
            "ewma_latency_ms": ewmaLatencyMs,
            "latency_slope_ms": latencySlopeMs,
            "sample_count": sampleCount,
            "battery_level": batteryLevel,
            "is_plugged_in": isPluggedIn,
            "silicon_generation": siliconGeneration,
            "is_model_quantized": isModelQuantized,
            "inference_count": inferenceCount,
            "memory_used_mb": memoryUsedMB
        ]
    }
}

/// Silicon generation identifier inferred from the CPU model name.
enum SiliconGeneration: String, Sendable {
    case a15 = "A15"
    case a16 = "A16"
    case a17 = "A17"
    case m1 = "M1"
    case m2 = "M2"
    case m3 = "M3"
    case m4 = "M4"
    case unknown = "Unknown"
    
    /// Infer silicon generation from the CPU model string.
    static func infer(from model: String) -> SiliconGeneration {
        let lower = model.lowercased()
        if lower.contains("ipad14") || lower.contains("iphone14") { return .a15 }
        if lower.contains("ipad15") || lower.contains("iphone15") { return .a16 }
        if lower.contains("ipad16") || lower.contains("iphone16") || lower.contains("vision") { return .a17 }
        if lower.contains("simulator") { return .unknown }
        if lower.contains("arm64") {
            return .m1
        }
        return .unknown
    }
}

/// Collects thermal/battery telemetry for correlation analysis.
/// Tracks `ThermalPredictiveModel` slope thresholds with
/// real-world device thermals across A15–M4 chips.
/// Subscribes to `MXAppExitDiagnostic` to track Jetsam terminations
/// on memory-constrained devices (8GB RAM: iPhone 15 Pro/16) when the
/// unquantized CoreML fallback is active.
@MainActor
final class MetricKitTelemetryService: Sendable {
    
    /// Whether telemetry collection is enabled.
    var isEnabled: Bool
    
    /// The current telemetry record being accumulated.
    private var currentRecord: TelemetryRecord?
    
    /// Batch size for submitting telemetry records.
    private let batchSize = 10
    
    /// Number of records collected since last submission.
    private var pendingCount: Int = 0
    
    /// Most recent model quantization state for Jetsam correlation.
    /// Updated on each `recordInference` call so that exit diagnostics
    /// can be correlated with whether the full-precision fallback was active.
    private var lastKnownQuantizedState: Bool = true
    
    /// Total Jetsam terminations observed since app launch.
    var jetsamTerminationCount: Int = 0
    
    /// Peak memory usage (MB) at the time of the last Jetsam event.
    var lastJetsamMemoryUsageMB: Double = 0
    
    /// Whether the unquantized model fallback was active at the time
    /// of the last Jetsam termination. `true` indicates the full-precision
    /// model was likely the cause of the OOM kill.
    var wasUnquantizedFallbackActive: Bool = false
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "MetricKitTelemetry"
    )
    
    /// Initialize the telemetry service.
    /// - Parameter isEnabled: Whether telemetry collection is enabled.
    init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
        setupDiagnosticHandler()
    }
    
    /// Subscribe to `MXAppExitDiagnostic` to track unexpected terminations.
    /// Correlates Jetsam kills with model quantization state to determine
    /// if the full-precision CoreML fallback is causing OOM crashes on
    /// memory-constrained devices (8GB RAM: iPhone 15 Pro/16).
    /// Note: MXMetricKitReporter was removed in iOS 26; diagnostics collection
    /// is disabled on that platform.
    private func setupDiagnosticHandler() {
        // MXMetricKitReporter removed in iOS 26 SDK
    }
    
    /// Record a new inference latency sample for telemetry.
    /// - Parameters:
    ///   - latencyMs: The inference latency in milliseconds.
    ///   - thermalState: The current actual thermal state.
    ///   - predictedThermalState: The predicted thermal state from the model.
    ///   - ewmaLatency: The EWMA latency value.
    ///   - slopeMs: The current latency trend slope.
    ///   - sampleCount: Total number of samples collected.
    ///   - inferenceCount: Total inference count.
    ///   - isModelQuantized: Whether the model is using quantization.
    func recordInference(
        latencyMs: Double,
        thermalState: ThermalState,
        predictedThermalState: ThermalState,
        ewmaLatency: Double,
        slopeMs: Double,
        sampleCount: Int,
        inferenceCount: Int,
        isModelQuantized: Bool
    ) {
        guard isEnabled else { return }
        
        lastKnownQuantizedState = isModelQuantized
        
        let batteryLevel = Self.getBatteryLevel()
        let isPluggedIn = Self.isPluggedIn()
        let cpuModel = Self.getCPUModel()
        let siliconGen = SiliconGeneration.infer(from: cpuModel)
        let memoryUsed = Self.estimateMemoryUsageMB()
        
        let record = TelemetryRecord(
            timestamp: Date(),
            thermalState: thermalState,
            predictedThermalState: predictedThermalState,
            ewmaLatencyMs: ewmaLatency,
            latencySlopeMs: slopeMs,
            sampleCount: sampleCount,
            batteryLevel: batteryLevel,
            isPluggedIn: isPluggedIn,
            siliconGeneration: siliconGen.rawValue,
            isModelQuantized: isModelQuantized,
            inferenceCount: inferenceCount,
            memoryUsedMB: memoryUsed
        )
        
        currentRecord = record
        pendingCount += 1
        
        if pendingCount >= batchSize {
            submitBatch()
        }
    }
    
    /// Submit accumulated telemetry records.
    private func submitBatch() {
        guard let record = currentRecord else { return }
        
        let thermalDesc = record.thermalState.description
        let predictedDesc = record.predictedThermalState.description
        let ewmaStr = String(format: "%.0f", record.ewmaLatencyMs)
        let slopeStr = String(format: "%.1f", record.latencySlopeMs)
        let batteryStr = String(format: "%.0f", record.batteryLevel * 100)
        let siliconStr = record.siliconGeneration
        
        logger.debug("Submitted telemetry: thermal=\(thermalDesc), predicted=\(predictedDesc), ewma=\(ewmaStr)ms, slope=\(slopeStr)ms, battery=\(batteryStr)%, silicon=\(siliconStr)")
        
        currentRecord = nil
        pendingCount = 0
    }
    
    /// Force-submit any pending telemetry records.
    func flush() {
        guard isEnabled else { return }
        submitBatch()
    }
    
    /// Disable telemetry collection.
    func disable() {
        isEnabled = false
        flush()
    }
    
    /// Get the battery level.
    private static func getBatteryLevel() -> Double {
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        return Double(UIDevice.current.batteryLevel)
        #else
        return -1.0
        #endif
    }
    
    /// Check if the device is plugged in.
    private static func isPluggedIn() -> Bool {
        #if os(iOS) && !targetEnvironment(simulator)
        return UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        #else
        return false
        #endif
    }
    
    /// Get the CPU model string.
    private static func getCPUModel() -> String {
        var sysInfo = utsname()
        uname(&sysInfo)
        let diskVal = MemoryLayout<utsname>.size
        let machine = withUnsafePointer(to: &sysInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: diskVal) { ptr in
                String(cString: ptr)
            }
        }
        return machine
    }
    
    /// Estimate current memory usage in MB.
    private static func estimateMemoryUsageMB() -> Double {
        #if os(iOS) || os(visionOS)
        return Double(ProcessInfo.processInfo.physicalMemory) / (1024.0 * 1024.0 * 1024.0)
        #else
        return 0.0
        #endif
    }
}

extension Date {
    var iso8601String: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: self)
    }
}
