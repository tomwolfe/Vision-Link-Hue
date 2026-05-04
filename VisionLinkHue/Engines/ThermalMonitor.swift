import Foundation
import os

/// Represents the thermal state of the device for adaptive inference throttling.
/// Used to prevent the device from entering a "Serious" thermal state that
/// forces LiDAR shut-off.
enum ThermalState: Comparable, CustomStringConvertible {
    case nominal
    case fair
    case warning
    case serious
    case critical
    
    var description: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .warning: return "Warning"
        case .serious: return "Serious"
        case .critical: return "Critical"
        }
    }
}

/// Monitors device thermal state and provides adaptive inference throttling.
/// Subscribes to `ProcessInfo.thermalStateDidChangeNotification` and
/// updates the thermal state for consumers to react to.
///
/// Integrates with `ThermalPredictiveModel` to proactively throttle
/// inference based on rising latency trends, preventing the device
/// from reaching a "Serious" thermal state before the system detects it.
///
/// DetectionEngine subscribes to this monitor to dynamically adjust
/// its inference interval based on thermal conditions.
@MainActor
final class ThermalMonitor: Sendable {
    
    /// Current thermal state of the device.
    var thermalState: ThermalState = .nominal
    
    /// Whether predictive throttling is currently active.
    var isPredictiveThrottlingActive: Bool {
        predictiveModel.isPredictiveThrottling
    }
    
    /// The predicted thermal state based on latency trends.
    /// May be one level worse than the actual thermal state when
    /// rising latency trends indicate imminent thermal degradation.
    var predictedThermalState: ThermalState {
        predictiveModel.predictedThermalState
    }
    
    /// The effective thermal state used for adaptive throttling decisions.
    /// Returns the worse of the actual and predicted states.
    var effectiveThermalState: ThermalState {
        max(thermalState, predictedThermalState)
    }
    
    /// Callback invoked when thermal state changes.
    var onStateChange: ((ThermalState) -> Void)?
    
    /// Callback invoked when predictive throttling state changes.
    var onPredictiveThrottleChange: ((Bool) -> Void)?
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "ThermalMonitor"
    )
    
    private var thermalMonitoringTask: Task<Void, Never>?
    
    /// Predictive thermal model for proactive throttling based on
    /// inference latency trends.
    private var predictiveModel: ThermalPredictiveModel
    
    /// Initialize with an optional predictive model configuration.
    /// - Parameter predictiveConfig: Configuration for the predictive throttling model.
    init(predictiveConfig: ThermalPredictiveModel.PredictiveConfiguration? = nil) {
        if let config = predictiveConfig {
            self.predictiveModel = ThermalPredictiveModel(thermalState: .nominal, configuration: config)
        } else {
            self.predictiveModel = ThermalPredictiveModel(thermalState: .nominal)
        }
    }
    
    /// Update the predictive model with a new inference latency measurement.
    /// - Parameter latencyMs: The inference latency in milliseconds.
    func updateWithLatency(_ latencyMs: Double) {
        predictiveModel.update(withLatency: latencyMs)
        
        let wasPredictiveActive = predictiveModel.isPredictiveThrottling
        if wasPredictiveActive {
            logger.debug(
                "Predictive throttling active: EWMA=\(String(format: "%.0f", predictiveModel.ewmaLatency))ms, slope=\(String(format: "%.1f", predictiveModel.latencyTrendSlope))ms/sample"
            )
        }
    }
    
    /// Start monitoring thermal state changes via notification.
    func start() {
        guard thermalMonitoringTask == nil else { return }
        
        thermalMonitoringTask = Task { [weak self] in
            guard let self else { return }
            
            for await notification in NotificationCenter.default.notifications(named: ProcessInfo.thermalStateDidChangeNotification) {
                guard let _ = notification.object as? ProcessInfo else { continue }
                
                let previousState = self.thermalState
                self.thermalState = Self.mapSystemThermalState(ProcessInfo.processInfo.thermalState)
                self.predictiveModel.updateThermalState(self.thermalState)
                
                if self.thermalState != previousState {
                    self.logger.info("Thermal state changed: \(previousState) -> \(self.thermalState)")
                    self.onStateChange?(self.thermalState)
                }
            }
        }
    }
    
    /// Stop thermal state monitoring.
    func stop() {
        thermalMonitoringTask?.cancel()
        thermalMonitoringTask = nil
    }
    
    /// Map ProcessInfo thermal state to our ThermalState enum.
    private static func mapSystemThermalState(_ systemState: ProcessInfo.ThermalState) -> ThermalState {
        switch systemState {
        case .nominal:
            return .nominal
        case .fair:
            return .fair
        case .serious:
            return .warning
        case .critical:
            return .critical
        @unknown default:
            return .nominal
        }
    }
}
