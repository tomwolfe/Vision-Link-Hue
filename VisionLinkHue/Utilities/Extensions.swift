import Foundation
import simd
import ARKit

// MARK: - simd_float4x4 Extensions

extension simd_float4x4 {
    /// Extract the XYZ components of a column as a SIMD3 vector.
    var xyz: SIMD3<Float> {
        SIMD3<Float>(columns.0.x, columns.0.y, columns.0.z)
    }
    
    /// Extract the translation (4th column) as a SIMD3 vector.
    /// Uses native .position accessor available since iOS 19/26.
    var translation: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }
}

// MARK: - ARFrame Extensions

extension ARFrame {
    /// Get the captured image as a CVPixelBuffer.
    var imageBuffer: CVPixelBuffer {
        self.capturedImage
    }
}

// MARK: - Date/Time Formatting

extension Date {
    /// Format as ISO 8601 string.
    func toISO8601() -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: self)
    }
}

// MARK: - JSON Utilities

extension JSONDecoder {
    /// Create a decoder with ISO 8601 date decoding strategy.
    static var hueDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

extension JSONEncoder {
    /// Create an encoder with ISO 8601 date encoding strategy.
    static var hueEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}

// MARK: - Optional Chaining Helper

extension Optional where Wrapped: RangeReplaceableCollection {
    /// Safely append to an optional collection.
    mutating func safeAppend(_ element: Wrapped.Element) {
        if self == nil { self = .init() }
        self?.append(element)
    }
}
