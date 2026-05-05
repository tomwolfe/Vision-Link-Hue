import Foundation
import simd
import os

/// Keychain-backed persistence store for spatial calibration data.
/// Stores the rotation matrix and translation vector from the Kabsch
/// algorithm in the iOS Keychain, enabling calibration reuse across
/// app launches when ARKit re-localizes in a known room.
@MainActor
final class KeychainCalibrationStore: SpatialCalibrationPersistenceStore {
    
    private let keychainManager: KeychainManager
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "CalibrationPersistence"
    )
    
    /// Keychain key for the calibration rotation data.
    private static let rotationKey = "calibration_rotation"
    
    /// Keychain key for the calibration translation data.
    private static let translationKey = "calibration_translation"
    
    /// Initialize with a Keychain manager.
    /// - Parameter keychainManager: The keychain manager to use for storage.
    init(keychainManager: KeychainManager) {
        self.keychainManager = keychainManager
    }
    
    func loadCalibration() async -> CalibrationData? {
        let rotationData: Data?
        let translationData: Data?
        do {
            rotationData = try await keychainManager.getItem(forKey: Self.rotationKey)
            translationData = try await keychainManager.getItem(forKey: Self.translationKey)
        } catch {
            logger.error("Failed to load calibration from keychain: \(error.localizedDescription)")
            return nil
        }
        
        guard let rotationData, let translationData else {
            return nil
        }
        
        return CalibrationData(rotationData: rotationData, translationData: translationData)
    }
    
    func saveCalibration(rotationData: Data, translationData: Data) async {
        do {
            try await keychainManager.setItem(rotationData, forKey: Self.rotationKey)
            try await keychainManager.setItem(translationData, forKey: Self.translationKey)
            logger.info("Calibration saved to keychain")
        } catch {
            logger.error("Failed to save calibration to keychain: \(error.localizedDescription)")
        }
    }
    
    func clearCalibration() async {
        await keychainManager.removeItem(forKey: Self.rotationKey)
        await keychainManager.removeItem(forKey: Self.translationKey)
        logger.debug("Calibration cleared from keychain")
    }
}
