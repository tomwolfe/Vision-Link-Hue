import ARKit
import RealityKit
import Foundation
import os

/// Manages the AR session lifecycle and bridges ARKit frames to
/// the RealityKit scene and DetectionEngine.
final class ARSessionManager: ObservableObject {
    
    @Published var isSessionActive: Bool = false
    @Published var anchorCount: Int = 0
    @Published var frameTimestamp: TimeInterval = 0
    @Published var trackingState: ARTrackingState = .notAvailable
    @Published var worldMapAvailable: Bool = false
    @Published var trackedFixtures: [TrackedFixture] = []
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "ARSessionManager"
    )
    
    private let detectionEngine: DetectionEngine
    private let spatialProjector: SpatialProjector
    private let hueClient: HueClient
    private let stateStream: HueStateStream
    
    private var arView: ARView?
    private var anchorEntity: AnchorEntity.World?
    private var fixtureEntities: [UUID: ModelEntity] = [:]
    
    private var lastInferenceTime: TimeInterval = 0
    private let inferenceInterval: TimeInterval = 0.5
    
    /// Root anchor for all AR content.
    var rootAnchor: AnchorEntity.World? { anchorEntity }
    
    /// Currently tracked fixtures.
    var anchoredFixtures: [TrackedFixture] {
        Array(fixtureEntities.values.compactMap { entity in
            trackedFixtures.first { $0.hudEntityID == entity.id }
        })
    }
    
    init(
        detectionEngine: DetectionEngine,
        spatialProjector: SpatialProjector,
        hueClient: HueClient,
        stateStream: HueStateStream
    ) {
        self.detectionEngine = detectionEngine
        self.spatialProjector = spatialProjector
        self.hueClient = hueClient
        self.stateStream = stateStream
    }
    
    // MARK: - Session Lifecycle
    
    /// Configure and start the AR session with scene reconstruction.
    func configureAndStart(in arView: ARView) async {
        self.arView = arView
        
        // Update spatial projector with the active session
        await spatialProjector.configure(with: arView.session)
        
        let configuration = ARWorldTrackingConfiguration()
        
        // Enable world reconstruction for mesh-based raycasting
        configuration.worldReconstructionMode = .automatic
        
        // Enable plane detection for surface anchoring
        configuration.planeDetection = [.horizontal, .vertical]
        
        // Enable light estimation for ambient lighting awareness
        configuration.lightEstimation = .automatic
        configuration.isLightEstimationEnabled = true
        configuration.isWorldSensingEnabled = true
        
        do {
            try await arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
            isSessionActive = true
            
            // Create root anchor
            anchorEntity = AnchorEntity(world: .zero)
            if let anchor = anchorEntity {
                arView.scene.addAnchor(anchor)
            }
            
            // Start detection engine
            detectionEngine.start()
            
            logger.info("AR session started with world reconstruction")
        } catch {
            logger.error("Failed to start AR session: \(error.localizedDescription)")
            await stateStream.reportError(error, severity: .critical, source: "ARSessionManager.configure")
        }
    }
    
    /// Pause the AR session.
    func pause() {
        arView?.session.pause()
        detectionEngine.stop()
        isSessionActive = false
        logger.info("AR session paused")
    }
    
    /// Reset tracking and restart.
    func resetTracking() async {
        guard let arView else { return }
        
        let configuration = arView.session.configuration as? ARWorldTrackingConfiguration
        if let configuration {
            try? await arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        }
        
        detectionEngine.start()
        logger.info("AR tracking reset")
    }
    
    // MARK: - Frame Processing
    
    /// Called from ARView's session delegate when a new frame is available.
    func didUpdateFrame(_ frame: ARFrame) async {
        frameTimestamp = frame.timestamp
        worldMapAvailable = frame.worldMap != nil
        
        // Update tracking state
        if let state = frame.trackingState {
            trackingState = state == .limited ? .limited : .tracking
        }
        
        // Throttle inference to inferenceInterval
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastInferenceTime >= inferenceInterval else { return }
        lastInferenceTime = now
        
        // Run detection on the frame
        do {
            let detections = try await detectionEngine.processFrame(
                frame.capturedImage,
                timestamp: frame.timestamp
            )
            
            // Process each detection
            for detection in detections {
                await processDetection(detection, in: frame)
            }
            
            anchorCount = trackedFixtures.count
        } catch {
            logger.warning("Frame processing failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Detection Processing
    
    private func processDetection(
        _ detection: FixtureDetection,
        in frame: ARFrame
    ) async {
        guard let anchor = anchorEntity else { return }
        
        // Check if we already have this detection
        if trackedFixtures.first(where: { $0.id == detection.id }) != nil {
            return
        }
        
        // Project 2D detection to 3D world coordinates
        let result = await spatialProjector.project(
            region: detection.region,
            inFrame: frame,
            anchor: anchor
        )
        
        guard case .anchored(let fixture) = result else {
            logger.warning("Projection failed: \(result.errorMessage ?? "unknown")")
            return
        }
        
        // Store the tracked fixture
        let trackedFixture = TrackedFixture(
            id: fixture.id,
            detection: fixture.detection,
            position: fixture.position,
            orientation: fixture.orientation,
            distanceMeters: fixture.distanceMeters
        )
        
        trackedFixtures.append(trackedFixture)
        
        logger.info(
            "Tracked \(trackedFixture.type.displayName) at \(String(format: "%.2f", trackedFixture.distanceMeters))m " +
            "(confidence: \(String(format: "%.2f", trackedFixture.confidence)))"
        )
    }
    
    // MARK: - Fixture Management
    
    /// Create a HUD entity for a fixture in the RealityKit scene.
    func createHUD(for fixture: TrackedFixture, in scene: RealityKit.Scene) async {
        guard let anchor = anchorEntity else { return }
        
        // Create the model entity
        let entity = ModelEntity()
        entity.position = fixture.position
        entity.orientation = fixture.orientation
        
        // Add ViewAttachmentComponent for SwiftUI integration
        let attachment = ViewAttachmentComponent(
            parent: anchor,
            offset: .zero
        )
        entity.components.set(ViewAttachmentComponent.self, set: attachment)
        
        // Add to scene
        anchor.addChild(entity)
        
        // Update tracked fixture with entity ID
        if let idx = trackedFixtures.firstIndex(where: { $0.id == fixture.id }) {
            var updated = trackedFixtures[idx]
            updated.hudEntityID = entity.id
            trackedFixtures[idx] = updated
        }
        
        fixtureEntities[fixture.id] = entity
        
        logger.debug("Created HUD entity for fixture \(fixture.id)")
    }
    
    /// Remove a fixture and its HUD from the scene.
    func removeFixture(_ fixtureId: UUID) {
        trackedFixtures.removeAll { $0.id == fixtureId }
        fixtureEntities.removeValue(forKey: fixtureId)
        anchorCount = trackedFixtures.count
        logger.debug("Removed fixture \(fixtureId)")
    }
    
    /// Clear all fixtures from the scene.
    func clearAllFixtures() {
        trackedFixtures.removeAll()
        fixtureEntities.removeAll()
        anchorCount = 0
    }
    
    /// Get the Hue light group ID that corresponds to a fixture.
    func resolveHueGroup(for fixture: TrackedFixture) -> String? {
        guard let groupId = stateStream.selectedGroupId else { return nil }
        return groupId
    }
}

/// Tracking state representation.
enum ARTrackingState: Sendable {
    case notAvailable
    case limited
    case tracking
}
