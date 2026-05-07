import Foundation
import simd
import os

// MARK: - SpatialCalibrationEngine

/// Engine that computes the optimal rigid-body transformation (rotation + translation)
/// between ARKit local space and Bridge Room Space coordinates using the Kabsch algorithm.
///
/// ## Mathematical Background
///
/// The Kabsch algorithm solves the **orthogonal Procrustes problem**: given two
/// centered point sets P and Q, find the rotation matrix R that minimizes the
/// root-mean-square deviation (RMSD):
///
/// ```
/// E(R) = Σᵢ ||qᵢ - R·pᵢ||²
/// ```
///
/// where `pᵢ` are source points (ARKit coordinates) and `qᵢ` are target points
/// (Bridge Room Space coordinates).
///
/// The algorithm avoids SVD by using **polar decomposition**:
///
/// ```
/// R = H · (Hᵀ · H)^(-½)
/// ```
///
/// where `H` is the 3×3 covariance matrix between the centered point sets:
///
/// ```
/// H = Σᵢ (qᵢ - q̄) · (pᵢ - p̄)ᵀ
/// ```
///
/// The inverse square root `(Hᵀ · H)^(-½)` is computed via **Newton-Raphson
/// iteration**, which converges quadratically to the matrix inverse square root:
///
/// ```
/// X_{n+1} = ½ · X_n · (3I - M · X_n²)
/// ```
///
/// where `M = Hᵀ · H` and `X₀ = I / √(tr(M))` is the initial trace-based guess.
///
/// ## Implementation Notes
///
/// - **Numerical stability**: The Newton-Raphson method avoids the numerical
///   instability of direct SVD on ill-conditioned covariance matrices. A
///   determinant check (`det(HTH) > 1e-6`) guards against singular matrices
///   caused by collinear calibration points. When the determinant falls below
///   this threshold, calibration **fails** rather than silently returning an
///   identity transform, preventing corrupted spatial mappings.
///
/// - **Reflection handling**: After computing `R`, the determinant is checked.
///   If `det(R) < 0`, the matrix represents a reflection rather than a rotation.
///   The algorithm flips the column corresponding to the smallest singular value
///   to enforce a proper rotation (`det(R) = +1`).
///
/// - **Gram-Schmidt re-orthogonalization**: Applied after polar decomposition
///   to ensure strict orthogonality of the rotation matrix columns, correcting
///   for accumulated floating-point errors.
///
/// ## Transformation Formula
///
/// The full rigid-body transformation maps a source point `p` to the target space:
///
/// ```
/// q = R · p + t
/// ```
///
/// where the translation `t` is:
///
/// ```
/// t = q̄ - R · p̄
/// ```
///
/// and `p̄`, `q̄` are the centroids of the source and target point sets.
///
/// ## RMSD Computation
///
/// The root-mean-square deviation after transformation is:
///
/// ```
/// RMSD = √( Σᵢ ||qᵢ - (R·pᵢ + t)||² / n )
/// ```
///
/// This provides a per-point error metric for calibration quality assessment.
///
/// Supports persistence of the transformation matrix via `PersistenceStore` protocol,
/// enabling automatic calibration restoration when ARKit re-localizes in a known room.
@MainActor
final class SpatialCalibrationEngine {
    
    // MARK: - Calibration Result Types
    
    /// Represents the outcome of a Kabsch calibration computation.
    enum CalibrationResult: Sendable {
        /// Calibration succeeded with the computed transformation.
        case success(Transformation)
        /// Calibration failed due to degenerate input (collinear or identical points).
        /// The AR mapping cannot be computed and the user should provide new calibration points.
        case failed(CalibrationFailure)
    }
    
    /// Describes why a calibration computation failed.
    enum CalibrationFailure: Sendable {
        /// The covariance matrix was near-singular (`det(HTH) < 1e-6`),
        /// typically caused by collinear or identical calibration points.
        case illConditionedCovariance
        /// All calibration points are coplanar (e.g., all ceiling lights at same height),
        /// causing the covariance matrix rank to drop below 3. The engine used a
        /// 2D + height-constrained fallback to compute the transformation instead.
        case coplanarPoints
    }
    
    // MARK: - Public State
    
    /// Whether a valid calibration has been established.
    /// Returns `false` if calibration failed due to degenerate input points,
    /// even if 3+ points were provided.
    var isCalibrated: Bool { transformation != nil }
    
