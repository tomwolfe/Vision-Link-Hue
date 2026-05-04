import Foundation
import simd
import os

/// Engine that computes the optimal rigid-body transformation (rotation + translation)
/// between ARKit local space and Bridge Room Space coordinates using the Kabsch algorithm.
///
/// The Kabsch algorithm uses singular value decomposition (SVD) to find the optimal
/// rotation matrix that minimizes the RMSD between two centered point sets.
@MainActor
final class SpatialCalibrationEngine {
    
    // MARK: - Public State
    
    /// Whether a valid 3+ point calibration has been established.
    var isCalibrated: Bool { calibrationPoints.count >= 3 }
    
    /// Computed transformation matrix (rotation + translation).
    /// `nil` until at least 3 calibration points are available.
    var transformation: Transformation?
    
    /// Maximum number of calibration points to retain.
    private static let maxCalibrationPoints = 6
    
    /// Minimum number of calibration points required for a valid transform.
    private static let minCalibrationPoints = 3
    
    // MARK: - Private State
    
    /// Calibration points for transformation between ARKit and Bridge space.
    private var calibrationPoints: [(arKit: SIMD3<Float>, bridge: SIMD3<Float>)] = []
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "SpatialCalibration"
    )
    
    // MARK: - Transformation Model
    
    /// Rigid-body transformation consisting of a 3x3 rotation matrix and 3D translation vector.
    struct Transformation: Sendable {
        let rotation: simd_float3x3
        let translation: SIMD3<Float>
        
        /// Apply the transformation to a point.
        func apply(_ point: SIMD3<Float>) -> SIMD3<Float> {
            rotation * point + translation
        }
    }
    
    // MARK: - Calibration API
    
    /// Add a calibration point to the transformation solver.
    func addCalibrationPoint(arKit: SIMD3<Float>, bridge: SIMD3<Float>) {
        calibrationPoints.append((arKit: arKit, bridge: bridge))
        
        if calibrationPoints.count > Self.maxCalibrationPoints {
            calibrationPoints = Array(calibrationPoints.suffix(Self.maxCalibrationPoints))
        }
        
        logger.info(
            "Calibration point added (\(self.calibrationPoints.count)/\(Self.minCalibrationPoints) minimum). Calibrated: \(self.isCalibrated)"
        )
        
        if isCalibrated {
            computeTransformation()
        }
    }
    
    /// Clear all calibration points and reset the transformation.
    func clearCalibration() {
        calibrationPoints.removeAll()
        transformation = nil
        logger.info("Calibration cleared")
    }
    
    /// Get the current calibration points for inspection.
    func getCalibrationPoints() -> [(arKit: SIMD3<Float>, bridge: SIMD3<Float>)] {
        calibrationPoints
    }
    
    /// Map an ARKit coordinate to Bridge Room Space using the computed transformation.
    func mapToBridgeSpace(_ arKitPos: SIMD3<Float>) -> SIMD3<Float> {
        transformation?.apply(arKitPos) ?? arKitPos
    }
    
    /// Map an ARKit coordinate with orientation to Bridge Room Space.
    func mapToBridgeSpace(
        arKitPosition: SIMD3<Float>,
        arKitOrientation: simd_quatf
    ) -> (position: SIMD3<Float>, orientation: simd_quatf) {
        let bridgePosition = mapToBridgeSpace(arKitPosition)
        let bridgeOrientation = arKitOrientation
        return (bridgePosition, bridgeOrientation)
    }
    
    // MARK: - Kabsch Algorithm Implementation
    
    /// Compute the optimal rigid-body transformation using the Kabsch algorithm.
    private func computeTransformation() {
        guard calibrationPoints.count >= Self.minCalibrationPoints else { return }
        
        let n = calibrationPoints.count
        
        // Compute centroids
        var sourceCentroid = SIMD3<Float>(0, 0, 0)
        var targetCentroid = SIMD3<Float>(0, 0, 0)
        
        for point in calibrationPoints {
            sourceCentroid += point.arKit
            targetCentroid += point.bridge
        }
        sourceCentroid /= Float(n)
        targetCentroid /= Float(n)
        
        // Compute centered covariance matrix H = sum(dt * ds^T)
        var covMatrix = simd_float3x3(
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(0, 0, 0)
        )
        
        for point in calibrationPoints {
            let ds = point.arKit - sourceCentroid
            let dt = point.bridge - targetCentroid
            covMatrix.columns.0 += dt * ds.x
            covMatrix.columns.1 += dt * ds.y
            covMatrix.columns.2 += dt * ds.z
        }
        
        // Compute optimal rotation
        let rotation = kabschRotation(from: covMatrix)
        
        // Compute translation: t = target_centroid - R * source_centroid
        let translation = targetCentroid - rotation * sourceCentroid
        
        transformation = Transformation(rotation: rotation, translation: translation)
        
        logger.debug(
            "Kabsch transformation computed from \(n) points. Translation: (\(String(format: "%.3f", translation.x)), \(String(format: "%.3f", translation.y)), \(String(format: "%.3f", translation.z)))"
        )
    }
    
    /// Compute the optimal rotation matrix using the Kabsch algorithm.
    /// Uses polar decomposition: R = H * (H^T * H)^(-1/2)
    /// This avoids the need for SVD while providing numerically stable results.
    private func kabschRotation(from covMatrix: simd_float3x3) -> simd_float3x3 {
        let H = covMatrix
        let HTH = H.transpose * H
        let detHTH = determinant(HTH)
        
        if detHTH < 1e-6 {
            logger.warning("Kabsch algorithm: det(HTH) = \(detHTH) < 1e-6, falling back to identity transformation. Covariance matrix may be ill-conditioned due to collinear or insufficient calibration points.")
            return simd_float3x3(
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0, 1, 0),
                SIMD3<Float>(0, 0, 1)
            )
        }
        
        let HTHInvSqrt = inverseSqrtMatrix(HTH)
        var R = H * HTHInvSqrt
        
        // Ensure proper rotation (handle reflection)
        let det = determinant(R)
        if det < 0 {
            // Flip the column corresponding to the smallest singular value
            R.columns.2 = -R.columns.2
        }
        
        // Re-orthogonalize via Gram-Schmidt
        R = orthogonalize(R)
        
        return R
    }
    
    /// Compute the inverse square root of a 3x3 matrix using Newton's method.
    private func inverseSqrtMatrix(_ M: simd_float3x3) -> simd_float3x3 {
        // Initial guess using trace
        let trace = M.columns.0.x + M.columns.1.y + M.columns.2.z
        let scale = 1.0 / sqrt(max(trace, 1e-6))
        var X = simd_float3x3(
            SIMD3<Float>(scale, 0, 0),
            SIMD3<Float>(0, scale, 0),
            SIMD3<Float>(0, 0, scale)
        )
        
        // Newton-Raphson iterations: X_{n+1} = 0.5 * X_n * (3I - M * X_n^2)
        // Converge when change falls below epsilon, capped by max iterations
        let maxIterations = 20
        let epsilon: Float = 1e-5
        for _ in 0..<maxIterations {
            let MX = M * X
            let MX2 = MX * MX
            let threeI_minus_MX2 = simd_float3x3(
                SIMD3<Float>(3 - MX2.columns.0.x, -MX2.columns.0.y, -MX2.columns.0.z),
                SIMD3<Float>(-MX2.columns.1.x, 3 - MX2.columns.1.y, -MX2.columns.1.z),
                SIMD3<Float>(-MX2.columns.2.x, -MX2.columns.2.y, 3 - MX2.columns.2.z)
            )
            let XNew = 0.5 * (X * threeI_minus_MX2)
            
            let diff = simd_length(XNew.columns.0 - X.columns.0)
                + simd_length(XNew.columns.1 - X.columns.1)
                + simd_length(XNew.columns.2 - X.columns.2)
            
            X = XNew
            
            if diff <= epsilon {
                break
            }
        }
        
        return X
    }
    
    /// Compute the determinant of a 3x3 matrix.
    private func determinant(_ M: simd_float3x3) -> Float {
        let a = M.columns.0.x
        let b = M.columns.0.y
        let c = M.columns.0.z
        let d = M.columns.1.x
        let e = M.columns.1.y
        let f = M.columns.1.z
        let g = M.columns.2.x
        let h = M.columns.2.y
        let i = M.columns.2.z
        
        return a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    }
    
    /// Orthogonalize a 3x3 matrix using Gram-Schmidt process.
    private func orthogonalize(_ M: simd_float3x3) -> simd_float3x3 {
        var c0 = normalize(M.columns.0)
        var c1 = M.columns.1 - c0 * dot(c0, M.columns.1)
        c1 = normalize(c1)
        var c2 = cross(M.columns.0, M.columns.1)
        c2 = normalize(c2)
        
        return simd_float3x3(c0, c1, c2)
    }
}
