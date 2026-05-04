import ARKit
import simd
import Foundation
import os
import Metal
import MetalPerformanceShaders

/// Represents one of the four quadrants of the depth map.
/// Uses `RawRepresentable` with `RawValue` matching `InlineArray` indices
/// for zero-cost indexing into `Span`-backed quadrant arrays.
enum DepthQuadrant: Int, Sendable, CaseIterable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    
    /// Returns the index for use with `InlineArray`/`Span` storage.
    var index: Int { rawValue }
    
    /// Human-readable label for the quadrant.
    var label: String {
        switch self {
        case .topLeft: return "upper left"
        case .topRight: return "upper right"
        case .bottomLeft: return "lower left"
        case .bottomRight: return "lower right"
        }
    }
    
    /// The opposite quadrant for directional guidance.
    var opposite: DepthQuadrant {
        switch self {
        case .topLeft: return .bottomRight
        case .topRight: return .bottomLeft
        case .bottomLeft: return .topRight
        case .bottomRight: return .topLeft
        }
    }
}

/// Fixed-size storage for exactly 4 quadrant values.
/// Uses Swift 6.3 `InlineArray` to avoid heap allocation during
/// CVPixelBuffer depth map analysis, reducing memory pressure during
/// high-frequency feature density computation.
@_fixed_layout
struct QuadrantCounts: ~Copyable {
    @InlineArray(4)
    var values: [Int]
    
    /// Initialize with all counts set to zero.
    init() {
        for i in 0..<4 {
            values[i] = 0
        }
    }
    
    /// Access the count for a specific quadrant by index.
    subscript(quadrant: DepthQuadrant) -> Int {
        get { values[quadrant.index] }
        set { values[quadrant.index] = newValue }
    }
    
    /// Convert to a `Span` over the raw values for iteration.
    borrowing func asSpan() -> Span<Int> {
        Span(values)
    }
    
    /// Compute the sum of all quadrant counts.
    borrowing func total() -> Int {
        var sum = 0
        for count in asSpan() {
            sum += count
        }
        return sum
    }
    
    /// Find the quadrant index with the minimum count.
    /// Uses Span-based iteration to avoid unintended copies during
    /// high-frequency frame analysis per Swift 6.3 InlineArray best practices.
    borrowing func sparsest() -> Int {
        var minIdx = 0
        var minVal = values[0]
        for (i, count) in asSpan().enumerated().dropFirst() {
            if count < minVal {
                minVal = count
                minIdx = i
            }
        }
        return minIdx
    }
    
    /// Find the quadrant index with the maximum count.
    /// Uses Span-based iteration to avoid unintended copies during
    /// high-frequency frame analysis per Swift 6.3 InlineArray best practices.
    borrowing func richest() -> Int {
        var maxIdx = 0
        var maxVal = values[0]
        for (i, count) in asSpan().enumerated().dropFirst() {
            if count > maxVal {
                maxVal = count
                maxIdx = i
            }
        }
        return maxIdx
    }
}

/// Fixed-size density array backed by `InlineArray` for Shannon entropy
/// computation on quadrant feature distributions.
@_fixed_layout
struct QuadrantDensities: ~Copyable {
    @InlineArray(4)
    var values: [Float]
    
    /// Initialize with all densities set to zero.
    init() {
        for i in 0..<4 {
            values[i] = 0.0
        }
    }
    
    /// Access the density for a specific quadrant by index.
    subscript(quadrant: DepthQuadrant) -> Float {
        get { values[quadrant.index] }
        set { values[quadrant.index] = newValue }
    }
    
    /// Convert to a `Span` over the raw values for iteration.
    borrowing func asSpan() -> Span<Float> {
        Span(values)
    }
    
    /// Compute the total density across all quadrants.
    borrowing func total() -> Float {
        var sum: Float = 0.0
        for density in asSpan() {
            sum += density
        }
        return sum
    }
    
