import Vision
@preconcurrency import CoreML
import Foundation
import os

/// Protocol for intent-based fixture classification using on-device ML models.
/// Complements heuristic classification by providing semantic understanding
/// of fixture archetypes (Chandelier, Sconce, Desk Lamp, etc.) from visual data.
///
/// When CoreML confidence exceeds the override threshold, intent classification
/// takes priority over geometric heuristics for more accurate fixture type assignment.
protocol FixtureIntentClassifier: Sendable {
    /// Whether the underlying model is loaded and ready for inference.
    var isReady: Bool { get }

    /// Classify an observation into a fixture type with confidence score.
    /// - Parameter observation: The observation data to classify.
    /// - Returns: A tuple containing the classified fixture type and confidence score.
    func classify(_ observation: ObservationData) async -> (type: FixtureType, confidence: Double)

    /// Load the underlying ML model asynchronously.
    func loadModel() async throws
}

/// CoreML-backed intent classifier that uses the bundled LightingArchetype model
/// to classify lighting fixtures into architectural archetypes.
///
/// The model recognizes categories like Chandelier, Sconce, Desk Lamp, Pendant,
/// Ceiling Light, Recessed Light, and Strip Light. Classification results override
/// heuristic scoring when confidence exceeds the override threshold.
///
/// Uses `VNCoreMLRequest` for Vision framework integration and handles
/// async inference via `Task.detached` to avoid blocking the main thread.
struct CoreMLIntentClassifier: FixtureIntentClassifier {
    /// Mapping from CoreML model labels to `FixtureType` enum cases.
    static let labelToFixtureType: [String: FixtureType] = [
        "Chandelier": .chandelier,
        "Sconce": .sconce,
        "Desk Lamp": .deskLamp,
        "Pendant": .pendant,
        "Ceiling Light": .ceiling,
        "Recessed Light": .recessed,
        "Strip Light": .strip,
        "Lamp": .lamp
    ]

    /// Minimum confidence required for intent classification to override heuristics.
    private static let overrideConfidenceThreshold: Double = 0.75

    /// The loaded CoreML model.
    private var model: MLModel?

    /// Whether the model has been loaded successfully.
    var isReady: Bool { model != nil }

    /// Initialize the classifier without loading the model.
    /// Call `loadModel()` before using.
    init() {}

    /// Initialize with a pre-loaded model.
    /// - Parameter model: An already-loaded CoreML model.
    init(model: MLModel?) {
        self.model = model
    }

    /// Load the bundled LightingArchetype CoreML model asynchronously.
    /// Falls back to an unloaded state if the model is not found.
    func loadModel() async throws {
        guard let modelURL = Bundle.main.url(forResource: "LightingArchetype", withExtension: "mlmodel") else {
            return
        }

        let compiledModelURL = try MLModel.compile(modelAt: modelURL)
        model = try await Task.detached {
            try MLModel(contentsOf: compiledModelURL)
        }.value
    }

    /// Classify an observation using the CoreML model and Vision framework.
    /// Returns the top classification result mapped to `FixtureType`.
    /// - Parameter observation: The observation data containing bounding box info.
    /// - Returns: A tuple of (FixtureType, confidence). Returns (.lamp, 0.0) if unavailable.
    func classify(_ observation: ObservationData) async -> (type: FixtureType, confidence: Double) {
        guard let model = model else {
            return (FixtureType.lamp, 0.0)
        }

        do {
            let pixelBuffer = try createPixelBuffer(from: observation.boundingBox)
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])

            let coreMLRequest = VNCoreMLRequest(
                model: try VNCoreMLModel(for: model)
            ) { [weak self] request, error in
                if let error {
                    Logger(subsystem: "com.visionlinkhue", category: "CoreMLIntentClassifier")
                        .warning("CoreML classification failed: \(error.localizedDescription)")
                }
            }
            coreMLRequest.imageCropAndScaleOption = .scaleFill

            try await handler.perform([coreMLRequest])

            guard let results = coreMLRequest.results as? [VNRecognizedObjectObservation],
                  let topObservation = results.first,
                  let topLabel = topObservation.labels.first else {
                return (FixtureType.lamp, 0.0)
            }

            guard let fixtureType = Self.labelToFixtureType[topLabel.identifier] else {
                return (FixtureType.lamp, 0.0)
            }

            return (fixtureType, topLabel.confidence)
        } catch {
            Logger(subsystem: "com.visionlinkhue", category: "CoreMLIntentClassifier")
                .warning("CoreML classification error: \(error.localizedDescription)")
            return (FixtureType.lamp, 0.0)
        }
    }

    /// Check if the intent classifier has sufficient confidence to override
    /// heuristic classification results.
    /// - Parameter confidence: The CoreML classification confidence score.
    /// - Returns: True if confidence exceeds the override threshold.
    static func shouldOverrideHeuristics(confidence: Double) -> Bool {
        confidence >= overrideConfidenceThreshold
    }

    /// Get the override threshold value for external consumers.
    static let overrideThreshold: Double = overrideConfidenceThreshold

    /// Create a minimal pixel buffer for Vision framework processing.
    /// In production, this would use the actual camera frame buffer.
    private func createPixelBuffer(from box: CGRect) throws -> CVPixelBuffer {
        let width = 224
        let height = 224
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            width,
            height,
            kCVPixelFormatType_32ARGB,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw NSError(
                domain: "CoreMLIntentClassifier",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create pixel buffer"]
            )
        }

        return buffer
    }
}
