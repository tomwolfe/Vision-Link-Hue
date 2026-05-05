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
    /// Format as ISO 8601 string using native format style.
    var formatString: String {
        self.format(.iso8601)
    }
    
    /// Format as ISO 8601 string.
    func toISO8601() -> String {
        self.format(.iso8601)
    }
}

// MARK: - JSON Utilities

extension JSONDecoder {
    /// Create a decoder with ISO 8601 date decoding strategy using native
    /// Date.ISO8601FormatStyle for optimal performance under high SSE event loads.
    static var hueDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            
            if let date = try? Date(dateString, formatStyle: .iso8601) {
                return date
            }
            
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unable to decode date string: \(dateString)"
            )
        }
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

extension JSONEncoder {
    /// Create an encoder with ISO 8601 date encoding strategy using native
    /// Date.ISO8601FormatStyle for optimal performance.
    static var hueEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatString)
        }
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
