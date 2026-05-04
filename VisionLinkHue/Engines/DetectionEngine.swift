import Foundation
import AVFoundation
import Vision
import ARKit
import CoreML
import os

/// Engine that performs on-device lighting fixture detection using
/// a hybrid approach: CoreML-based object recognition for architectural
/// lighting archetype classification (Chandelier, Sconce, Desk Lamp, etc.)
/// with fallback to Vision rectangle detection for broader coverage.
///
/// Throttles inference to `DetectionConstants.inferenceInterval` (500ms)
/// and applies non-maximum suppression to remove overlapping detections.
/// Adaptive inference frequency based on thermal state to prevent
/// device thermal throttling (which forces LiDAR shut-off).
///
/// Supports ARKit 2026 Neural Surface Synthesis for material-based
/// fixture classification (Glass, Metal, Wood, etc.) via ARMeshMaterialLabel.
@Observable
@MainActor
final class DetectionEngine {
    
    var lastDetections: [FixtureDetection] = []
    var isRunning: Bool = false
    var inferenceLatencyMs: Double = 0
    var frameCount: Int = 0
    var isCoreMLAvailable: Bool = false
    var isObjectDetectionActive: Bool = true
    
    /// Thermal state monitor for adaptive inference throttling.
    private let thermalMonitor: ThermalMonitor
    
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
    
    /// Intent-based classifier using CoreML for architectural archetype recognition.
    /// Overrides heuristic classification when CoreML confidence exceeds threshold.
    private var intentClassifier = CoreMLIntentClassifier()
    
    /// Neural surface material classifier for ARKit 2026 material detection.
    private let materialClassifier: NeuralSurfaceMaterialClassifier
    
    /// CoreML model for object detection (loaded lazily).
    private var objectDetectionModel: MLModel?
    
    /// Cached VNCoreMLRequest for object detection — created once when model loads.
    private var objectDetectionRequest: VNCoreMLRequest?
    
    /// Whether the CoreML object detection model has been loaded.
    private var isObjectModelLoaded: Bool = false
    
    /// Whether the model is using 4-bit weight quantization.
    var isModelQuantized: Bool = false
    
    /// Progress of model loading (0.0 to 1.0).
    var modelLoadingProgress: Double = 0.0
    
    /// Whether the model is currently being loaded.
    var isModelLoading: Bool = false
    
    /// Callback for model loading progress updates.
    private var onModelLoadingProgress: (@Sendable (Double) -> Void)?
    
    /// Initialize with material fixture mapping loaded from classification_rules.json.
    /// Optionally verifies an ECDSA signature for OTA config authenticity.
    /// - Parameters:
    ///   - onModelLoadingProgress: Callback for model loading progress updates.
    ///   - configSignature: Optional ECDSA signature for verifying config authenticity.
    ///   - configKeyID: Optional key identifier for multi-key rotation support.
    init(onModelLoadingProgress: (@Sendable (Double) -> Void)? = nil, configSignature: Data? = nil, configKeyID: String? = nil) {
        self.materialClassifier = NeuralSurfaceMaterialClassifier(
            materialFixtureMapping: NeuralSurfaceMaterialClassifier.loadMaterialMapping(signature: configSignature, keyID: configKeyID),
            materialIndexMapping: NeuralSurfaceMaterialClassifier.loadMaterialIndexMapping(signature: configSignature, keyID: configKeyID)
        )
        self.thermalMonitor = ThermalMonitor()
        self.onModelLoadingProgress = onModelLoadingProgress
        Task { await loadObjectDetectionModel() }
        Task { await loadIntentClassifierModel() }
    }
    
    /// Timestamp of the last inference pass (monotonic clock).
    private var lastInferenceInstant: ContinuousClock.Instant = .now
    
