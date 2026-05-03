import Foundation
import simd

/// Utility for converting `simd_quatf` to/from `Data`.
/// Used for binary serialization of quaternion orientation data.
public enum QuaternionTransform {
    
    /// The binary size of a `simd_quatf` (4 x Float32).
    private static let quaternionSize = MemoryLayout<simd_quatf>.size
    
    /// Transforms `simd_quatf` into `Data` for storage.
    public static func transform(_ value: simd_quatf) -> Data {
        withUnsafeBytes(of: value) { bytes in
            Data(bytes: bytes.baseAddress!, count: quaternionSize)
        }
    }
    
    /// Transforms stored `Data` back into a `simd_quatf`.
    public static func revert(_ data: Data) -> simd_quatf {
        guard data.count == quaternionSize else {
            return simd_quatf()
        }
        
        return data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(as: simd_quatf.self)
        }
    }
}
