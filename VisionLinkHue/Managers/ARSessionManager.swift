import ARKit
import RealityKit
import Foundation
import os

/// Represents the AR session relocalization state for the HUD.
enum ARRelocalizationState: Sendable {
    case none
    case relocalizing(progress: Float)
    case relocalized
    case failed
}

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
    
    /// Whether the session is currently relocalizing against a saved world map.
    var isRelocalizing: Bool = false
    
    /// Current relocalization progress (0.0-1.0).
    var relocalizationProgress: Float = 0.0
    
    /// The AR session's current relocalization state for HUD display.
    var relocalizationState: ARRelocalizationState = .none
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "ARSessionManager"
    )
    
    private let detectionEngine: DetectionEngine
    private let spatialProjector: SpatialProjector
    private let hueClient: HueClient
    private let stateStream: HueStateStream
    private let hudFactory: FixtureHUDFactory
    private let provider: CameraConfigurationProvider
    private let fixturePersistence: FixturePersistence
    
    private var arView: ARView?
    private var anchorEntity: AnchorEntity?
    private var fixtureEntities: [UUID: Entity] = [:]
    
    /// Task that monitors for world map capture during relocalization.
    private var worldMapCaptureTask: Task<ARWorldMap?, Never>?
    
    /// Serial task queue for AR frame processing.
    /// Cancels any in-progress frame processing before starting a new one,
    /// preventing unbounded task accumulation when Vision processing stalls.
    private var processingTask: Task<Void, Never>?
    
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
        fixturePersistence: FixturePersistence = FixturePersistence.shared,
        hudFactory: FixtureHUDFactory = FixtureHUDFactory(),
        provider: CameraConfigurationProvider = DefaultCameraConfigurationProvider()
    ) {
        self.detectionEngine = detectionEngine
        self.spatialProjector = spatialProjector
        self.hueClient = hueClient
        self.stateStream = stateStream
        self.fixturePersistence = fixturePersistence
        self.hudFactory = hudFactory
        self.provider = provider
    }
    
    // MARK: - Session Lifecycle
    
    /// Configure and start the AR session with scene reconstruction.
    /// The AR session is already running via ARViewRepresentable;
    /// this method sets up the root anchor, attempts world map relocalization,
    /// and starts the detection engine.
    func configureAndStart(in arView: ARView) async {
        self.arView = arView
        
        isSessionActive = true
        
        // Create root anchor
        anchorEntity = provider.makeWorldAnchor()
        if let anchor = anchorEntity {
            arView.scene.addAnchor(anchor)
        }
        
        // Attempt to load and use a persisted world map for relocalization
        if let savedWorldMap = fixturePersistence.loadWorldMap() {
            await attemptRelocalization(using: savedWorldMap, in: arView)
        }
        
        // Start detection engine
        detectionEngine.start()
        
        logger.info("AR session started with world reconstruction")
    }
    
    /// Pause the AR session.
    func pause() {
        detectionEngine.stop()
        worldMapCaptureTask?.cancel()
        worldMapCaptureTask = nil
        isSessionActive = false
        isRelocalizing = false
        relocalizationState = .none
        logger.info("AR session paused")
    }
    
    /// Reset tracking and restart.
    func resetTracking() async {
        detectionEngine.start()
        logger.info("AR tracking reset")
    }
    
    // MARK: - World Map Persistence
    
    /// Attempt to relocalize the AR session using a previously saved world map.
    /// Displays a "Connecting" indicator while relocalization is in progress.
    private func attemptRelocalization(using worldMap: ARWorldMap, in arView: ARView) async {
        guard let session = arView.session as? ARSession else { return }
        
        isRelocalizing = true
        relocalizationState = .relocalizing(progress: 0.0)
        logger.info("Attempting relocalization with saved world map")
        
        // Configure session with the saved world map for initial pose
        let config = provider.makeARConfiguration()
        config.initialWorldMap = worldMap
        config.worldMappingMode = .none
        
        // Start a monitoring task to track relocalization progress
        worldMapCaptureTask = Task { [weak self] in
            guard let self else { return }
            
            let startTime = ContinuousClock.now
            let monitoringDuration = Duration.seconds(10)
            
            while !Task.isCancelled {
                let elapsed = ContinuousClock.now - startTime
                let progress = min(Float(elapsed.components.seconds) / 10.0, 0.95)
                
                await MainActor.run {
                    self.relocalizationProgress = progress
                    self.relocalizationState = .relocalizing(progress: progress)
                }
                
                if elapsed >= monitoringDuration {
                    break
                }
                
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        
        // Apply the configuration to trigger relocalization
        await session.run(withConfig: config, options: [.resetScene, .removeExistingAnchors])
        
        // Wait for relocalization to complete
        await waitForRelocalizationCompletion()
    }
    
    /// Monitor the session state to detect successful relocalization.
    private func waitForRelocalizationCompletion() async {
        guard let session = arView?.session as? ARSession else { return }
        
        let startTime = ContinuousClock.now
        let timeout = Duration.seconds(15)
        
        while !Task.isCancelled {
            let snapshot = session.currentFrame?.camera.trackingState
            
            if snapshot == .normal || snapshot == .limited(.localization) {
                await MainActor.run {
                    self.isRelocalizing = false
                    self.relocalizationState = .relocalized
                    self.relocalizationProgress = 1.0
                }
                logger.info("Relocalization successful")
                worldMapCaptureTask?.cancel()
                worldMapCaptureTask = nil
                return
            }
            
            let elapsed = ContinuousClock.now - startTime
            if elapsed >= timeout {
                await MainActor.run {
                    self.isRelocalizing = false
                    self.relocalizationState = .failed
                    self.relocalizationProgress = 0.0
                }
                logger.warning("Relocalization timed out")
                worldMapCaptureTask?.cancel()
                worldMapCaptureTask = nil
                return
            }
            
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
    
    /// Capture and persist the current AR session state as a world map.
    /// This should be called after a fixture has been successfully linked
    /// to save the spatial anchor for future sessions.
    func captureAndSaveWorldMap() async {
        guard let session = arView?.session as? ARSession else { return }
        
        let config = provider.makeARConfiguration()
        config.worldMappingMode = .exact
        
        do {
            let worldMap = try await session.snapshotAsWorldMap(config: config)
            
            await MainActor.run {
                self.worldMapAvailable = true
            }
            
            fixturePersistence.saveWorldMap(worldMap)
            logger.info("World map captured and saved with \(trackedFixtures.count) fixture(s)")
        } catch {
            logger.error("Failed to capture world map: \(error.localizedDescription)")
        }
    }
    
    /// Clear the persisted world map and reset relocalization state.
    func clearSavedWorldMap() {
        fixturePersistence.deleteWorldMap()
        isRelocalizing = false
        relocalizationProgress = 0.0
        relocalizationState = .none
        logger.info("Saved world map cleared")
    }
    
    // MARK: - Frame Processing
    
    /// Called from ARView's session delegate when a new frame is available.
    func didUpdateFrame(_ frame: ARFrame) async {
        await MainActor.run {
            self.frameTimestamp = frame.timestamp
            #if !targetEnvironment(simulator)
            self.worldMapAvailable = frame.worldMap != nil
            if let state = frame.trackingState {
                self.trackingState = state == .limited ? .limited : .tracking
            }
            
            // Update relocalization state based on frame tracking state
            if self.isRelocalizing, let state = frame.trackingState {
                if state == .normal || state == .limited(.localization) {
                    self.isRelocalizing = false
                    self.relocalizationState = .relocalized
                    self.relocalizationProgress = 1.0
                    self.worldMapCaptureTask?.cancel()
                    self.worldMapCaptureTask = nil
                    logger.info("Relocalization completed from frame tracking")
                }
            }
            #else
            self.worldMapAvailable = false
            self.trackingState = .notAvailable
            #endif
        }
        
        // Cancel any in-progress frame processing to prevent task queue buildup.
        // This ensures only the latest frame is processed, dropping stale frames.
        processingTask?.cancel()
        processingTask = Task { await self.processFrameSafely(frame) }
    }
    
    /// Process a single AR frame with bounded concurrency.
    /// Cancels on task cancellation to prevent resource waste.
    private func processFrameSafely(_ frame: ARFrame) async {
        guard !Task.isCancelled else { return }
        
        let anchor = self.anchorEntity
        
        do {
            let detections = try await detectionEngine.processFrame(
                frame.imageBuffer,
                timestamp: frame.timestamp
            )
            
            var newFixtures: [TrackedFixture] = []
            
            for detection in detections {
                guard !Task.isCancelled else { return }
                
                if let anchor {
                    let material = await detectionEngine.classifyMaterial(from: frame, at: detection.region)
                    
                    let fixture = await processDetectionOffMain(detection, in: frame, anchor: anchor, material: material)
                    
                    if let fixture {
                        newFixtures.append(fixture)
                    }
                }
            }
            
            await MainActor.run { [newFixtures] in
                guard self.isSessionActive else { return }
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
    
    // MARK: - Detection Processing
    
    func processDetectionOffMain(
        _ detection: FixtureDetection,
        in frame: ARFrame,
        anchor: AnchorEntity,
        material: String?
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
            distanceMeters: fixture.distanceMeters,
            material: material
        )
    }
    
    @MainActor
    func processDetection(
        _ detection: FixtureDetection,
        in frame: ARFrame
    ) async {
        guard let anchor = anchorEntity else { return }
        
        let fixture = await processDetectionOffMain(detection, in: frame, anchor: anchor, material: nil)
        
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
        
        if let entity = fixtureEntities[fixtureId] {
            entity.removeFromParent()
        }
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
    
    /// Adjust the depth offset for a tracked fixture.
    /// Used on non-LiDAR devices to manually push/pull the Z-depth
    /// of a fixture reticle when automatic depth estimation is unavailable.
    func adjustDepthOffset(for fixtureId: UUID, offset: Float) {
        guard let idx = trackedFixtures.firstIndex(where: { $0.id == fixtureId }) else { return }
        trackedFixtures[idx].depthOffsetMeters = offset
    }
    
    /// Called after a fixture is successfully linked to a Hue light.
    /// Captures the current AR session as a world map for future relocalization.
    func onFixtureLinked(_ fixture: TrackedFixture) async {
        // Update the fixture's mapped light ID
        if let idx = trackedFixtures.firstIndex(where: { $0.id == fixture.id }) {
            trackedFixtures[idx].mappedHueLightId = fixture.mappedHueLightId
        }
        
        // Capture and save the world map for session persistence
        await captureAndSaveWorldMap()
    }
    
}

/// Tracking state representation.
enum ARTrackingState: Sendable {
    case notAvailable
    case limited
    case tracking
}
