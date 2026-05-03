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
/// DetectionEngine subscribes to this monitor to dynamically adjust
/// its inference interval based on thermal conditions.
@MainActor
final class ThermalMonitor: @unchecked Sendable {
    
    /// Current thermal state of the device.
    var thermalState: ThermalState = .nominal
    
    /// Callback invoked when thermal state changes.
    var onStateChange: ((ThermalState) -> Void)?
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "ThermalMonitor"
    )
    
    private var thermalMonitoringTask: Task<Void, Never>?
    
    /// Start monitoring thermal state changes via notification.
    func start() {
        guard thermalMonitoringTask == nil else { return }
        
        thermalMonitoringTask = Task { [weak self] in
            guard let self else { return }
            
            for await notification in NotificationCenter.default.notifications(named: ProcessInfo.thermalStateDidChangeNotification) {
                guard let _ = notification.object as? ProcessInfo else { continue }
                
                let previousState = self.thermalState
                self.thermalState = Self.mapSystemThermalState(ProcessInfo.processInfo.thermalState)
                
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
            return .serious
        @unknown default:
            return .nominal
        }
    }
}
