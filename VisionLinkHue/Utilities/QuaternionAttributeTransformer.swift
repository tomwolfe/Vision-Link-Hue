import Foundation
import simd

/// Utility for converting `simd_quatf` to/from `Data`.
/// Used for binary serialization of quaternion orientation data.
public enum QuaternionTransform {
    
    /// The binary size of a `simd_quatf` (4 x Float32).
    private static let quaternionSize = MemoryLayout<simd_quatf>.size
    
    /// Transforms `simd_quatf` into `Data` for storage.
    public static func transform(_ value: simd_quatf) -> Data {
        var bytes = Data(count: 16)
        bytes.withUnsafeMutableBytes { mutableBytes in
            let ptr = mutableBytes.baseAddress!
            ptr.assumingMemoryBound(to: Float.self).pointee = value.x
            ptr.advanced(by: 4).assumingMemoryBound(to: Float.self).pointee = value.y
            ptr.advanced(by: 8).assumingMemoryBound(to: Float.self).pointee = value.z
            ptr.advanced(by: 12).assumingMemoryBound(to: Float.self).pointee = value.w
        }
        return bytes
    }
    
    /// Transforms stored `Data` back into a `simd_quatf`.
    public static func revert(_ data: Data) -> simd_quatf {
        guard data.count == quaternionSize else {
            return simd_quatf()
        }
        
        var x: Float = 0, y: Float = 0, z: Float = 0, w: Float = 0
        data.withUnsafeBytes { bytes in
            let ptr = bytes.baseAddress!.assumingMemoryBound(to: Float.self)
            x = ptr.pointee
            y = ptr.advanced(by: 1).pointee
            z = ptr.advanced(by: 2).pointee
            w = ptr.advanced(by: 3).pointee
        }
        return simd_quatf(x: x, y: y, z: z, w: w)
    }
}
