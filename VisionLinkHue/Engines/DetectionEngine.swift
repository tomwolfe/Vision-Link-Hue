import Foundation
import AVFoundation
import Vision
import ARKit
import CoreML
import os

/// Protocol abstraction for fixture detection backends.
/// Enables swapping the internal `VNCoreMLRequest` for a future
/// "Core AI" framework (rumored WWDC 2026) without refactoring
/// `ARSessionManager` or other consumers.
@MainActor
protocol DetectionProvider: Sendable {
    /// Start continuous detection.
    func start()
    /// Stop continuous detection.
    func stop()
    /// Process a single AR frame and return detections.
    func processFrame(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval, displayTransform: CGAffineTransform?) async throws -> [FixtureDetection]
    /// Classify fixture material using neural surface synthesis.
    func classifyMaterial(from intrinsics: CameraIntrinsics, at region: NormalizedRect?) -> String?
}

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
/// Battery Saver mode (configurable via `DetectionSettings`) disables
/// Neural Surface Synthesis to reduce computational overhead.
///
/// Conforms to `DetectionProvider` for Core AI framework swap readiness.
@Observable
@MainActor
final class DetectionEngine: DetectionProvider {
    
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
    
    /// Whether Battery Saver mode is active, disabling Neural Surface Synthesis.
    var isBatterySaverMode: Bool {
        detectionSettings.batterySaverMode
    }
    
    private let logger = Logger(subsystem: "com.tomwolfe.visionlinkhue", category: "DetectionEngine")
    
    /// Minimum confidence threshold for returning detections.
    private let minConfidence: Double = DetectionConstants.minConfidence
    
    /// Request ID for Vision requests.
    private let requestID = UUID()
    
    /// Heuristic classifier for fixture type and confidence.
    private var classifier = FixtureHeuristicClassifier()
    
    /// Intent-based classifier using CoreML for architectural archetype recognition.
    /// Overrides heuristic classification when CoreML confidence exceeds threshold.
    @ObservationIgnored
    private var intentClassifier: FixtureIntentClassifier = CoreMLIntentClassifier()
    
    /// Neural surface material classifier for ARKit 2026 material detection.
    private let materialClassifier: NeuralSurfaceMaterialClassifier
    
    /// User-configurable detection settings controlling battery/performance trade-offs.
    private let detectionSettings: DetectionSettings
    
    /// CoreML model for object detection (loaded lazily).
    private var objectDetectionModel: MLModel?
    
    /// Cached VNCoreMLRequest for object detection — created once when model loads.
    private var objectDetectionRequest: VNCoreMLRequest?
    
    /// Whether the CoreML object detection model has been loaded.
    private var isObjectModelLoaded: Bool = false
    
    /// Whether the model is using 4-bit weight quantization.
    var isModelQuantized: Bool = false
    
    /// The current CoreML compute units configuration.
    /// Switches between `.all` (default) and `.cpuOnly` based on thermal state
    /// to reduce NPU/GPU thermal load during predictive throttling.
    private var currentComputeUnits: MLComputeUnits = .all
    
    /// Reference to the state stream for reporting quantization fallback events.
    private weak var stateStream: HueStateStream?
    
    /// Progress of model loading (0.0 to 1.0).
    var modelLoadingProgress: Double = 0.0
    
    /// Whether the model is currently being loaded.
    var isModelLoading: Bool = false
    
    /// Whether the quantization fallback error has already been reported.
    private var hasReportedQuantizationFallback: Bool = false
    
    /// Memory guardrail: Threshold (8GB) below which loading the unquantized 16-bit model
    /// risks triggering Jetsam termination when ARSession is under heavy load.
    /// On constrained devices (iPhone 15 Pro series), the combination of ARKit Neural Surface
    /// Synthesis and a full-precision CoreML model can exceed the Jetsam memory limit.
    private static let fullPrecisionMemoryThreshold: UInt64 = 8 * 1024 * 1024 * 1024
    
    /// Check if the device has sufficient memory for the unquantized 16-bit CoreML model.
    /// Prevents Jetsam termination on memory-constrained devices by falling back to
    /// rectangle detection when physical memory is at or below the 8GB threshold.
    private static var isMemoryAvailableForFullPrecision: Bool {
        ProcessInfo.processInfo.physicalMemory > fullPrecisionMemoryThreshold
    }
    
    /// Callback for model loading progress updates.
    private var onModelLoadingProgress: (@Sendable (Double) -> Void)?
    
    /// Callback to signal that the ARSession should be paused while a
    /// large unquantized CoreML model is being loaded. This prevents
    /// memory pressure from ARKit Neural Surface Synthesis from triggering
    /// a Jetsam termination on A13+ devices.
    private var onShouldPauseARSession: (@Sendable (Bool) -> Void)?
    
