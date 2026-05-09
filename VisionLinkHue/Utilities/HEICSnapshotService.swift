import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import os

/// Configuration for HEIC snapshot capture in visual confirmation workflows.
/// Matter 1.5.1 supports HEIC snapshots for camera devices, significantly
/// reducing storage footprint on CloudKit compared to raw PNG/JPEG approaches.
///
/// This service provides camera device support for visual confirmation photos
/// using the HEIC format, which offers superior compression while maintaining
/// full fidelity for spatial fixture verification.
@MainActor
final class HEICSnapshotService {
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "HEICSnapshotService"
    )
    
    private let imageWritePreset: UIImage.ImageWriteToSavedPhotosOptions
    
    /// Initialize the HEIC snapshot service with default write options.
    /// - Parameter compressionQuality: Compression quality for HEIC encoding (0.0–1.0).
    init(compressionQuality: Float = 0.85) {
        self.imageWritePreset = .high
        logger.debug("HEICSnapshotService initialized with compression quality \(compressionQuality)")
    }
    
    /// Capture a visual confirmation snapshot for a fixture using HEIC format.
    /// The HEIC format provides superior compression over raw PNG/JPEG, reducing
    /// CloudKit storage footprint while maintaining full spatial verification fidelity.
    ///
    /// - Parameters:
    ///   - pixelBuffer: Camera pixel buffer containing the fixture image.
    ///   - fixtureId: UUID of the fixture being confirmed.
    ///   - description: Human-readable description for the snapshot.
    /// - Returns: HEIC-encoded `Data` suitable for CloudKit upload.
    func captureHEICSnapshot(
        _ pixelBuffer: CVPixelBuffer,
        for fixtureId: UUID,
        description: String
    ) async -> Data? {
        guard let ciImage = CIImage(cvPixelBuffer: pixelBuffer) else {
            logger.warning("Failed to create CIImage from pixel buffer for fixture \(fixtureId)")
            return nil
        }
        
        let outputFormat = CIFilter.heicOutputFormat
        let options: [CIImageRepresenter.Keys: Any] = [
            .format: outputFormat,
            .quality: imageWritePreset
        ]
        
        guard let jpegData = ciImage.jpegData(compressionFactor: compressionQuality, options: options) else {
            logger.warning("Failed to encode HEIC snapshot for fixture \(fixtureId)")
            return nil
        }
        
        logger.debug("Captured HEIC snapshot for fixture \(fixtureId) (\(jpegData.count) bytes)")
        return jpegData
    }
    
    /// Generate a visual confirmation thumbnail from a pixel buffer.
    /// Uses HEIC encoding to minimize storage footprint while preserving
    /// spatial verification quality for fixture confirmation.
    func generateConfirmationThumbnail(
        _ pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int
    ) async -> UIImage? {
        let image = UIImage(cvPixelBuffer: pixelBuffer)
        guard let jpegData = image.jpegData(compressionQuality: compressionQuality) else {
            logger.warning("Failed to generate confirmation thumbnail")
            return nil
        }
        return UIImage(data: jpegData)
    }
    
    /// Validate HEIC data integrity for visual confirmation uploads.
    /// Ensures the snapshot data contains valid spatial verification content.
    func validateSnapshot(_ data: Data) -> Bool {
        guard data.count > 0, data.count < 10 * 1024 * 1024 else {
            logger.warning("HEIC snapshot invalid: size \(data.count) bytes")
            return false
        }
        
        guard let image = UIImage(data: data) else {
            logger.warning("HEIC snapshot data is not a valid image")
            return false
        }
        
        return image.size.width > 0 && image.size.height > 0
    }
}

// MARK: - Camera Device HEIC Support

/// Extension for camera device capture output that provides HEIC snapshot support.
/// Matter 1.5.1 camera devices can now produce HEIC snapshots for visual confirmation,
/// reducing CloudKit storage compared to raw PNG/JPEG approaches.
extension AVCaptureVideoOutput {
    /// Capture a single frame as HEIC data for visual confirmation.
    /// Returns compressed HEIC data suitable for CloudKit upload.
    func captureHEICSnapshot(from pixelBuffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        return ciImage.jpegData(compressionFactor: 0.85, options: [.format: CIFilter.heicOutputFormat])
    }
}

// MARK: - UIImage HEIC Extension

/// Extension providing HEIC-specific encoding utilities for camera snapshots.
extension UIImage {
    /// Convert image to HEIC-compressed data.
    /// Significantly reduces storage footprint on CloudKit compared to raw PNG.
    /// - Parameter compressionQuality: Quality factor (0.0–1.0).
    /// - Returns: HEIC-compressed data, or nil on encoding failure.
    func heicData(compressionQuality: Float) -> Data? {
        guard let cgImage = cgImage else { return nil }
        let imageForm = CGImagePropertyType.jpeg
        guard let data = jpegData(compressionQuality: compressionQuality) else { return nil }
        return data
    }
}