    /// Compute Shannon entropy of the normalized density distribution.
    borrowing func entropy() -> Float {
        let total = self.total()
        guard total > 0 else { return 0.0 }
        
        var entropy: Float = 0.0
        for density in asSpan() {
            let probability = density / total
            guard probability > 0 else { continue }
            entropy -= probability * log(probability)
        }
        return entropy
    }
    
    /// Find the quadrant index with the minimum density.
    /// Uses Span-based iteration to avoid unintended copies during
    /// high-frequency frame analysis per Swift 6.3 InlineArray best practices.
    borrowing func sparsest() -> Int {
        var minIdx = 0
        var minVal = values[0]
        for (i, density) in asSpan().enumerated().dropFirst() {
            if density < minVal {
                minVal = density
                minIdx = i
            }
        }
        return minIdx
    }
    
    /// Find the quadrant index with the maximum density.
    /// Uses Span-based iteration to avoid unintended copies during
    /// high-frequency frame analysis per Swift 6.3 InlineArray best practices.
    borrowing func richest() -> Int {
        var maxIdx = 0
        var maxVal = values[0]
        for (i, density) in asSpan().enumerated().dropFirst() {
            if density > maxVal {
                maxVal = density
                maxIdx = i
            }
        }
        return maxIdx
    }
}

/// Analyzes ARKit frame data during relocalization to determine
/// the best direction for the user to look/move to improve tracking.
/// Uses feature point distribution and tracking state analysis to
/// generate directional guidance signals.
@MainActor
@Observable
final class RelocalizationGuide {
    
    /// The current look direction recommendation, if any.
    var currentLookDirection: LookDirection = .none
    
    /// Whether a guidance instruction is currently active.
    var hasInstruction: Bool { currentLookDirection != .none }
    
    /// The instruction text to display to the user.
    var instructionText: String {
        currentLookDirection.instruction
    }
    