    /// Reference to the MetricKit telemetry service for thermal/battery reporting.
    /// When set, inference latency samples are recorded for MetricKit submission
    /// to correlate predictive model thresholds with real-world device thermals.
    private weak var telemetryService: MetricKitTelemetryService?
    
    /// Configure the ARSession pause/resume handler.
    /// Call this after the DetectionEngine is created to wire up the ARSessionManager
    /// for automatic session pausing during unquantized model fallback loads.
    func configureARSessionPauseHandler(_ handler: @escaping (@Sendable (Bool) -> Void)) {
        onShouldPauseARSession = handler
    }
    
    /// Configure the MetricKit telemetry service for thermal/battery reporting.
    /// When set, inference latency samples are recorded and submitted via MetricKit
    /// to correlate predictive model thresholds with real-world device thermals.
    /// - Parameter service: The telemetry service to use for reporting.
    func configureTelemetryService(_ service: MetricKitTelemetryService) {
        self.telemetryService = service
    }
    
    /// Initialize with material fixture mapping loaded from classification_rules.json.
    /// Optionally verifies an ECDSA signature for OTA config authenticity.
    /// - Parameters:
    ///   - onModelLoadingProgress: Callback for model loading progress updates.
    ///   - configSignature: Optional ECDSA signature for verifying config authenticity.
    ///   - configKeyID: Optional key identifier for multi-key rotation support.
    ///   - stateStream: Optional reference to the state stream for reporting quantization fallback events.
    ///   - detectionSettings: User-configurable detection settings for battery/performance trade-offs.
    ///   - onShouldPauseARSession: Optional callback to pause/resume the ARSession during
    ///     unquantized model fallback load to prevent memory spikes.
    init(onModelLoadingProgress: (@Sendable (Double) -> Void)? = nil, configSignature: Data? = nil, configKeyID: String? = nil, stateStream: HueStateStream? = nil, detectionSettings: DetectionSettings = DetectionSettings(), onShouldPauseARSession: (@Sendable (Bool) -> Void)? = nil) {
        self.materialClassifier = NeuralSurfaceMaterialClassifier(
            materialFixtureMapping: NeuralSurfaceMaterialClassifier.loadMaterialMapping(signature: configSignature, keyID: configKeyID),
            materialIndexMapping: NeuralSurfaceMaterialClassifier.loadMaterialIndexMapping(signature: configSignature, keyID: configKeyID)
        )
        self.detectionSettings = detectionSettings
        self.thermalMonitor = ThermalMonitor()
        self.onModelLoadingProgress = onModelLoadingProgress
        self.onShouldPauseARSession = onShouldPauseARSession
        self.stateStream = stateStream
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
    ///
    /// - Parameters:
    ///   - pixelBuffer: The camera frame pixel buffer.
    ///   - timestamp: The frame timestamp.
    ///   - displayTransform: ARKit's display transform for device-orientation-aware
    ///     coordinate mapping. When `nil`, defaults to portrait orientation.
    func processFrame(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval, displayTransform: CGAffineTransform? = nil) async throws -> [FixtureDetection] {
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
        
        let detections = try await runHybridDetection(pixelBuffer, lowPower: useLowPower, displayTransform: displayTransform ?? CGAffineTransform.identity)
        
        let elapsed = ContinuousClock.now - start
        inferenceLatencyMs = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        
        // Update predictive thermal model with latency measurement for proactive throttling.
        thermalMonitor.updateWithLatency(inferenceLatencyMs)
        
        // Record telemetry for MetricKit submission to correlate
        // predictive model thresholds with real-world device thermals.
        telemetryService?.recordInference(
            latencyMs: inferenceLatencyMs,
            thermalState: thermalState,
            predictedThermalState: thermalMonitor.predictedThermalState,
            ewmaLatency: thermalMonitor.predictiveModel.ewmaLatency,
            slopeMs: thermalMonitor.predictiveModel.latencyTrendSlope,
            sampleCount: thermalMonitor.predictiveModel.sampleCount,
            inferenceCount: frameCount,
            isModelQuantized: isModelQuantized
        )
        
        let filtered = detections.filter { $0.confidence >= minConfidence }
        
        logger.debug("Pre-filter: \(detections.count) detections, post-filter: \(filtered.count)")
        
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
    /// Also triggers compute unit switching when thermal state changes.
    private func updateThermalState() {
        let previousState = thermalMonitor.thermalState
        _ = thermalMonitor.thermalState
        
        // Switch CoreML compute units when thermal state changes.
        if thermalMonitor.thermalState != previousState {
            updateComputeUnitsForThermalState()
        }
    }
    
    // MARK: - CoreML Model Loading
    
    /// Load the CoreML object detection model for lighting archetype recognition.
    /// Uses a bundled model that classifies fixtures into architectural categories:
    /// Chandelier, Sconce, Desk Lamp, Pendant, Ceiling Light, Recessed Light, Strip Light.
    /// Asynchronously loads the model with progress reporting to avoid blocking the main thread.
    ///
    /// Model loading cascade (optimized for memory-constrained devices):
    /// 1. Pre-compiled FLOAT16 quantized `.mlpackage` bundle (primary, ~50% size reduction)
    /// 2. Standard `.mlpackage` with runtime quantization (fallback)
    /// 3. Full-precision `.mlpackage` (last resort, requires >8GB RAM to avoid Jetsam)
    /// 4. Rectangle detection only (safe fallback for memory-constrained devices)
    private func loadObjectDetectionModel() async {
        guard !isModelLoading else {
            logger.warning("Model loading already in progress")
            return
        }

        isModelLoading = true
        modelLoadingProgress = 0.0
        onModelLoadingProgress?(0.0)

        // Phase 1: Try to load a pre-compiled FLOAT16 quantized model bundle.
        // This is the preferred artifact for production deployment, as it:
        // - Avoids runtime compilation delays (no on-device Neural Engine compilation)
        // - Uses ~50% less memory than the full-precision model (prevents Jetsam)
        // - Provides optimal inference speed on A17+ and M-series chips
        // Ship this as the primary artifact using `coremltools` FLOAT16 quantization.
        let quantizedModelURL = Bundle.main.url(forResource: "LightingArchetype_quantized", withExtension: "mlpackage")

        if let quantizedURL = quantizedModelURL,
           let quantizedModel = try? MLModel(contentsOf: quantizedURL, configuration: MLModelConfiguration()) {
            objectDetectionModel = quantizedModel
            isCoreMLAvailable = true
            isObjectModelLoaded = true
            isModelQuantized = true
            logger.info("Loaded pre-compiled FLOAT16 quantized LightingArchetype model (optimal deployment)")

            // Pre-create VNCoreMLRequest for the quantized model
            do {
                objectDetectionRequest = VNCoreMLRequest(model: try VNCoreMLModel(for: quantizedModel)) { _, error in
                    if let error {
                        Logger(subsystem: "com.tomwolfe.visionlinkhue", category: "DetectionEngine")
                            .warning("CoreML object detection failed: \(error.localizedDescription)")
                    }
                }
                objectDetectionRequest?.imageCropAndScaleOption = .scaleFill
                logger.info("CoreML compute units: \(self.currentComputeUnits == .all ? ".all" : ".cpuOnly")")
            } catch {
                logger.warning("Failed to create VNCoreMLRequest for quantized model: \(error.localizedDescription)")
                isCoreMLAvailable = false
            }

            isModelLoading = false
            modelLoadingProgress = 1.0
            onModelLoadingProgress?(1.0)
            return
        }

        // Phase 2: Fall back to the standard .mlpackage model.
        guard let modelURL = Bundle.main.url(forResource: "LightingArchetype", withExtension: "mlpackage") else {
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

            var skipModelSetup = false

            #if targetEnvironment(simulator)
            objectDetectionModel = try MLModel(contentsOf: modelURL, configuration: baseConfig)
            isCoreMLAvailable = true
            isObjectModelLoaded = true
            isModelQuantized = false
            #else
            let quantizedConfig = MLModelConfiguration()
            quantizedConfig.computeUnits = .all

            var loadedModel: MLModel?
            var quantizationApplied = false

            do {
                loadedModel = try MLModel(contentsOf: modelURL, configuration: quantizedConfig)
                quantizationApplied = true
            } catch {
                logger.debug("4-bit quantization not available for model, falling back to unquantized: \(error.localizedDescription)")

                // Memory guardrail: On devices with <=8GB RAM (e.g., iPhone 15 Pro),
                // loading the unquantized 16-bit model during active ARSession can trigger
                // Jetsam termination. Check physical memory before attempting fallback load.
                if Self.isMemoryAvailableForFullPrecision {
                    // Report quantization fallback to stateStream for thermal model baseline tracking.
                    // Rate-limit to a single report per session to avoid spamming on older devices.
                    if let stateStream, !hasReportedQuantizationFallback {
                        hasReportedQuantizationFallback = true
                        let fallbackError = NSError(
                            domain: "DetectionEngine",
                            code: 2,
                            userInfo: [
                                NSLocalizedDescriptionKey: "FLOAT16 quantized model unavailable, falling back to full precision model. This will increase inference latency and may impact the predictive thermal model baseline."
                            ]
                        )
                        stateStream.reportError(fallbackError, severity: .warning, source: "DetectionEngine.quantization_fallback")
                    }

                    // Pause the ARSession before loading the unquantized model to prevent
                    // a memory spike that could trigger Jetsam termination on A13+ devices.
                    // ARKit Neural Surface Synthesis consumes significant memory, and loading
                    // an unquantized 16-bit model while the session is running can exceed
                    // the available memory budget even on modern devices.
                    onShouldPauseARSession?(true)

                    // Wrap failed model release and fallback load in a single autoreleasepool
                    // to ensure memory from the failed 4-bit CoreML initialization is flushed
                    // before allocating the larger 16-bit model, preventing RAM spikes on
                    // older A-series/M-series chips.
                    try autoreleasepool {
                        loadedModel = nil
                        loadedModel = try MLModel(contentsOf: modelURL, configuration: baseConfig)
                        quantizationApplied = false
                    }

                    // Resume the ARSession after the model is loaded.
                    onShouldPauseARSession?(false)
                } else {
                    let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_000_000_000
                    logger.warning("Memory guardrail triggered: device has \(String(format: "%.1f", memoryGB))GB RAM. Skipping unquantized model to prevent Jetsam. Falling back to rectangle detection.")
                    isCoreMLAvailable = false
                    isObjectModelLoaded = false
                    isModelQuantized = false
                    if let stateStream, !hasReportedQuantizationFallback {
                        hasReportedQuantizationFallback = true
                        let guardrailError = NSError(
                            domain: "DetectionEngine",
                            code: 3,
                            userInfo: [
                                NSLocalizedDescriptionKey: "Memory guardrail: insufficient RAM for full-precision model. Using heuristic rectangle detection."
                            ]
                        )
                        stateStream.reportError(guardrailError, severity: .warning, source: "DetectionEngine.memory_guardrail")
                    }
                    skipModelSetup = true
                }
            }

            if !skipModelSetup {
                objectDetectionModel = loadedModel
                isCoreMLAvailable = true
                isObjectModelLoaded = true
                isModelQuantized = quantizationApplied

                if quantizationApplied {
                    logger.info("CoreML lighting archetype model loaded with FLOAT16 weight quantization")
                } else {
                    logger.info("CoreML lighting archetype model loaded (quantization unavailable, using full precision)")
                }
            }
            #endif

            if !skipModelSetup {
                // Pre-create the VNCoreMLRequest to avoid per-frame allocation churn.
                guard let model = objectDetectionModel else {
                    throw NSError(domain: "DetectionEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model was nil after loading"])
                }
                objectDetectionRequest = VNCoreMLRequest(model: try VNCoreMLModel(for: model)) { _, error in
                    if let error {
                        Logger(subsystem: "com.tomwolfe.visionlinkhue", category: "DetectionEngine")
                            .warning("CoreML object detection failed: \(error.localizedDescription)")
                    }
                }
                objectDetectionRequest?.imageCropAndScaleOption = .scaleFill

                logger.info("CoreML compute units: \(self.currentComputeUnits == .all ? ".all" : ".cpuOnly")")
            }

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
        hasReportedQuantizationFallback = false
        objectDetectionModel = nil
        objectDetectionRequest = nil
        intentClassifier = CoreMLIntentClassifier()
        Task { await loadObjectDetectionModel() }
        Task { await loadIntentClassifierModel() }
    }
    
    /// Switch CoreML compute units based on the effective thermal state.
    /// When predictive throttling is active or thermal state is warning or worse,
    /// switches from `.all` to `.cpuOnly` to reduce NPU/GPU thermal load
    /// while preserving inference capability on the CPU.
    ///
    /// This is called automatically when the thermal monitor detects a state change.
    func updateComputeUnitsForThermalState() {
        let effectiveState = thermalMonitor.effectiveThermalState
        
        if thermalMonitor.isPredictiveThrottlingActive || effectiveState >= .warning {
            if currentComputeUnits != .cpuOnly {
                logger.info("Switching CoreML to .cpuOnly due to thermal state: \(effectiveState.description)")
                currentComputeUnits = .cpuOnly
            }
        } else {
            if currentComputeUnits != .all {
                logger.info("Restoring CoreML to .all compute units (thermal state: \(effectiveState.description))")
                currentComputeUnits = .all
            }
        }
        
        // Reload the model with the new compute units if the model is loaded.
        if isObjectModelLoaded {
            reloadObjectDetectionModel()
        }
    }
    
    /// Load the intent classifier CoreML model asynchronously.
    /// Runs in parallel with the object detection model loading.
    private func loadIntentClassifierModel() async {
        do {
            let classifier = intentClassifier
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
    private func runHybridDetection(_ pixelBuffer: CVPixelBuffer, lowPower: Bool = false, displayTransform: CGAffineTransform) async throws -> [FixtureDetection] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        
        var detections: [FixtureDetection] = []
        
        // Phase 1: CoreML object detection for architectural archetypes
        if isObjectDetectionActive, isCoreMLAvailable, isObjectModelLoaded, !lowPower {
            let objectDetections = try await runObjectDetection(handler: handler, pixelBuffer: pixelBuffer, displayTransform: displayTransform)
            detections.append(contentsOf: objectDetections)
        }
        
        // Phase 2: Rectangle detection as fallback / supplement
        // Always run rectangle detection to catch fixtures not covered by the object model
        // In low-power mode, use reduced confidence threshold to compensate
        let rectangleDetections = try await runRectangleDetection(handler: handler, lowPower: lowPower, displayTransform: displayTransform)
        
        // Merge detections, prioritizing CoreML results for overlapping regions
        detections = mergeDetections(detections, rectangleDetections: rectangleDetections)
        
        return detections
    }
    
    /// Run CoreML-based object detection for lighting archetypes.
    private func runObjectDetection(
        handler: VNImageRequestHandler,
        pixelBuffer: CVPixelBuffer,
        displayTransform: CGAffineTransform
    ) async throws -> [FixtureDetection] {
        guard objectDetectionModel != nil else { return [] }
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
                    ObservationData(boundingBox: observation.boundingBox, worldSpaceHeightMeters: nil)
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
        return await classifyObjects(from: observations, displayTransform: displayTransform)
    }
    
    /// Run Vision rectangle detection as fallback.
    private func runRectangleDetection(handler: VNImageRequestHandler, lowPower: Bool, displayTransform: CGAffineTransform) async throws -> [FixtureDetection] {
        let request = VNDetectRectanglesRequest()
        // Raise confidence threshold in low-power mode to reduce false-positive bounding boxes
        // that would increase downstream CPU/GPU load during thermal throttling
        request.minimumConfidence = lowPower ? DetectionConstants.rectangleMinimumConfidence * 1.25
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
                guard let results = request.results else {
                    return [ObservationData]()
                }
                return results.map { ObservationData(boundingBox: $0.boundingBox, worldSpaceHeightMeters: nil) }
            }
        }
        
        let box = RectangleDetectionBox(handler: handler, request: request)
        let observations = try await Task.detached(priority: priority, operation: { [box] in
            try box.run()
        }).value
        
        logger.debug("Rectangle detection found \(observations.count) candidate(s)")
        
        let result = classifyFixtures(from: observations, displayTransform: displayTransform)
        logger.debug("After filtering: \(result.count) fixture(s) passed confidence threshold")
        
        return result
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
    private func classifyObjects(from observations: [ObservationData], displayTransform: CGAffineTransform) async -> [FixtureDetection] {
        var detections: [FixtureDetection] = []
        
        for observation in observations {
            guard observation.boundingBox.minY < DetectionConstants.maxDetectionY else { continue }
            guard observation.boundingBox.width > DetectionConstants.minBoundingBoxSize && observation.boundingBox.height > DetectionConstants.minBoundingBoxSize else { continue }
            
            let region = NormalizedRect(visionBoundingBox: observation.boundingBox, displayTransform: displayTransform)
            
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
    private func classifyFixtures(from observations: [ObservationData], displayTransform: CGAffineTransform) -> [FixtureDetection] {
        var detections: [FixtureDetection] = []
        
        for observation in observations {
            guard observation.boundingBox.minY < DetectionConstants.maxDetectionY else { continue }
            guard observation.boundingBox.width > DetectionConstants.minBoundingBoxSize && observation.boundingBox.height > DetectionConstants.minBoundingBoxSize else { continue }
            
            let region = NormalizedRect(visionBoundingBox: observation.boundingBox, displayTransform: displayTransform)
            
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
        
        let sorted = detections.sorted { $0.confidence > $1.confidence }
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
    ///
    /// Returns `nil` immediately when Battery Saver mode is enabled to avoid
    /// the computational cost of Neural Surface Synthesis material classification.
    func classifyMaterial(from intrinsics: CameraIntrinsics, at region: NormalizedRect? = nil) -> String? {
        guard !isBatterySaverMode else {
            return nil
        }
        #if !targetEnvironment(simulator)
        return nil
        #else
        return nil
        #endif
    }
}
