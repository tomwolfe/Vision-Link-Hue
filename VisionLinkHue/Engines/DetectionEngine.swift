import Foundation
import AVFoundation
import Vision
import ARKit
import os

/// Engine that performs on-device lighting fixture detection using
/// the Vision framework for bounding box detection and heuristic
/// classification based on aspect ratio, vertical position, and area.
///
/// Throttles inference to `DetectionConstants.inferenceInterval` (500ms)
/// and applies non-maximum suppression to remove overlapping detections.
///
/// Supports ARKit 2026 Neural Surface Synthesis for material-based
/// fixture classification (Glass, Metal, Wood, etc.) via ARMeshMaterialLabel.
/// Uses low-power mode to prevent thermal throttling on device.
@Observable
@MainActor
final class DetectionEngine {
    
    var lastDetections: [FixtureDetection] = []
    var isRunning: Bool = false
    var inferenceLatencyMs: Double = 0
    var frameCount: Int = 0
    
    /// Thermal state monitor for adaptive inference throttling.
    private let thermalMonitor = ThermalMonitor()
    
    /// Current thermal state of the device for adaptive inference throttling.
    var thermalState: ThermalState { thermalMonitor.thermalState }
    
    /// Whether low-power AR mode is active to prevent thermal throttling.
    var isLowPowerMode: Bool = false
    
    private let logger = Logger(subsystem: "com.tomwolfe.visionlinkhue", category: "DetectionEngine")
    
    /// Minimum confidence threshold for returning detections.
    private let minConfidence: Double = DetectionConstants.minConfidence
    
    /// Request ID for Vision requests.
    private let requestID = UUID()
    
    /// Heuristic classifier for fixture type and confidence.
    private var classifier = FixtureHeuristicClassifier()
    
    /// Neural surface material classifier for ARKit 2026 material detection.
    private let materialClassifier: NeuralSurfaceMaterialClassifier
    
    /// Initialize with material fixture mapping loaded from classification_rules.json.
    init() {
        self.materialClassifier = NeuralSurfaceMaterialClassifier(
            materialFixtureMapping: NeuralSurfaceMaterialClassifier.loadMaterialMapping()
        )
    }
    
    /// Timestamp of the last inference pass.
    private var lastInferenceTime: CFAbsoluteTime = 0
    
    /// Adaptive inference interval that adjusts based on thermal state.
    private var currentInferenceInterval: TimeInterval {
        switch thermalState {
        case .nominal, .fair:
            return DetectionConstants.inferenceInterval
        case .warning:
            return DetectionConstants.inferenceInterval * 2.0
        case .serious, .critical:
            return DetectionConstants.inferenceInterval * 4.0
        }
    }
    
    /// Background task for monitoring thermal state changes on iOS.
    private var thermalMonitoringTask: Task<Void, Never>?
    
    // MARK: - Public API
    
