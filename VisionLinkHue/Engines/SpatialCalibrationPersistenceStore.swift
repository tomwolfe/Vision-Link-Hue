import Foundation

/// Protocol for persisting spatial calibration transformation data.
/// Allows the `SpatialCalibrationEngine` to save and restore calibration
/// across app launches without being tightly coupled to a specific
/// storage mechanism.
@MainActor
protocol SpatialCalibrationPersistenceStore {
    
    /// Represents persisted calibration data.
    struct CalibrationData {
        let rotationData: Data
        let translationData: Data
    }
    
    /// Load previously saved calibration data.
    /// Returns `nil` if no calibration has been persisted.
    func loadCalibration() async -> CalibrationData?
    
    /// Save a calibration transformation.
    func saveCalibration(rotationData: Data, translationData: Data) async
    
    /// Remove persisted calibration data.
    func clearCalibration() async
}