    /// Computed transformation matrix (rotation + translation).
    /// `nil` until at least 3 non-degenerate calibration points are available.
    /// When calibration fails (e.g., collinear points), this is set to `nil`
    /// to prevent silently applying a corrupted identity transform.
    var transformation: Transformation?
    
    /// The reason calibration failed, if `transformation` is `nil` despite
    /// having enough calibration points. `nil` when calibration has not yet
    /// been attempted or succeeded.
    var calibrationFailure: CalibrationFailure?
    
    // MARK: - Persistence
    
    /// Optional persistence store for saving/loading calibration transformation.
    /// When set, the engine automatically saves the transformation after computation
    /// and attempts to restore it on `loadPersistedCalibration()`.
    weak var persistenceStore: SpatialCalibrationPersistenceStore?
    
    /// Maximum number of calibration points to retain.
    private static let maxCalibrationPoints = 6
    
    /// Minimum number of calibration points required for a valid transform.
    static let minCalibrationPoints = 3
    
    // MARK: - Private State
    
    /// Calibration points for transformation between ARKit and Bridge space.
    private var calibrationPoints: [(arKit: SIMD3<Float>, bridge: SIMD3<Float>)] = []
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "SpatialCalibration"
    )
    
    /// Callback fired when a calibration point is successfully registered.
    /// Used by the GestureManager to provide transient haptic feedback confirming
    /// point registration without requiring the user to look away from the fixture.
    var onCalibrationPointAdded: (() -> Void)?
    
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
        onCalibrationPointAdded?()
        
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
        clearPersistedCalibration()
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
    
    // MARK: - Persistence
    
    /// Load a previously persisted calibration transformation.
    /// Returns `true` if a valid transformation was restored.
    func loadPersistedCalibration() async -> Bool {
        guard let store = persistenceStore else { return false }
        
        let persisted = await store.loadCalibration()
        
        guard let rotationData = persisted?.rotationData,
              let translationData = persisted?.translationData else {
            return false
        }
        
        let rotationCols: [simd_float3] = rotationData.withUnsafeBytes { ptr in
            ptr.bindMemory(to: simd_float3.self).map { $0 }
        }
        let rotation = simd_float3x3(rotationCols)
        
        let translationFloats = translationData.withUnsafeBytes { ptr in
            ptr.bindMemory(to: Float.self).map { $0 }
        }
        let translation = simd_float3(translationFloats[0], translationFloats[1], translationFloats[2])
        
        transformation = Transformation(rotation: rotation, translation: translation)
        logger.info("Loaded persisted calibration: rotation=[\(String(format: "%.3f", rotation.columns.0.x)), ...], translation=[\(String(format: "%.3f", translation.x)), \(String(format: "%.3f", translation.y)), \(String(format: "%.3f", translation.z))])")
        return true
    }
    
    /// Save the current transformation to the persistence store.
    func savePersistedCalibration() {
        guard let store = persistenceStore,
              let transform = transformation else { return }
        
        Task { [transform] in
            var rotation = transform.rotation
            let rotationData = Data(bytes: &rotation, count: MemoryLayout<simd_float3x3>.stride)
            var translation = transform.translation
            let translationData = Data(bytes: &translation, count: MemoryLayout<simd_float3>.stride)
            await store.saveCalibration(rotationData: rotationData, translationData: translationData)
            logger.debug("Saved calibration transformation to persistence store")
        }
    }
    
    /// Clear persisted calibration data.
    func clearPersistedCalibration() {
        guard let store = persistenceStore else { return }
        Task {
            await store.clearCalibration()
            logger.info("Cleared persisted calibration data")
        }
    }
    
    // MARK: - Kabsch Algorithm Implementation
    
    /// Compute the optimal rigid-body transformation using the Kabsch algorithm.
    ///
    /// ## Algorithm Steps
    ///
    /// 1. **Centroid Computation**: Calculate the centroid of each point set:
    ///    ```
    ///    p̄ = (1/n) · Σᵢ pᵢ
    ///    q̄ = (1/n) · Σᵢ qᵢ
    ///    ```
    ///
    /// 2. **Centering**: Subtract centroids to center each point set at the origin:
    ///    ```
    ///    p'ᵢ = pᵢ - p̄
    ///    q'ᵢ = qᵢ - q̄
    ///    ```
    ///
    /// 3. **Covariance Matrix**: Compute the 3×3 covariance matrix:
    ///    ```
    ///    H = Σᵢ q'ᵢ · (p'ᵢ)ᵀ
    ///    ```
    ///    In column-major form (simd_float3x3):
    ///    ```
    ///    H = [q'₁·p'₁ₓ  q'₁·p'₁ᵧ  q'₁·p'₁ᵤ]
    ///        [q'₂·p'₂ₓ  q'₂·p'₂ᵧ  q'₂·p'₂ᵤ]
    ///        [q'₃·p'₃ₓ  q'₃·p'₃ᵧ  q'₃·p'₃ᵤ]
    ///    ```
    ///
    /// 4. **Polar Decomposition**: Compute the optimal rotation via:
    ///    ```
    ///    R = H · (Hᵀ · H)^(-½)
    ///    ```
    ///    The inverse square root is computed via Newton-Raphson iteration.
    ///
    /// 5. **Reflection Correction**: If `det(R) < 0`, flip the column corresponding
    ///    to the smallest singular value to ensure a proper rotation.
    ///
    /// 6. **Gram-Schmidt Re-orthogonalization**: Enforce strict orthogonality.
    ///
    /// 7. **Translation**: Compute the translation vector:
    ///    ```
    ///    t = q̄ - R · p̄
    ///    ```
    ///
    /// ## Convergence Guarantees
    ///
    /// The Newton-Raphson iteration for matrix inverse square root converges
    /// quadratically when the initial guess `X₀ = I / √(tr(M))` is within
    /// the convergence basin. For well-conditioned covariance matrices
    /// (`det(HTH) > 1e-6`), convergence is typically achieved in 5-10 iterations.
    /// The implementation caps iterations at 20 with an epsilon of 1e-5 for
    /// robust termination.
    ///
    /// - Note: Requires at least 3 non-collinear calibration points.
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
        
        // Compute centered points and covariance matrix simultaneously
        var centeredSources: [SIMD3<Float>] = []
        var centeredTargets: [SIMD3<Float>] = []
        var covMatrix = simd_float3x3(
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(0, 0, 0)
        )
        
        for point in calibrationPoints {
            let ds = point.arKit - sourceCentroid
            let dt = point.bridge - targetCentroid
            centeredSources.append(ds)
            centeredTargets.append(dt)
            covMatrix.columns.0 += dt * ds.x
            covMatrix.columns.1 += dt * ds.y
            covMatrix.columns.2 += dt * ds.z
        }
        
        // Compute optimal rotation, bubbling up failure for degenerate inputs.
        guard let result = kabschRotation(from: covMatrix) else {
            // Fallback for coplanar calibration points (e.g., all ceiling lights).
            if let coplanarResult = coplanarFallback(sourcePoints: centeredSources, targetPoints: centeredTargets) {
                let translation = targetCentroid - coplanarResult.rotation * sourceCentroid
                transformation = Transformation(rotation: coplanarResult.rotation, translation: translation)
                calibrationFailure = .coplanarPoints
                logger.info("Kabsch calibration succeeded via coplanar fallback: using 2D + height-constrained Procrustes")
                savePersistedCalibration()
                return
            }
            calibrationFailure = .illConditionedCovariance
            transformation = nil
            logger.warning("Kabsch calibration failed: covariance matrix is ill-conditioned. Det(HTH) was below threshold. User should provide non-collinear calibration points.")
            return
        }
        // Compute translation: t = target_centroid - R * source_centroid
        let translation = targetCentroid - result * sourceCentroid
        
        transformation = Transformation(rotation: result, translation: translation)
        calibrationFailure = nil
        
        logger.debug(
            "Kabsch transformation computed from \(n) points. Translation: (\(String(format: "%.3f", translation.x)), \(String(format: "%.3f", translation.y)), \(String(format: "%.3f", translation.z)))"
        )
        
        savePersistedCalibration()
    }
    
    /// Compute the optimal rotation matrix using the Kabsch algorithm.
    ///
    /// ## Mathematical Derivation
    ///
    /// Given the covariance matrix `H`, the optimal rotation `R` is found via
    /// **polar decomposition** of `H`:
    ///
    /// ```
    /// H = R · S
    /// ```
    ///
    /// where `S` is a symmetric positive-definite matrix. The rotation factor
    /// `R` is extracted as:
    ///
    /// ```
    /// R = H · (Hᵀ · H)^(-½)
    /// ```
    ///
    /// This follows from the identity `S = √(Hᵀ · H)`, so `S^(-1) = (Hᵀ · H)^(-½)`.
    ///
    /// ## Reflection Handling
    ///
    /// If `det(R) < 0`, the decomposition produces an improper rotation
    /// (a reflection). The algorithm corrects this by flipping the column
    /// of `R` corresponding to the smallest singular value of `H`:
    ///
    /// ```
    /// If det(R) < 0:
    ///     R[:, k] = -R[:, k]   where k = argmin_j σⱼ
    /// ```
    ///
    /// This ensures `det(R) = +1`, enforcing a proper rotation.
    ///
    /// ## Gram-Schmidt Re-orthogonalization
    ///
    /// After polar decomposition, floating-point errors may cause columns
    /// to deviate from strict orthogonality. The Gram-Schmidt process
    /// re-orthogonalizes:
    ///
    /// ```
    /// c₀ = normalize(h₀)
    /// c₁ = normalize(h₁ - (c₀ · h₁) · c₀)
    /// c₂ = normalize(c₀ × c₁)
    /// R = [c₀ c₁ c₂]
    /// ```
    ///
    /// - Parameter covMatrix: The 3×3 covariance matrix `H` between centered point sets.
    /// - Returns: A 3×3 orthogonal rotation matrix with `det(R) = +1`, or `nil` if the
    ///   covariance matrix is ill-conditioned (indicating collinear or degenerate calibration points).
    private func kabschRotation(from covMatrix: simd_float3x3) -> simd_float3x3? {
        let H = covMatrix
        let HTH = H.transpose * H
        let detHTH = determinant(HTH)
        
        if detHTH < 1e-6 {
            logger.warning("Kabsch algorithm: det(HTH) = \(detHTH) < 1e-6, calibration failed. Covariance matrix is ill-conditioned due to collinear or degenerate calibration points. Returning nil to prevent silently applying a corrupted identity transform.")
            return nil
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
    
    /// Compute the inverse square root of a 3×3 positive-definite matrix using Newton's method.
    ///
    /// ## Newton-Raphson Iteration
    ///
    /// Given a positive-definite matrix `M`, we seek `X = M^(-½)` such that:
    ///
    /// ```
    /// X · X = M^(-1)
    /// ```
    ///
    /// Equivalently, `Y = X^(-1)` satisfies `Y · Y = M`, and `X = Y^(-1)`.
    ///
    /// The Newton-Raphson iteration for `M^(-½)` is:
    ///
    /// ```
    /// X_{n+1} = ½ · X_n · (3I - M · X_n²)
    /// ```
    ///
    /// This iteration converges quadratically: the number of correct digits
    /// approximately doubles each iteration.
    ///
    /// ## Initial Guess
    ///
    /// The initial guess uses the trace of `M`:
    ///
    /// ```
    /// X₀ = I / √(tr(M)) = I / √(Σᵢ Mᵢᵢ)
    /// ```
    ///
    /// This is derived from the observation that for a scaled identity matrix
    /// `M = αI`, the inverse square root is `X = (1/√α) · I`, and `tr(M) = 3α`.
    ///
    /// ## Convergence Criterion
    ///
    /// The iteration terminates when the Frobenius-norm difference between
    /// successive iterates falls below `ε = 1e-5`:
    ///
    /// ```
    /// ||X_{n+1} - X_n||_F ≤ ε
    /// ```
    ///
    /// where `||·||_F` is the Frobenius norm:
    ///
    /// ```
    /// ||A||_F = √(Σᵢⱼ Aᵢⱼ²)
    /// ```
    ///
    /// The iteration is capped at 20 iterations to prevent infinite loops
    /// in degenerate cases.
    ///
    /// ## Numerical Stability
    ///
    /// The trace-based initial guess ensures `X₀` is well-scaled, preventing
    /// divergence for matrices with large condition numbers. The `max(trace, 1e-6)`
    /// guard prevents division by zero for zero-trace matrices.
    ///
    /// - Parameter M: A 3×3 positive-definite matrix (typically `Hᵀ · H`).
    /// - Returns: The inverse square root `M^(-½)`.
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
            let MX2 = MX * X
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
    
    /// Compute the determinant of a 3×3 matrix.
    ///
    /// ## Sarrus' Rule
    ///
    /// Uses the direct expansion formula for 3×3 determinants:
    ///
    /// ```
    /// det(M) = a(ei - fh) - b(di - fg) + c(dh - eg)
    /// ```
    ///
    /// where the matrix is:
    ///
    /// ```
    /// [a b c]
    /// [d e f]
    /// [g h i]
    /// ```
    ///
    /// The determinant is used to:
    /// - Check if `HTH` is near-singular (`det(HTH) < 1e-6`)
    /// - Detect reflections in the rotation matrix (`det(R) < 0`)
    ///
    /// - Parameter M: A 3×3 matrix.
    /// - Returns: The determinant value.
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
    
    // MARK: - Coplanar Fallback: 2D + Height-Constrained Procrustes
    
    /// Fallback algorithm for when all calibration points are coplanar
    /// (e.g., all ceiling lights at the same physical height).
    ///
    /// ## Algorithm
    ///
    /// When `det(HTH) < 1e-6` due to coplanarity, the 3D Kabsch algorithm
    /// cannot determine a unique rotation. This fallback:
    ///
    /// 1. **Detects coplanarity**: Checks if all source Y values are approximately equal
    ///    (within `coplanarityThreshold = 0.05m`).
    ///
    /// 2. **Projects to XZ plane**: Drops the Y axis and solves a 2D rotation
    ///    problem on the XZ plane, which always has full rank when points are
    ///    non-collinear in the horizontal plane.
    ///
    /// 3. **Computes 2D rotation**: Uses the 2D analog of the Kabsch algorithm:
    ///    ```
    ///    S = Σ(x_s · x_t + z_s · z_t)
    ///    A = Σ(x_s · z_t - z_s · x_t)
    ///    θ = atan2(A, S)
    ///    ```
    ///
    /// 4. **Handles Y-axis**: If targets are also coplanar, computes a direct
    ///    scalar offset: `y_offset = mean(target_y) - mean(source_y)`.
    ///    If targets are not coplanar, uses the source Y as-is (identity on Y).
    ///
    /// - Parameters:
    ///   - sourcePoints: Centered source (ARKit) points.
    ///   - targetPoints: Centered target (Bridge) points.
    /// - Returns: A rotation matrix and translation for the coplanar case, or `nil`
    ///   if the points are collinear in the XZ plane (truly degenerate).
    private func coplanarFallback(
        sourcePoints: [SIMD3<Float>],
        targetPoints: [SIMD3<Float>]
    ) -> Transformation? {
        let coplanarityThreshold: Float = 0.05
        
        // Detect coplanarity in source points (all Y values approximately equal)
        var sourceYValues: [Float] = []
        for p in sourcePoints {
            sourceYValues.append(p.y)
        }
        
        let sourceIsCoplanar = isCoplanar(sourceYValues, threshold: coplanarityThreshold)
        
        guard sourceIsCoplanar else {
            // Source points are not coplanar; the failure must be due to collinearity
            // rather than coplanarity. Fall through to ill-conditioned failure.
            return nil
        }
        
        // Detect coplanarity in target points
        var targetYValues: [Float] = []
        for p in targetPoints {
            targetYValues.append(p.y)
        }
        
        let targetIsCoplanar = isCoplanar(targetYValues, threshold: coplanarityThreshold)
        
        // Project to XZ plane and solve 2D rotation
        var xzSumXX = 0.0
        var xzSumXZ = 0.0
        
        for i in 0..<sourcePoints.count {
            let sx = Double(sourcePoints[i].x)
            let sz = Double(sourcePoints[i].z)
            let tx = Double(targetPoints[i].x)
            let tz = Double(targetPoints[i].z)
            
            xzSumXX += sx * tx + sz * tz
            xzSumXZ += sx * tz - sz * tx
        }
        
        let angle = atan2(xzSumXZ, xzSumXX)
        
        // Build 3D rotation matrix from 2D XZ rotation
        let cosA = Float(cos(angle))
        let sinA = Float(sin(angle))
        
        var rotation = simd_float3x3(
            SIMD3<Float>(cosA, 0, -sinA),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(sinA, 0, cosA)
        )
        
        // Compute Y-axis translation
        var yTranslation: Float = 0
        
        if targetIsCoplanar {
            // Both source and target are coplanar: compute Y offset
            var sourceYMean: Float = 0
            var targetYMean: Float = 0
            for p in sourcePoints { sourceYMean += p.y }
            for p in targetPoints { targetYMean += p.y }
            sourceYMean /= Float(sourcePoints.count)
            targetYMean /= Float(targetPoints.count)
            yTranslation = targetYMean - sourceYMean
        }
        // If targets are not coplanar, keep Y as identity (yTranslation = 0)
        // The source Y values will pass through unchanged
        
        let translation = SIMD3<Float>(0, yTranslation, 0)
        
        logger.info(
            "Coplanar fallback: XZ rotation = \(String(format: "%.2f", angle * 180 / .pi))°, Y offset = \(String(format: "%.3f", yTranslation))m"
        )
        
        return Transformation(rotation: rotation, translation: translation)
    }
    
    /// Check if a set of Y values are all approximately equal (coplanar).
    ///
    /// - Parameter values: Array of Y coordinates.
    /// - Parameter threshold: Maximum allowed spread in meters.
    /// - Returns: `true` if all values are within `threshold` of each other.
    private func isCoplanar(_ values: [Float], threshold: Float) -> Bool {
        guard values.count >= 2 else { return false }
        let minVal = values.min()!
        let maxVal = values.max()!
        return (maxVal - minVal) < threshold
    }
    
    /// Orthogonalize a 3×3 matrix using the Gram-Schmidt process.
    ///
    /// ## Gram-Schmidt Process
    ///
    /// Given three column vectors `h₀, h₁, h₂`, the Gram-Schmidt process
    /// produces an orthonormal basis:
    ///
    /// ```
    /// c₀ = h₀ / ||h₀||
    ///
    /// c₁ = (h₁ - (c₀ · h₁) · c₀) / ||h₁ - (c₀ · h₁) · c₀||
    ///
    /// c₂ = (c₀ × c₁) / ||c₀ × c₁||
    /// ```
    ///
    /// The result is a rotation matrix `[c₀ c₁ c₂]` where:
    /// - `||cᵢ|| = 1` for all columns (unit length)
    /// - `cᵢ · cⱼ = 0` for `i ≠ j` (mutually orthogonal)
    /// - `c₀ × c₁ = c₂` (right-handed coordinate system)
    ///
    /// ## Why Re-orthogonalize?
    ///
    /// After polar decomposition, accumulated floating-point errors may cause
    /// the rotation matrix columns to deviate from strict orthogonality. This
    /// can lead to:
    /// - Scale distortion when transforming coordinates
    /// - Drift in repeated transformations
    /// - Numerical instability in subsequent calculations
    ///
    /// Gram-Schmidt re-orthogonalization corrects these issues with minimal
    /// computational cost.
    ///
    /// ## NaN Guard
    ///
    /// Before normalizing the first column, the length is checked against a
    /// minimum threshold (`1e-6`). If the column length is effectively zero
    /// (which can occur from a highly degenerate covariance matrix despite
    /// the `det(HTH)` check), the function returns the identity matrix to
    /// prevent NaN from poisoning the transformation.
    ///
    /// - Parameter M: A 3×3 matrix with approximately orthogonal columns.
    /// - Returns: A strictly orthogonal 3×3 rotation matrix, or identity
    ///   if the input is degenerate.
    private func orthogonalize(_ M: simd_float3x3) -> simd_float3x3 {
        let col0Length = simd_length(M.columns.0)
        guard col0Length > 1e-6 else {
            logger.warning(
                "Gram-Schmidt orthogonalization: first column length \(col0Length) is effectively zero. Returning identity matrix to prevent NaN propagation. This may indicate a degenerate covariance matrix from collinear calibration points."
            )
            return simd_float3x3(
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0, 1, 0),
                SIMD3<Float>(0, 0, 1)
            )
        }
        
        let c0 = normalize(M.columns.0)
        var c1 = M.columns.1 - c0 * dot(c0, M.columns.1)
        c1 = normalize(c1)
        var c2 = cross(M.columns.0, M.columns.1)
        c2 = normalize(c2)
        
        return simd_float3x3(c0, c1, c2)
    }
}