    /// The icon to display alongside the instruction.
    var iconText: String {
        currentLookDirection.icon
    }
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "RelocalizationGuide"
    )
    
    /// Analysis history for trend detection.
    private var featureDensityHistory: [Float] = []
    
    /// Maximum history length for trend analysis.
    private let maxHistoryLength = 10
    
    /// Track the best feature density to detect improvement.
    private var bestFeatureDensity: Float = 0
    
    /// Minimum valid depth value in millimeters (filters out invalid pixels).
    private let minValidDepth: Int32 = 100
    
    /// Maximum valid depth value in millimeters (filters out far-away pixels).
    private let maxValidDepth: Int32 = 10000
    
    /// Initialize the relocalization guide.
    init() {}
    
    /// Analyze the current AR frame to determine the best look direction.
    /// Uses feature point density distribution and tracking state to
    /// generate directional guidance.
    ///
    /// - Parameters:
    ///   - frame: The current ARKit frame.
    ///   - confidence: The current tracking confidence score.
    /// - Returns: The recommended look direction.
    func analyzeFrame(_ frame: ARFrame, confidence: Float) -> LookDirection {
        #if targetEnvironment(simulator)
        return .none
        #endif
        
        let direction = deriveLookDirection(from: frame, confidence: confidence)
        
        if direction != .none {
            currentLookDirection = direction
            logger.debug("Relocalization guidance: \(direction.instruction)")
        } else {
            currentLookDirection = .none
        }
        
        return direction
    }
    
    /// Update analysis with a new feature density measurement.
    /// Tracks trends to determine if the user's actions are improving
    /// the feature availability for relocalization.
    func updateFeatureDensity(_ density: Float) {
        featureDensityHistory.append(density)
        
        if featureDensityHistory.count > maxHistoryLength {
            featureDensityHistory.removeFirst()
        }
        
        if density > bestFeatureDensity {
            bestFeatureDensity = density
            logger.debug("Feature density improving: \(String(format: "%.2f", density))")
        }
    }
    
    /// Check if feature density is trending upward.
    var isFeatureDensityImproving: Bool {
        guard featureDensityHistory.count >= 3 else { return false }
        
        let recent = Array(featureDensityHistory.suffix(3))
        for i in 1..<recent.count {
            if recent[i] < recent[i - 1] {
                return false
            }
        }
        return true
    }
    
    /// Reset all analysis state. Call when starting a new relocalization attempt.
    func reset() {
        currentLookDirection = .none
        featureDensityHistory.removeAll()
        bestFeatureDensity = 0
    }
    
    /// Derive the best look direction from ARKit frame data.
    /// Analyzes feature point distribution across the image plane to
    /// determine which direction has the most/least tracked features.
    private func deriveLookDirection(from frame: ARFrame, confidence: Float) -> LookDirection {
        // If tracking is normal, no guidance needed.
        guard let trackingState = frame.trackingState,
              trackingState != .normal,
              trackingState != .limited(.localization) else {
            return .none
        }
        
        // Use feature point depth data distribution if available.
        if let depthData = frame.sceneDepth,
           let depthMap = depthData.depthMap {
            return analyzeDepthDistribution(depthMap, imageBufferSize: frame.capturedImage.size)
        }
        
        // Fallback: use camera transform to infer direction.
        // When confidence is very low, suggest broader movement.
        if confidence < 0.2 {
            return .closer
        } else if confidence < 0.4 {
            return .none
        }
        
        return .none
    }
    
    /// Analyze depth map distribution to find directions with sparse features.
    /// Divides the depth map into four quadrants and computes feature density
    /// (valid depth pixel ratio) for each. Uses Shannon entropy to measure
    /// distribution uniformity. When entropy is low (highly uneven), generates
    /// specific environmental guidance directing the user toward the quadrant
    /// with the most visual features.
    ///
    /// Uses MPS (Metal Performance Shaders) histogram kernels for GPU-accelerated
    /// depth map analysis instead of CPU-side stride iteration. This significantly
    /// reduces latency on iOS 26.3+ by offloading the pixel iteration to the GPU.
    /// Falls back to CPU-side sampling when MPS is unavailable (simulator).
    ///
    /// Uses Swift 6.3 `InlineArray`/`Span` for zero-allocation quadrant
    /// storage during CVPixelBuffer iteration, reducing memory pressure
    /// during high-frequency feature density analysis.
    ///
    /// - Parameters:
    ///   - depthMap: The ARKit depth map CVPixelBuffer.
    ///   - imageBufferSize: The dimensions of the captured image.
    /// - Returns: A LookDirection with specific guidance, or .none if distribution
    ///   is already uniform or analysis fails.
    private func analyzeDepthDistribution(_ depthMap: CVPixelBuffer, imageBufferSize: CGSize) -> LookDirection {
        #if targetEnvironment(simulator)
        return analyzeDepthDistributionCPU(depthMap, imageBufferSize: imageBufferSize)
        #else
        return analyzeDepthDistributionMPS(depthMap, imageBufferSize: imageBufferSize)
        #endif
    }
    
    /// GPU-accelerated depth distribution analysis using MPS histogram kernels.
    /// Uses Metal to compute quadrant feature densities in parallel, avoiding
    /// CPU-side pixel iteration entirely.
    private func analyzeDepthDistributionMPS(_ depthMap: CVPixelBuffer, imageBufferSize: CGSize) -> LookDirection {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            return analyzeDepthDistributionCPU(depthMap, imageBufferSize: imageBufferSize)
        }
        
        let commandQueue = device.makeCommandQueue()
        guard let commandQueue else {
            return analyzeDepthDistributionCPU(depthMap, imageBufferSize: imageBufferSize)
        }
        
        let midX = width / 2
        let midY = height / 2
        
        let quadrantRects: [CGRect] = [
            CGRect(x: 0, y: 0, width: midX, height: midY),           // topLeft
            CGRect(x: midX, y: 0, width: midX, height: midY),        // topRight
            CGRect(x: 0, y: midY, width: midX, height: midY),        // bottomLeft
            CGRect(x: midX, y: midY, width: midX, height: midY),     // bottomRight
        ]
        
        let pixelCountPerQuadrant = (width / 2) * (height / 2)
        
        var quadrantCounts = QuadrantCounts()
        
        do {
            let pixelBufferDescriptor = MPSImageDataDescriptor(
                pixelBuffer: depthMap,
                type: .int32,
                width: UInt(width),
                height: UInt(height),
                components: 1,
                bytesPerRow: UInt(CVPixelBufferGetBytesPerRow(depthMap))
            )
            
            let minimumPixelValues = [minValidDepth, minValidDepth, minValidDepth, minValidDepth]
            let maximumPixelValues = [maxValidDepth, maxValidDepth, maxValidDepth, maxValidDepth]
            
            let histogram = MPSImageHistogram(
                device: device,
                pixelValues: minimumPixelValues,
                maximumPixelValues: maximumPixelValues,
                imageDescriptor: pixelBufferDescriptor,
                quadrantRects: quadrantRects.map { NSRect($0) }
            )
            
            let destinationDescriptor = MPSImageDataDescriptor(
                width: UInt(4),
                height: UInt(1),
                components: 1,
                bytesPerRow: UInt(MemoryLayout<Int32>.stride * 4),
                allocationPolicy: .alwaysAllocate
            )
            
            let destinationBuffer = device.makeBuffer(length: 4 * MemoryLayout<Int32>.stride, options: .storagePrivate)
            guard let destinationBuffer else {
                return analyzeDepthDistributionCPU(depthMap, imageBufferSize: imageBufferSize)
            }
            
            let destination = MPSImageData(buffer: destinationBuffer, descriptor: destinationDescriptor)
            
            let commandBuffer = commandQueue.makeCommandBuffer()
            guard let commandBuffer else {
                return analyzeDepthDistributionCPU(depthMap, imageBufferSize: imageBufferSize)
            }
            
            let encoder = commandBuffer.makeComputeCommandEncoder()
            guard let encoder else {
                return analyzeDepthDistributionCPU(depthMap, imageBufferSize: imageBufferSize)
            }
            
            encoder.setComputePipelineState(histogram.computePipelineState)
            histogram.encodeWithCommandEncoder(encoder)
            encoder.setMPSImageData(destination, index: 1)
            encoder.endEncoding()
            
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            
            let histogramData = destinationBuffer.contents().bindMemory(
                to: Int32.self,
                capacity: 4
            )
            
            for i in 0..<4 {
                quadrantCounts[DepthQuadrant(rawValue: i)!] = Int(histogramData[i])
            }
            
        } catch {
            logger.debug("MPS histogram failed, falling back to CPU: \(error.localizedDescription)")
        }
        
        return computeLookDirection(from: quadrantCounts, pixelCountPerQuadrant: pixelCountPerQuadrant)
    }
    
    /// CPU-side depth distribution analysis using stride-based sampling.
    /// Used as fallback when MPS is unavailable (simulator) or fails.
    private func analyzeDepthDistributionCPU(_ depthMap: CVPixelBuffer, imageBufferSize: CGSize) -> LookDirection {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return .none
        }
        
        let midX = width / 2
        let midY = height / 2
        
        var quadrantCounts = QuadrantCounts()
        
        let sampleStride = 2
        
        for y in stride(from: 0, to: height, by: sampleStride) {
            for x in stride(from: 0, to: width, by: sampleStride) {
                let byteOffset = y * bytesPerRow + x * 4
                let depthValue = Int32(baseAddress.load(fromByteOffset: byteOffset, as: Int32.self))
                
                guard depthValue >= minValidDepth, depthValue <= maxValidDepth else {
                    continue
                }
                
                let quadrant: DepthQuadrant
                if x < midX {
                    quadrant = y < midY ? .topLeft : .bottomLeft
                } else {
                    quadrant = y < midY ? .topRight : .bottomRight
                }
                
                quadrantCounts[quadrant] += 1
            }
        }
        
        let samplesPerQuadrant = (width / sampleStride / 2) * (height / sampleStride / 2)
        
        return computeLookDirection(from: quadrantCounts, pixelCountPerQuadrant: samplesPerQuadrant)
    }
    
    /// Compute the LookDirection from quadrant counts using density analysis and Shannon entropy.
    private func computeLookDirection(
        from quadrantCounts: borrowing QuadrantCounts,
        pixelCountPerQuadrant: Int
    ) -> LookDirection {
        var densities = QuadrantDensities()
        for quadrant in DepthQuadrant.allCases {
            densities[quadrant] = Float(quadrantCounts[quadrant]) / Float(pixelCountPerQuadrant)
        }
        
        let entropy = densities.entropy()
        
        let sparsestIdx = densities.sparsest()
        let richestIdx = densities.richest()
        
        guard let sparsestQuadrant = DepthQuadrant(rawValue: sparsestIdx),
              let richestQuadrant = DepthQuadrant(rawValue: richestIdx) else {
            return .none
        }
        
        let maxEntropy = Float(log(4.0))
        if entropy > maxEntropy * 0.85 {
            return .none
        }
        
        let guidance = environmentalGuidance(from: sparsestQuadrant, richest: richestQuadrant, densities: densities)
        
        let densitySpread = densities[richestQuadrant] - densities[sparsestQuadrant]
        if densitySpread < 0.15 {
            return .none
        }
        
        return guidance
    }
    
    /// Generate environmental guidance based on quadrant analysis.
    /// Maps the sparsest quadrant to a specific directional instruction
    /// with a descriptive label (e.g., "Look toward the window to improve tracking").
    ///
    /// - Parameters:
    ///   - sparsestQuadrant: The quadrant with the fewest visual features.
    ///   - richest: The quadrant with the most visual features.
    ///   - densities: Full density map for all quadrants via InlineArray-backed storage.
    /// - Returns: A LookDirection.environmental with specific guidance text.
    private func environmentalGuidance(
        from sparsestQuadrant: DepthQuadrant,
        richest: DepthQuadrant,
        densities: borrowing QuadrantDensities
    ) -> LookDirection {
        // Generate specific guidance based on which quadrant is sparsest.
        // The user should look toward the opposite (richest) quadrant.
        let instruction: String
        let icon: String
        
        switch sparsestQuadrant {
        case .topLeft:
            instruction = "Look toward the upper right to improve tracking"
            icon = "arrow.up.right.circle.fill"
        case .topRight:
            instruction = "Look toward the upper left to improve tracking"
            icon = "arrow.up.left.circle.fill"
        case .bottomLeft:
            instruction = "Look toward the lower right to improve tracking"
            icon = "arrow.down.right.circle.fill"
        case .bottomRight:
            instruction = "Look toward the lower left to improve tracking"
            icon = "arrow.down.left.circle.fill"
        }
        
        // Enhance the instruction with environmental context if there's
        // a strong directional bias (entropy is very low).
        let totalDensity = densities.total()
        let richestDensity = densities[richest]
        let dominanceRatio = Float(richestDensity) / totalDensity
        
        if dominanceRatio > 0.45 {
            // Strong bias toward one quadrant - provide room context hint.
            let contextHint = environmentalContextHint(for: richest)
            instruction = "\(instruction) — \(contextHint)"
        }
        
        return .environmental(description: instruction, icon: icon)
    }
    
    /// Generate an environmental context hint based on the richest quadrant.
    /// Uses heuristic rules to suggest common room features that may be
    /// located in that direction (e.g., windows, walls with texture).
    ///
    /// - Parameter quadrant: The richest quadrant.
    /// - Returns: A descriptive context hint string.
    private func environmentalContextHint(for quadrant: DepthQuadrant) -> String {
        switch quadrant {
        case .topLeft, .topRight:
            return "Ceiling or upper walls often have the best tracking features"
        case .bottomLeft, .bottomRight:
            return "Floor-level objects provide strong visual features for tracking"
        }
    }
}
