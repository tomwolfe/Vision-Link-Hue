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
final class DetectionEngine: @unchecked Sendable {
    
    var lastDetections: [FixtureDetection] = []
    var isRunning: Bool = false
    var inferenceLatencyMs: Double = 0
    var frameCount: Int = 0
    
    /// Current thermal state of the device for adaptive inference throttling.
    var thermalState: ThermalState = .nominal
    
    /// Whether low-power AR mode is active to prevent thermal throttling.
    var isLowPowerMode: Bool = false
    
    private let logger = Logger(subsystem: "com.tomwolfe.visionlinkhue", category: "DetectionEngine")
    
    /// Minimum confidence threshold for returning detections.
    private let minConfidence: Double = DetectionConstants.minConfidence
    
    /// Request ID for Vision requests.
    private let requestID = UUID()
    
    /// Heuristic classifier for fixture type and confidence.
    private let classifier = FixtureHeuristicClassifier()
    
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
        startThermalMonitoring()
    }
    
    /// Stop continuous detection.
    func stop() {
        isRunning = false
        lastDetections = []
        stopThermalMonitoring()
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
    
    // MARK: - Vision Detection
    
    private func runVisionDetection(_ pixelBuffer: CVPixelBuffer, lowPower: Bool = false) async throws -> [FixtureDetection] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.2
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[FixtureDetection], Error>) in
            // In low-power mode, use .utility QoS to reduce CPU/GPU load
            // and prevent thermal throttling that forces LiDAR shut-off
            let qos: DispatchQoS.QoSClass = lowPower ? .utility : .userInitiated
            
            DispatchQueue.global(qos: qos).async {
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
    
    // MARK: - Thermal Management
    
    /// Update the thermal state based on current system conditions.
    /// Used to adaptively throttle inference frequency and prevent
    /// the device from entering a "Serious" thermal state (which
    /// forces LiDAR shut-off).
    private func updateThermalState() {
        let systemThermalState = ProcessInfo.processInfo.thermalState
        switch systemThermalState {
        case .nominal:
            self.thermalState = .nominal
        case .fair:
            self.thermalState = .fair
        case .serious:
            self.thermalState = .warning
        case .critical:
            self.thermalState = .serious
        @unknown default:
            self.thermalState = .nominal
        }
    }
    
    /// Start monitoring thermal state changes via notification.
    /// Proactively throttles inference before the system forces
    /// LiDAR/Depth sensor shutdown during thermal throttling.
    private func startThermalMonitoring() {
        thermalMonitoringTask = Task {
            for await notification in NotificationCenter.default.notifications(named: ProcessInfo.thermalStateDidChangeNotification) {
                guard let _ = notification.object as? ProcessInfo else { continue }
                await MainActor.run {
                    let previousState = self.thermalState
                    self.updateThermalState()
                    if self.thermalState != previousState {
                        self.logger.info("Thermal state changed: \(previousState) -> \(self.thermalState)")
                    }
                }
            }
        }
    }
    
    /// Stop thermal state monitoring.
    private func stopThermalMonitoring() {
        thermalMonitoringTask?.cancel()
        thermalMonitoringTask = nil
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

// MARK: - Thermal State

/// Represents the thermal state of the device for adaptive inference throttling.
/// Used to prevent the device from entering a "Serious" thermal state that
/// forces LiDAR shut-off.
enum ThermalState: Comparable, CustomStringConvertible {
    case nominal
    case fair
    case warning
    case serious
    case critical
    
    var description: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .warning: return "Warning"
        case .serious: return "Serious"
        case .critical: return "Critical"
        }
    }
}

// MARK: - Neural Surface Material Classifier

/// ARKit 2026 Neural Surface Synthesis material classifier.
/// Samples material labels from AR frames to identify fixture surfaces
/// as Glass, Metal, Wood, Fabric, Plaster, or Concrete.
///
/// This classifier complements the heuristic classifier by providing
/// material-based classification that is more robust for fixture types
/// with distinctive surface properties.
///
/// Uses ARKit 2026's `ARFrame.sceneDepth.materialLabel` API to sample
/// material classifications at normalized pixel coordinates. Supports
/// multi-point sampling with voting for improved accuracy.
///
/// Material-to-fixture-type mapping is loaded from `classification_rules.json`
/// to enable OTA updates without recompiling.
struct NeuralSurfaceMaterialClassifier: Sendable {
    
    /// Known material labels supported by ARKit 2026 Neural Surface Synthesis.
    static let supportedMaterials: [String] = [
        "Glass", "Metal", "Wood", "Fabric", "Plaster", "Concrete"
    ]
    
    /// Default material-to-fixture-type mapping (used when config is unavailable).
    private static let defaultMaterialFixtureMapping: [String: [FixtureType]] = [
        "Glass": [.recessed, .ceiling],
        "Metal": [.pendant, .lamp],
        "Wood": [.ceiling, .recessed],
        "Fabric": [.lamp, .pendant],
        "Plaster": [.ceiling, .recessed],
        "Concrete": [.ceiling, .recessed]
    ]
    