    /// Start continuous detection. Call from the AR session observer.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        frameCount = 0
        lastInferenceTime = 0
        logger.info("DetectionEngine started")
        thermalMonitor.start()
    }
    
    /// Stop continuous detection.
    func stop() {
        isRunning = false
        lastDetections = []
        thermalMonitor.stop()
        logger.info("DetectionEngine stopped")
    }
    
    /// Process a single AR frame and return detections.
    /// Returns immediately if called within the inference interval.
    /// Adapts inference frequency based on thermal state to prevent
    /// device thermal throttling (which forces LiDAR shut-off).
    func processFrame(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) async throws -> [FixtureDetection] {
        guard isRunning else { return [] }
        
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastInferenceTime >= currentInferenceInterval else {
            return []
        }
        lastInferenceTime = now
        
        let start = now
        frameCount += 1
        
        // Update thermal state for adaptive throttling
        updateThermalState()
        
        // Enable low-power mode when thermal state is warning or worse
        let useLowPower = thermalState >= .warning
        if useLowPower != isLowPowerMode {
            isLowPowerMode = useLowPower
            if useLowPower {
                logger.info("Low-power detection mode enabled (thermal state: \(self.thermalState))")
            }
        }
        
        let detections = try await runVisionDetection(pixelBuffer, lowPower: useLowPower)
        
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
    
    /// Update thermal state from the thermal monitor for adaptive throttling.
    private func updateThermalState() {
        _ = thermalMonitor.thermalState
    }
    
    // MARK: - Vision Detection
    
    private func runVisionDetection(_ pixelBuffer: CVPixelBuffer, lowPower: Bool = false) async throws -> [FixtureDetection] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = DetectionConstants.rectangleMinimumConfidence
        
        // Use structured concurrency with Task for proper cancellation support.
        // In low-power mode, lower the task priority to reduce CPU/GPU load
        // and prevent thermal throttling that forces LiDAR shut-off.
        let priority: TaskPriority = lowPower ? .utility : .userInitiated
        
        return try await Task(priority: priority) {
            try handler.perform([request])
            
            guard let results = request.results as? [VNRectangleObservation] else {
                return []
            }
            
            let observations = results.map { ObservationData(boundingBox: $0.boundingBox) }
            return await classifyFixtures(from: observations)
        }.value
    }
    
    /// Classify detected objects into fixture types using heuristic scoring.
    private func classifyFixtures(from observations: [ObservationData]) -> [FixtureDetection] {
        var detections: [FixtureDetection] = []
        
        for observation in observations {
            guard observation.boundingBox.minY < DetectionConstants.maxDetectionY else { continue }
            guard observation.boundingBox.width > DetectionConstants.minBoundingBoxSize && observation.boundingBox.height > DetectionConstants.minBoundingBoxSize else { continue }
            
            let region = NormalizedRect(
                topLeft: SIMD2<Float>(Float(observation.boundingBox.minX), Float(observation.boundingBox.minY)),
                bottomRight: SIMD2<Float>(Float(observation.boundingBox.maxX), Float(observation.boundingBox.maxY))
            )
            
            let type = classifier.classify(typeFrom: observation)
            let confidence = classifier.calculateConfidence(from: observation)
            
            detections.append(FixtureDetection(type: type, region: region, confidence: confidence))
        }
        
        return nonMaxSuppression(detections, iouThreshold: DetectionConstants.nmsIoUThreshold)
    }
    
    /// Non-maximum suppression to remove overlapping detections.
    func nonMaxSuppression(
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
                
                let iou = detection.region.intersectionOverUnion(with: other.region)
                if iou > iouThreshold {
                    suppressed.insert(other.id)
                }
            }
        }
        
        return keep
    }
    
    // MARK: - Classifier Rules
    
    /// Reload classification rules from a JSON config file.
    /// Enables OTA updates to detection logic without recompiling.
    /// - Parameter url: URL pointing to the JSON config file.
    /// - Throws: `ClassificationConfigError` if the config is invalid.
    func reloadRules(from url: URL) throws {
        try classifier.loadRules(from: url)
        logger.info("Classification rules reloaded from \(url.path)")
    }
    
    /// Reset classifier rules to the bundled defaults.
    func resetRulesToDefaults() {
        classifier.resetToDefaults()
        logger.info("Classification rules reset to defaults")
    }
    
    // MARK: - Neural Surface Material Detection
    
    /// Classify fixture material using ARKit 2026 Neural Surface Synthesis.
    /// Samples material labels from the detection region's center and
    /// surrounding area for robust classification.
    /// Returns material labels like "Glass", "Metal", "Wood" based on
    /// the ARMeshMaterialLabel of the detected surface.
    func classifyMaterial(from frame: ARFrame, at region: NormalizedRect? = nil) -> String? {
        #if !targetEnvironment(simulator)
        guard let sceneDepth = frame.sceneDepth else {
            return nil
        }
        guard let materialLabel = sceneDepth.materialLabel else {
            return nil
        }
        
        let samplePoint: SIMD2<Float>
        if let region {
            samplePoint = region.center
        } else {
            samplePoint = SIMD2<Float>(0.5, 0.5)
        }
        
        return materialClassifier.sampleMaterial(at: samplePoint, in: frame, materialLabel: materialLabel)
        #else
        return nil
        #endif
    }
}