    /// Adaptive inference interval that adjusts based on thermal state.
    /// In Serious thermal states, throttles to 2x the base interval
    /// to protect LiDAR hardware from overheating.
    /// Uses effectiveThermalState which accounts for predictive
    /// throttling based on inference latency trends.
    private var currentInferenceInterval: TimeInterval {
        let state = thermalMonitor.effectiveThermalState
        switch state {
        case .nominal, .fair:
            return DetectionConstants.inferenceInterval
        case .warning:
            return DetectionConstants.inferenceInterval * 2.0
        case .serious, .critical:
            // Aggressive throttling in Serious states to protect LiDAR
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
        lastInferenceInstant = .now
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
    /// Uses CoreML object detection when available, falling back to
    /// rectangle detection for broader coverage.
    func processFrame(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) async throws -> [FixtureDetection] {
        guard isRunning else { return [] }
        
        let now = ContinuousClock.now
        let intervalMilliseconds = Int(currentInferenceInterval * 1000)
        guard now - lastInferenceInstant >= Duration.milliseconds(intervalMilliseconds) else {
            return []
        }
        lastInferenceInstant = now
        
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
        
        let detections = try await runHybridDetection(pixelBuffer, lowPower: useLowPower)
        
        let elapsed = ContinuousClock.now - start
        inferenceLatencyMs = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        
        // Update predictive thermal model with latency measurement for proactive throttling.
        thermalMonitor.updateWithLatency(inferenceLatencyMs)
        
        let filtered = detections.filter { $0.confidence >= minConfidence }
        
        await MainActor.run {
            self.lastDetections = filtered
        }
        
        if !filtered.isEmpty {
            let elapsedMs = Double(elapsed.components.seconds) * 1000.0 + Double(elapsed.components.attoseconds) / 1e12
            logger.debug("Detected \(filtered.count) fixture(s) in \(String(format: "%.1f", elapsedMs))ms")
        }
        
        return filtered
    }
    
    /// Update thermal state from the thermal monitor for adaptive throttling.
    private func updateThermalState() {
        _ = thermalMonitor.thermalState
    }
    
    // MARK: - CoreML Model Loading
    
    /// Load the CoreML object detection model for lighting archetype recognition.
    /// Uses a bundled model that classifies fixtures into architectural categories:
    /// Chandelier, Sconce, Desk Lamp, Pendant, Ceiling Light, Recessed Light, Strip Light.
    /// Asynchronously loads the model with progress reporting to avoid blocking the main thread.
    private func loadObjectDetectionModel() async {
        guard !isModelLoading else {
            logger.warning("Model loading already in progress")
            return
        }
        
        isModelLoading = true
        modelLoadingProgress = 0.0
        onModelLoadingProgress?(0.0)
        
        guard let modelURL = Bundle.main.url(forResource: "LightingArchetype", withExtension: "mlmodel"),
              let compiledModelURL = try? MLModel.compile(modelAt: modelURL) else {
            logger.warning("CoreML lighting archetype model not found, falling back to rectangle detection")
            isCoreMLAvailable = false
            isObjectModelLoaded = false
            isModelLoading = false
            modelLoadingProgress = 1.0
            onModelLoadingProgress?(1.0)
            return
        }
        
        modelLoadingProgress = 0.5
        onModelLoadingProgress?(0.5)
        
        do {
            let baseConfig = MLModelConfiguration()
            baseConfig.computeUnits = .all
            
            #if targetEnvironment(simulator)
            objectDetectionModel = try await Task.detached(priority: .userInitiated) {
                try MLModel(contentsOf: compiledModelURL, configuration: baseConfig)
            }.value
            isCoreMLAvailable = true
            isObjectModelLoaded = true
            isModelQuantized = false
            #else
            let quantizedConfig = MLModelConfiguration()
            quantizedConfig.computeUnits = .all
            quantizedConfig.weightsQuantization = .fourBit
            
            var loadedModel: MLModel?
            var quantizationApplied = false
            
            do {
                loadedModel = try await Task.detached(priority: .userInitiated) {
                    try MLModel(contentsOf: compiledModelURL, configuration: quantizedConfig)
                }.value
                quantizationApplied = true
            } catch {
                logger.debug("4-bit quantization not available for model, falling back to unquantized: \(error.localizedDescription)")
                loadedModel = try await Task.detached(priority: .userInitiated) {
                    try MLModel(contentsOf: compiledModelURL, configuration: baseConfig)
                }.value
                quantizationApplied = false
            }
            
            objectDetectionModel = loadedModel
            isCoreMLAvailable = true
            isObjectModelLoaded = true
            isModelQuantized = quantizationApplied
            
            if quantizationApplied {
                logger.info("CoreML lighting archetype model loaded with 4-bit weight quantization")
            } else {
                logger.info("CoreML lighting archetype model loaded (quantization unavailable, using full precision)")
            }
            #endif
            
            // Pre-create the VNCoreMLRequest to avoid per-frame allocation churn.
            guard let model = objectDetectionModel else {
                throw NSError(domain: "DetectionEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model was nil after loading"])
            }
            objectDetectionRequest = VNCoreMLRequest(model: model) { [weak self] request, error in
                if let error {
                    Logger(subsystem: "com.tomwolfe.visionlinkhue", category: "DetectionEngine")
                        .warning("CoreML object detection failed: \(error.localizedDescription)")
                }
            }
            objectDetectionRequest?.imageCropAndScaleOption = .scaleFill
            
        } catch {
            logger.warning("Failed to load CoreML model: \(error.localizedDescription)")
            isCoreMLAvailable = false
        }
        
        isModelLoading = false
        modelLoadingProgress = 1.0
        onModelLoadingProgress?(1.0)
    }
    
    /// Force reload the CoreML model (useful after app updates).
    func reloadObjectDetectionModel() {
        isModelLoading = true
        modelLoadingProgress = 0.0
        onModelLoadingProgress?(0.0)
        isObjectModelLoaded = false
        isModelQuantized = false
        objectDetectionModel = nil
        objectDetectionRequest = nil
        intentClassifier = CoreMLIntentClassifier()
        Task { await loadObjectDetectionModel() }
        Task { await loadIntentClassifierModel() }
    }
    
    /// Load the intent classifier CoreML model asynchronously.
    /// Runs in parallel with the object detection model loading.
    private func loadIntentClassifierModel() async {
        do {
            var classifier = intentClassifier
            try await classifier.loadModel()
            intentClassifier = classifier
            logger.info("Intent classifier model loaded successfully")
        } catch {
            logger.warning("Failed to load intent classifier model: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Hybrid Detection Pipeline
    
    /// Run the hybrid detection pipeline: CoreML object detection first,
    /// with rectangle detection as fallback when CoreML is unavailable
    /// or returns no high-confidence results.
    private func runHybridDetection(_ pixelBuffer: CVPixelBuffer, lowPower: Bool = false) async throws -> [FixtureDetection] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        
        var detections: [FixtureDetection] = []
        
        // Phase 1: CoreML object detection for architectural archetypes
        if isObjectDetectionActive, isCoreMLAvailable, isObjectModelLoaded, !lowPower {
            let objectDetections = try await runObjectDetection(handler: handler, pixelBuffer: pixelBuffer)
            detections.append(contentsOf: objectDetections)
        }
        
        // Phase 2: Rectangle detection as fallback / supplement
        // Always run rectangle detection to catch fixtures not covered by the object model
        // In low-power mode, use reduced confidence threshold to compensate
        let rectangleDetections = try await runRectangleDetection(handler: handler, lowPower: lowPower)
        
        // Merge detections, prioritizing CoreML results for overlapping regions
        detections = mergeDetections(detections, rectangleDetections: rectangleDetections)
        
        return detections
    }
    
    /// Run CoreML-based object detection for lighting archetypes.
    private func runObjectDetection(
        handler: VNImageRequestHandler,
        pixelBuffer: CVPixelBuffer
    ) async throws -> [FixtureDetection] {
        guard let model = objectDetectionModel else { return [] }
        guard let coreMLRequest = objectDetectionRequest else { return [] }
        
        let priority: TaskPriority = .userInitiated
        
        final class ObjectDetectionBox: @unchecked Sendable {
            let handler: VNImageRequestHandler
            let request: VNCoreMLRequest
            init(handler: VNImageRequestHandler, request: VNCoreMLRequest) {
                self.handler = handler
                self.request = request
            }
            func run() throws -> [ObservationData] {
                try handler.perform([request])
                guard let results = request.results as? [VNRecognizedObjectObservation] else {
                    return [ObservationData]()
                }
                return results.map { observation in
                    ObservationData(boundingBox: observation.boundingBox)
                }
            }
        }
        
        let box = ObjectDetectionBox(handler: handler, request: coreMLRequest)
        let observations = try await Task.detached(priority: priority, operation: { [box] in
            try box.run()
        }).value
        
        // Classify observations using intent classification (CoreML) with
        // heuristic fallback. Intent classification takes priority when
        // CoreML confidence exceeds the override threshold.
        return await classifyObjects(from: observations)
    }
    
    /// Run Vision rectangle detection as fallback.
    private func runRectangleDetection(handler: VNImageRequestHandler, lowPower: Bool) async throws -> [FixtureDetection] {
        let request = VNDetectRectanglesRequest()
        // Lower confidence threshold in low-power mode to compensate for reduced accuracy
        request.minimumConfidence = lowPower ? DetectionConstants.rectangleMinimumConfidence * 0.75
            : DetectionConstants.rectangleMinimumConfidence
        
        let priority: TaskPriority = lowPower ? .utility : .userInitiated
        
        final class RectangleDetectionBox: @unchecked Sendable {
            let handler: VNImageRequestHandler
            let request: VNDetectRectanglesRequest
            init(handler: VNImageRequestHandler, request: VNDetectRectanglesRequest) {
                self.handler = handler
                self.request = request
            }
            func run() throws -> [ObservationData] {
                try handler.perform([request])
                guard let results = request.results as? [VNRectangleObservation] else {
                    return [ObservationData]()
                }
                return results.map { ObservationData(boundingBox: $0.boundingBox) }
            }
        }
        
        let box = RectangleDetectionBox(handler: handler, request: request)
        let observations = try await Task.detached(priority: priority, operation: { [box] in
            try box.run()
        }).value
        
        return classifyFixtures(from: observations)
    }
    
    /// Merge CoreML object detections with rectangle detections.
    /// CoreML results take priority for overlapping regions.
    private func mergeDetections(
        _ objectDetections: [FixtureDetection],
        rectangleDetections: [FixtureDetection]
    ) -> [FixtureDetection] {
        // If we have high-confidence CoreML detections, use them preferentially
        let highConfidenceObjects = objectDetections.filter { $0.confidence >= 0.75 }
        
        if !highConfidenceObjects.isEmpty {
            // Remove rectangle detections that overlap with high-confidence CoreML results
            var keptRectangles: [FixtureDetection] = []
            for rect in rectangleDetections {
                var shouldKeep = true
                for obj in highConfidenceObjects {
                    let iou = obj.region.intersectionOverUnion(with: rect.region)
                    if iou > DetectionConstants.nmsIoUThreshold {
                        shouldKeep = false
                        break
                    }
                }
                if shouldKeep {
                    keptRectangles.append(rect)
                }
            }
            return highConfidenceObjects + keptRectangles
        }
        
        // No high-confidence CoreML results, use rectangle detections only
        return rectangleDetections
    }
    
    // MARK: - Object Classification
    
    /// Classify CoreML object detections into fixture types.
    /// CoreML archetype labels override heuristic classification when confidence is high.
    private func classifyObjects(from observations: [ObservationData]) async -> [FixtureDetection] {
        var detections: [FixtureDetection] = []
        
        for observation in observations {
            guard observation.boundingBox.minY < DetectionConstants.maxDetectionY else { continue }
            guard observation.boundingBox.width > DetectionConstants.minBoundingBoxSize && observation.boundingBox.height > DetectionConstants.minBoundingBoxSize else { continue }
            
            let region = NormalizedRect(
                topLeft: SIMD2<Float>(Float(observation.boundingBox.minX), Float(1.0 - observation.boundingBox.maxY)),
                bottomRight: SIMD2<Float>(Float(observation.boundingBox.maxX), Float(1.0 - observation.boundingBox.minY))
            )
            
            // Run intent classification via CoreML
            let intentResult = await intentClassifier.classify(observation)
            
            // Use intent classification when CoreML confidence is high enough
            // to override heuristic scoring, reducing false positives
            if CoreMLIntentClassifier.shouldOverrideHeuristics(confidence: intentResult.confidence) {
                let intentConfidence = intentResult.confidence + DetectionConstants.proximityBonus
                detections.append(FixtureDetection(
                    type: intentResult.type,
                    region: region,
                    confidence: min(intentConfidence, DetectionConstants.maxConfidence)
                ))
            } else {
                // Fall back to heuristic classification
                let type = classifier.classify(typeFrom: observation)
                let confidence = classifier.calculateConfidence(from: observation)
                detections.append(FixtureDetection(type: type, region: region, confidence: confidence))
            }
        }
        
        return nonMaxSuppression(detections, iouThreshold: DetectionConstants.nmsIoUThreshold)
    }
    
    /// Classify detected objects into fixture types using heuristic scoring.
    private func classifyFixtures(from observations: [ObservationData]) -> [FixtureDetection] {
        var detections: [FixtureDetection] = []
        
        for observation in observations {
            guard observation.boundingBox.minY < DetectionConstants.maxDetectionY else { continue }
            guard observation.boundingBox.width > DetectionConstants.minBoundingBoxSize && observation.boundingBox.height > DetectionConstants.minBoundingBoxSize else { continue }
            
            let region = NormalizedRect(
                topLeft: SIMD2<Float>(Float(observation.boundingBox.minX), Float(1.0 - observation.boundingBox.maxY)),
                bottomRight: SIMD2<Float>(Float(observation.boundingBox.maxX), Float(1.0 - observation.boundingBox.minY))
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
            
            for (j, other) in sorted.enumerated() where j > i {
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
    /// Optionally verifies an ECDSA signature for config authenticity.
    /// - Parameters:
    ///   - url: URL pointing to the JSON config file.
    ///   - signature: Optional ECDSA signature for verifying config authenticity.
    ///   - keyID: Optional key identifier for multi-key rotation support.
    /// - Throws: `ClassificationConfigError` if the config is invalid.
    func reloadRules(from url: URL, signature: Data? = nil, keyID: String? = nil) async throws {
        var c = classifier
        try await c.loadRules(from: url, signature: signature, keyID: keyID)
        classifier = c
        logger.info("Classification rules reloaded from \(url.path)")
    }
    
    /// Reset classifier rules to the bundled defaults.
    func resetRulesToDefaults() {
        classifier.resetToDefaults()
        logger.info("Classification rules reset to defaults")
    }
    
    // MARK: - Neural Surface Material Detection
    
    /// Classify fixture material using ARKit 2026 Neural Surface Synthesis.
    /// Samples material labels across the full detection region for robust
    /// classification. This handles fixtures with empty centers (ring-pendants,
    /// chandeliers) that would otherwise sample the background behind the fixture.
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
        
        if let region {
            return materialClassifier.sampleMaterial(region: region, materialLabel: materialLabel)
        } else {
            return materialClassifier.sampleMaterial(
                at: SIMD2<Float>(0.5, 0.5),
                in: frame,
                materialLabel: materialLabel
            )
        }
        #else
        return nil
        #endif
    }
}