    /// Material-to-fixture-type mapping loaded from classification_rules.json.
    private let materialFixtureMapping: [String: [FixtureType]]
    
    /// Number of sample points to use for voting-based material classification.
    private static let sampleRadius: Float = 0.03
    
    /// Initialize with a material fixture mapping from the classification config.
    /// - Parameter mapping: Material-to-fixture-type mapping loaded from `classification_rules.json`.
    init(materialFixtureMapping: [String: [FixtureType]] = NeuralSurfaceMaterialClassifier.defaultMaterialFixtureMapping) {
        self.materialFixtureMapping = materialFixtureMapping
    }
    
    /// Load the material-to-fixture-type mapping from classification_rules.json.
    /// Falls back to the default mapping if the config file is unavailable.
    static func loadMaterialMapping() -> [String: [FixtureType]] {
        // Try to load from the bundled classification_rules.json
        guard let url = Bundle.main.url(forResource: "classification_rules", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(ClassificationConfigFile.self, from: data),
              let mapping = config.config?.materialFixtureMapping else {
            return defaultMaterialFixtureMapping
        }
        
        var result: [String: [FixtureType]] = [:]
        for (material, fixtureNames) in mapping {
            result[material] = fixtureNames.compactMap { FixtureType(from: $0) }
        }
        
        return result.isEmpty ? defaultMaterialFixtureMapping : result
    }
    
    /// Sample the material label at a normalized position in the AR frame.
    /// Uses multi-point sampling with a small radius and returns the most
    /// common material label (majority voting).
    ///
    /// - Parameters:
    ///   - normalizedPosition: Normalized [0,1] coordinates in the frame.
    ///   - frame: The current AR frame containing depth/material data.
    ///   - materialLabel: The raw material label pixel buffer from `sceneDepth.materialLabel`.
    /// - Returns: The dominant material label string, or `nil` if no valid data.
    func sampleMaterial(
        at normalizedPosition: SIMD2<Float>,
        in frame: ARFrame,
        materialLabel: CVPixelBuffer
    ) -> String? {
        let pixelWidth = Int(CVPixelBufferGetWidth(materialLabel))
        let pixelHeight = Int(CVPixelBufferGetHeight(materialLabel))
        
        let basePx = Int(normalizedPosition.x * Float(pixelWidth))
        let basePy = Int(normalizedPosition.y * Float(pixelHeight))
        
        let radius = Int(NeuralSurfaceMaterialClassifier.sampleRadius * Float(max(pixelWidth, pixelHeight)))
        let clampedRadius = min(radius, 5)
        
        var voteCount: [String: Int] = [:]
        var totalSamples = 0
        
        CVPixelBufferLockBaseAddress(materialLabel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(materialLabel, .readOnly) }
        
        for dy in -clampedRadius...clampedRadius {
            for dx in -clampedRadius...clampedRadius {
                let px = basePx + dx
                let py = basePy + dy
                
                guard px >= 0, px < pixelWidth, py >= 0, py < pixelHeight else { continue }
                
                let label = extractMaterialLabel(from: materialLabel, pixelX: px, pixelY: py, width: pixelWidth)
                if let label, !label.isEmpty, NeuralSurfaceMaterialClassifier.supportedMaterials.contains(label) {
                    voteCount[label, default: 0] += 1
                    totalSamples += 1
                }
            }
        }
        
        guard totalSamples > 0 else { return nil }
        
        return voteCount.max { $0.value < $1.value }?.key
    }
    
    /// Extract a material label string from the material label pixel buffer.
    /// Material labels are stored as uint8 values indexed by a lookup table
    /// provided by ARKit's Neural Surface Synthesis pipeline.
    private func extractMaterialLabel(
        from pixelBuffer: CVPixelBuffer,
        pixelX: Int,
        pixelY: Int,
        width: Int
    ) -> String? {
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        
        let byteOffset = pixelY * width + pixelX
        let materialIndex = baseAddress.load(fromByteOffset: byteOffset, as: UInt8.self)
        
        return materialIndexToLabel(materialIndex)
    }
    
    /// Map an ARKit neural surface material index to its string label.
    /// ARKit 2026 assigns indices to material types in the depth/material pipeline.
    private func materialIndexToLabel(_ index: UInt8) -> String? {
        switch index {
        case 0: return "Glass"
        case 1: return "Metal"
        case 2: return "Wood"
        case 3: return "Fabric"
        case 4: return "Plaster"
        case 5: return "Concrete"
        default: return nil
        }
    }
    
    /// Get fixture types that are commonly associated with a material.
    /// Uses the mapping loaded from `classification_rules.json`.
    func fixtureTypes(forMaterial material: String) -> [FixtureType] {
        materialFixtureMapping[material, default: []]
    }
}

