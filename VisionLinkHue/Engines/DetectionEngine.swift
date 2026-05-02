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
    
    /// Time between inference passes (500ms to avoid ANE backpressure).
    private let inferenceInterval: TimeInterval = 0.5
    
    /// Minimum confidence threshold for returning detections.
    private let minConfidence: Double = 0.6
    
    /// Request ID for Vision requests.
    private let requestID = UUID()
    
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
        guard now - lastInferenceTime >= inferenceInterval else {
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
        
        let request = VNDetectObjectsRequest()
        request.minimumConfidence = 0.3
        request.featureLevel = .v1
        
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
            
            let type = classifyFixtureType(from: observation)
            let confidence = calculateConfidence(from: observation)
            
            detections.append(FixtureDetection(type: type, region: region, confidence: confidence))
        }
        
        return nonMaxSuppression(detections, iouThreshold: 0.3)
    }
    
    /// Classify the fixture type using a weighted scoring system across
    /// aspect ratio, vertical position, and bounding box area.
    private func classifyFixtureType(from observation: VNRectangleObservation) -> FixtureType {
        let aspectRatio = observation.boundingBox.width / max(observation.boundingBox.height, 0.001)
        let normalizedY = observation.boundingBox.midpoint.y
        let area = observation.boundingBox.width * observation.boundingBox.height
        
        var scores: [FixtureType: Double] = [:]
        
        // Aspect ratio scoring
        switch aspectRatio {
        case 0.2...0.8:
            scores[.ceiling] += 3.0
            scores[.recessed] += 2.5
            scores[.pendant] += 1.0
        case 0.5...1.5:
            scores[.pendant] += 3.0
            scores[.lamp] += 2.5
            scores[.ceiling] += 1.0
        case 1.2...3.0:
            scores[.lamp] += 2.0
            scores[.pendant] += 1.5
        case 2.0...8.0:
            scores[.strip] += 4.0
            scores[.lamp] += 0.5
        default:
            scores[.lamp] += 1.0
        }
        
        // Vertical position scoring
        if normalizedY < 0.25 {
            scores[.ceiling] += 3.0
            scores[.pendant] += 2.0
            scores[.recessed] += 1.5
        } else if normalizedY < 0.5 {
            scores[.pendant] += 2.0
            scores[.recessed] += 2.0
            scores[.lamp] += 1.0
        } else if normalizedY < 0.75 {
            scores[.lamp] += 2.5
            scores[.recessed] += 2.0
            scores[.strip] += 0.5
        } else {
            scores[.lamp] += 3.0
            scores[.strip] += 1.5
        }
        
        // Area-based scoring
        if area > 0.15 {
            scores[.ceiling] += 1.5
            scores[.strip] += 1.0
        } else if area > 0.05 {
            scores[.pendant] += 1.0
            scores[.lamp] += 1.0
            scores[.recessed] += 1.0
        } else {
            scores[.recessed] += 1.5
            scores[.lamp] += 0.5
        }
        
        let sorted = scores.sorted { a, b in
            if a.value == b.value {
                let specificity: [FixtureType: Int] = [.ceiling: 4, .recessed: 3, .pendant: 2, .strip: 1, .lamp: 0]
                return specificity[a.key, default: 0] > specificity[b.key, default: 0]
            }
            return a.value > b.value
        }
        
        return sorted.first?.key ?? .lamp
    }
    
    /// Calculate detection confidence from observation quality.
    private func calculateConfidence(from observation: VNRectangleObservation) -> Double {
        var confidence: Double = 0.7
        
        let area = observation.boundingBox.width * observation.boundingBox.height
        if area > 0.01 && area < 0.5 {
            confidence += 0.15
        }
        if area > 0.05 && area < 0.3 {
            confidence += 0.05
        }
        
        let center = observation.boundingBox.midpoint
        let distanceFromCenter = sqrt(
            pow(center.x - 0.5, 2) + pow(center.y - 0.5, 2)
        )
        if distanceFromCenter < 0.3 {
            confidence += 0.05
        }
        
        return min(confidence, 0.99)
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
