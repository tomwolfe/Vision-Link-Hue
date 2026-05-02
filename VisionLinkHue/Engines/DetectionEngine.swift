import Foundation
import AVFoundation
import Vision
import os

/// Engine that performs on-device lighting fixture detection using
/// the Vision framework for bounding box detection and heuristic
/// classification based on aspect ratio, vertical position, and area.
final class DetectionEngine: ObservableObject {
    
    @Published var lastDetections: [FixtureDetection] = []
    @Published var isRunning: Bool = false
    @Published var inferenceLatencyMs: Double = 0
    @Published var frameCount: Int = 0
    
    private let logger = Logger(subsystem: "com.tomwolfe.visionlinkhue", category: "DetectionEngine")
    
    /// Minimum confidence threshold for returning detections.
    private let minConfidence: Double = DetectionConstants.minConfidence
    
    /// Request ID for Vision requests.
    private let requestID = UUID()
    
    /// Heuristic classifier for fixture type and confidence.
    private let classifier = FixtureHeuristicClassifier()
    
    /// Timestamp of the last inference pass.
    private var lastInferenceTime: CFAbsoluteTime = 0
    
    // MARK: - Public API
    
    /// Start continuous detection. Call from the AR session observer.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        frameCount = 0
        lastInferenceTime = 0
        logger.info("DetectionEngine started")
    }
    
    /// Stop continuous detection.
    func stop() {
        isRunning = false
        lastDetections = []
        logger.info("DetectionEngine stopped")
    }
    
    /// Process a single AR frame and return detections.
    /// Returns immediately if called within the inference interval.
    func processFrame(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) async throws -> [FixtureDetection] {
        guard isRunning else { return [] }
        
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastInferenceTime >= DetectionConstants.inferenceInterval else {
            return []
        }
        lastInferenceTime = now
        
        let start = now
        frameCount += 1
        
        let detections = try await runVisionDetection(pixelBuffer)
        
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        inferenceLatencyMs = elapsed
        
        let filtered = detections.filter { $0.confidence >= minConfidence }
        
        await MainActor.run {
            self.lastDetections = filtered
        }
        
        if !filtered.isEmpty {
            logger.debug("Detected \(filtered.count) fixture(s) in \(String(format: "%.1f", elapsed))ms")
        }
        
        return filtered
    }
    
    // MARK: - Vision Detection
    
    private func runVisionDetection(_ pixelBuffer: CVPixelBuffer) async throws -> [FixtureDetection] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.2
        request.maximumOutputCount = 20
        request.quadTolerance = 0.1
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[FixtureDetection], Error>) in
            Task.detached(priority: .userInitiated) {
                do {
                    try handler.perform([request])
                    
                    guard let results = request.results as? [VNRectangleObservation] else {
                        continuation.resume(returning: [])
                        return
                    }
                    
                    let detections = self.classifyFixtures(from: results)
                    continuation.resume(returning: detections)
                } catch {
                    self.logger.error("Vision detection failed: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Classify detected objects into fixture types using heuristic scoring.
    private func classifyFixtures(from observations: [VNRectangleObservation]) -> [FixtureDetection] {
        var detections: [FixtureDetection] = []
        
        for observation in observations {
            // Only consider objects in the upper portion of the frame
            // (lighting fixtures are typically on walls/ceilings)
            guard observation.boundingBox.minY < 0.8 else { continue }
            guard observation.boundingBox.width > 0.05 && observation.boundingBox.height > 0.05 else { continue }
            
            let region = NormalizedRect(
                topLeft: SIMD2<Float>(Float(observation.boundingBox.minX), Float(observation.boundingBox.minY)),
                bottomRight: SIMD2<Float>(Float(observation.boundingBox.maxX), Float(observation.boundingBox.maxY))
            )
            
            let type = classifier.classify(typeFrom: observation)
            let confidence = classifier.calculateConfidence(from: observation)
            
            detections.append(FixtureDetection(type: type, region: region, confidence: confidence))
        }
        
        return nonMaxSuppression(detections, iouThreshold: 0.3)
    }
    

    
    /// Non-maximum suppression to remove overlapping detections.
    private func nonMaxSuppression(
        _ detections: [FixtureDetection],
        iouThreshold: Float
    ) -> [FixtureDetection] {
        guard !detections.isEmpty else { return [] }
        
        var sorted = detections.sorted { $0.confidence > $1.confidence }
        var keep: [FixtureDetection] = []
        var suppressed = Set<UUID>()
        
        for (i, detection) in sorted.enumerated() {
            guard !suppressed.contains(detection.id) else { continue }
            
            keep.append(detection)
            
            for (j, other) in sorted.enumerated() where i != j {
                guard !suppressed.contains(other.id) else { continue }
                
                let iou = calculateIoU(detection.region, other.region)
                if iou > iouThreshold {
                    suppressed.insert(other.id)
                }
            }
        }
        
        return keep
    }
    
    /// Calculate Intersection over Union between two normalized rects.
    private func calculateIoU(_ a: NormalizedRect, _ b: NormalizedRect) -> Float {
        let interX1 = max(a.topLeft.x, b.topLeft.x)
        let interY1 = max(a.topLeft.y, b.topLeft.y)
        let interX2 = min(a.bottomRight.x, b.bottomRight.x)
        let interY2 = min(a.bottomRight.y, b.bottomRight.y)
        
        let interWidth = max(0, interX2 - interX1)
        let interHeight = max(0, interY2 - interY1)
        let intersection = interWidth * interHeight
        
        let areaA = a.width * a.height
        let areaB = b.width * b.height
        let union = areaA + areaB - intersection
        
        return union > 0 ? intersection / Float(union) : 0
    }
}
