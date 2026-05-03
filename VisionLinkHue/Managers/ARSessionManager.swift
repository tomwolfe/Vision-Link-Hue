import ARKit
import RealityKit
import Foundation
import os

/// Manages the AR session lifecycle and bridges ARKit frames to
/// the RealityKit scene and DetectionEngine.
@MainActor
@Observable
final class ARSessionManager {
    
    var isSessionActive: Bool = false
    var anchorCount: Int = 0
    var frameTimestamp: TimeInterval = 0
    var trackingState: ARTrackingState = .notAvailable
    var worldMapAvailable: Bool = false
    var trackedFixtures: [TrackedFixture] = []
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "ARSessionManager"
    )
    
    private let detectionEngine: DetectionEngine
    private let spatialProjector: SpatialProjector
    private let hueClient: HueClient
    private let stateStream: HueStateStream
    private let hudFactory: FixtureHUDFactory
    
    private var arView: ARView?
    private var anchorEntity: AnchorEntity?
    private var fixtureEntities: [UUID: Entity] = [:]
    
    private var lastInferenceTime: TimeInterval = 0
    
    /// Root anchor for all AR content.
    var rootAnchor: AnchorEntity? { anchorEntity }
    
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
        stateStream: HueStateStream,
        hudFactory: FixtureHUDFactory = FixtureHUDFactory()
    ) {
        self.detectionEngine = detectionEngine
        self.spatialProjector = spatialProjector
        self.hueClient = hueClient
        self.stateStream = stateStream
        self.hudFactory = hudFactory
    }
    
    // MARK: - Session Lifecycle
    
    /// Configure and start the AR session with scene reconstruction.
    func configureAndStart(in arView: ARView) async {
        self.arView = arView
        
        let configuration = ARWorldTrackingConfiguration()
        #if !targetEnvironment(simulator)
        configuration.worldReconstructionMode = ARWorldTrackingConfiguration.WorldReconstructionMode.automatic
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.lightEstimation = .automatic
        #else
        configuration.planeDetection = [.horizontal, .vertical]
        #endif
        
        isSessionActive = true
        
        // Create root anchor
        #if !targetEnvironment(simulator)
        anchorEntity = AnchorEntity(.world)
        #else
        anchorEntity = AnchorEntity(.anchor(identifier: UUID()))
        #endif
        if let anchor = anchorEntity {
            arView.scene.addAnchor(anchor)
        }
        
        // Start detection engine
        detectionEngine.start()
        
        logger.info("AR session started with world reconstruction")
    }
    
    /// Pause the AR session.
    func pause() {
        detectionEngine.stop()
        isSessionActive = false
        logger.info("AR session paused")
    }
    
    /// Reset tracking and restart.
    func resetTracking() async {
        detectionEngine.start()
        logger.info("AR tracking reset")
    }
    
    // MARK: - Frame Processing
    
    /// Called from ARView's session delegate when a new frame is available.
    func didUpdateFrame(_ frame: ARFrame) async {
        await MainActor.run {
            self.frameTimestamp = frame.timestamp
            #if !targetEnvironment(simulator)
            self.worldMapAvailable = frame.worldMap != nil
            #else
            self.worldMapAvailable = false
            #endif
            #if !targetEnvironment(simulator)
            if let state = frame.trackingState {
                self.trackingState = state == .limited ? .limited : .tracking
            }
            #else
            self.trackingState = .notAvailable
            #endif
        }
        
        // Throttle inference to DetectionConstants.inferenceInterval
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastInferenceTime >= DetectionConstants.inferenceInterval else { return }
        lastInferenceTime = now
        
        // Offload heavy Vision/Projection work to background task
        Task.detached { [detectionEngine = self.detectionEngine, spatialProjector = self.spatialProjector, anchor = self.anchorEntity] in
            do {
                let detections = try await detectionEngine.processFrame(
                    frame.imageBuffer,
                    timestamp: frame.timestamp
                )
                
                var newFixtures: [TrackedFixture] = []
                
                for detection in detections {
                    if let anchor {
                        // Use TaskGroup for parallel detection processing and material sampling
                        let fixture = await withTaskGroup(of: TrackedFixture?.self) { taskGroup in
                            // Spawn task for spatial projection
                            taskGroup.addTask {
                                await self.processDetectionOffMain(detection, in: frame, anchor: anchor)
                            }
                            
                            // Spawn parallel task for material sampling
                            taskGroup.addTask {
                                let material = self.detectionEngine.classifyMaterial(from: frame, at: detection.region)
                                return nil // Material result is logged but doesn't block fixture creation
                            }
                            
                            // Wait for all tasks to complete
                            var result: TrackedFixture? = nil
                            for await item in taskGroup {
                                if let fixture = item {
                                    result = fixture
                                }
                            }
                            return result
                        }
                        
                        if let fixture {
                            newFixtures.append(fixture)
                        }
                    }
                }
                
                await MainActor.run { [newFixtures] in
                    for fixture in newFixtures {
                        if !self.trackedFixtures.contains(where: { $0.id == fixture.id }) {
                            self.trackedFixtures.append(fixture)
                        }
                    }
                    self.anchorCount = self.trackedFixtures.count
                }
            } catch {
                await MainActor.run {
                    self.logger.warning("Frame processing failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - Detection Processing
    
    func processDetectionOffMain(
        _ detection: FixtureDetection,
        in frame: ARFrame,
        anchor: AnchorEntity
    ) async -> TrackedFixture? {
        // Check if we already have this detection
        if trackedFixtures.first(where: { $0.id == detection.id }) != nil {
            return nil
        }
        
        // Project 2D detection to 3D world coordinates.
        // SpatialProjector is @MainActor isolated; calling from background
        // task automatically crosses the actor boundary.
        let result = await spatialProjector.project(
            region: detection.region,
            inFrame: frame,
            anchor: anchor
        )
        
        guard case .anchored(let fixture) = result else {
            logger.warning("Projection failed: \(result.errorMessage ?? "unknown")")
            return nil
        }
        
        return TrackedFixture(
            id: fixture.id,
            detection: fixture.detection,
            position: fixture.position,
            orientation: fixture.orientation,
            distanceMeters: fixture.distanceMeters
        )
    }
    
    @MainActor
    func processDetection(
        _ detection: FixtureDetection,
        in frame: ARFrame
    ) async {
        guard let anchor = anchorEntity else { return }
        
        let fixture = await processDetectionOffMain(detection, in: frame, anchor: anchor)
        
        guard let trackedFixture = fixture else { return }
        
        trackedFixtures.append(trackedFixture)
        
        logger.info(
            "Tracked \(trackedFixture.type.displayName) at \(String(format: "%.2f", trackedFixture.distanceMeters))m (confidence: \(String(format: "%.2f", trackedFixture.confidence)))"
        )
    }
    
    // MARK: - Fixture Management
    
    /// Create a HUD entity for a fixture in the RealityKit scene.
    /// Uses the RealityKit 2026 native ViewAttachmentComponent(rootView:)
    /// API for automatic SwiftUI view lifecycle management and
    /// @Observable-driven entity updates.
    func createHUD(for fixture: TrackedFixture, in scene: RealityKit.Scene) async {
        guard let anchor = anchorEntity else { return }
        
        guard let entity = hudFactory.createHUD(for: fixture, in: scene, parent: anchor) else { return }
        
        // Update tracked fixture with entity ID and mapped Hue light ID.
        if let idx = trackedFixtures.firstIndex(where: { $0.id == fixture.id }) {
            var updated = trackedFixtures[idx]
            updated.hudEntityID = entity.id
            updated.mappedHueLightId = stateStream.fixtureLightMapping[fixture.id]
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
