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
    /// Relocalization is failing; provides directional guidance for the user to look in a specific direction.
    case failing(lookDirection: LookDirection, progress: Float)
}

/// Directional guidance for the user during relocalization failure.
/// Derived from ARKit's feature point distribution analysis to tell the user
/// which direction to pan the device to expose more tracked features.
enum LookDirection: Sendable {
    /// No specific direction; generic prompt.
    case none
    /// Pan the device to the left to expose more tracked features.
    case left
    /// Pan the device to the right to expose more tracked features.
    case right
    /// Pan the device upward to expose more tracked features.
    case up
    /// Pan the device downward to expose more tracked features.
    case down
    /// Move the device closer to the environment.
    case closer
    /// Move the device farther from the environment.
    case farther
    /// Quadrant-based environmental guidance with specific direction description.
    case environmental(description: String, icon: String)
    
    /// Human-readable instruction for the HUD.
    var instruction: String {
        switch self {
        case .none: return "Move your device slowly to help the app reconnect"
        case .left: return "Look to your left to help reconnect"
        case .right: return "Look to your right to help reconnect"
        case .up: return "Look up to help reconnect"
        case .down: return "Look down to help reconnect"
        case .closer: return "Move your device closer to the room"
        case .farther: return "Move your device farther from the room"
        case .environmental(let description, _): return description
        }
    }
    
    /// System image name for the directional arrow icon.
    var icon: String {
        switch self {
        case .none: return "arrow.forward.circle"
        case .left: return "arrow.left.circle.fill"
        case .right: return "arrow.right.circle.fill"
        case .up: return "arrow.up.circle.fill"
        case .down: return "arrow.down.circle.fill"
        case .closer: return "arrow.inward.circle.fill"
        case .farther: return "arrow.outward.circle.fill"
        case .environmental(_, let icon): return icon
        }
    }
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
    private let relocalizationGuide: RelocalizationGuide
    private let objectAnchorService: ObjectAnchorPersistenceService
    
    private var arView: ARView?
    private var anchorEntity: AnchorEntity?
    private var fixtureEntities: [UUID: Entity] = [:]
    
    /// Task that monitors for world map capture during relocalization.
    private var worldMapCaptureTask: Task<ARWorldMap?, Never>?
    
    /// Task that monitors for object anchor matches during relocalization.
    private var objectAnchorMatchTask: Task<Void, Never>?
    
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
        provider: CameraConfigurationProvider = DefaultCameraConfigurationProvider(),
        relocalizationGuide: RelocalizationGuide = RelocalizationGuide(),
        objectAnchorService: ObjectAnchorPersistenceService = ObjectAnchorPersistenceService()
    ) {
        self.detectionEngine = detectionEngine
        self.spatialProjector = spatialProjector
        self.hueClient = hueClient
        self.stateStream = stateStream
        self.fixturePersistence = fixturePersistence
        self.hudFactory = hudFactory
        self.provider = provider
        self.relocalizationGuide = relocalizationGuide
        self.objectAnchorService = objectAnchorService
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
        objectAnchorMatchTask?.cancel()
        objectAnchorMatchTask = nil
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
    /// Also configures object anchor tracking for faster fixture-specific relocalization.
    private func attemptRelocalization(using worldMap: ARWorldMap, in arView: ARView) async {
        guard let session = arView.session as? ARSession else { return }
        
        // Reset relocalization guide state for the new attempt.
        relocalizationGuide.reset()
        
        // Reset object anchor matching state.
        objectAnchorService.isRelocalized = false
        objectAnchorService.matchedArchetype = nil
        
        isRelocalizing = true
        relocalizationState = .relocalizing(progress: 0.0)
        logger.info("Attempting relocalization with saved world map")
        
        // Configure session with the saved world map for initial pose
        let config = provider.makeARConfiguration()
        config.initialWorldMap = worldMap
        config.worldMappingMode = .none
        
        // Enable object anchor tracking for fixture-specific relocalization.
        // As of iOS 26, object anchors provide faster relocalization than
        // generic world-mapping for known fixture archetypes.
        if objectAnchorService.hasActiveAnchors {
            config.objectTrackingMode = .enabled
            logger.info("Object anchor tracking enabled with \(objectAnchorService.archetypes.count) archetype(s)")
        }
        
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
        
        // Start object anchor matching monitor when object anchors are available.
        if objectAnchorService.hasActiveAnchors {
            objectAnchorMatchTask = Task { [weak self] in
                await self?.monitorObjectAnchorMatches()
            }
        }
        
        // Apply the configuration to trigger relocalization
        await session.run(withConfig: config, options: [.resetScene, .removeExistingAnchors])
        
        // Wait for relocalization to complete
        await waitForRelocalizationCompletion()
    }
    
    /// Monitor the session state to detect successful relocalization.
    /// Provides directional guidance to the user when tracking is limited.
    private func waitForRelocalizationCompletion() async {
        guard let session = arView?.session as? ARSession else { return }
        
        let startTime = ContinuousClock.now
        let timeout = Duration.seconds(15)
        var lastGuidanceUpdate: ContinuousClock.Instant = .now
        let guidanceInterval = Duration.seconds(2)
        
        while !Task.isCancelled {
            let frame = session.currentFrame
            let snapshot = frame?.camera.trackingState
            
            // Analyze frame for directional guidance at regular intervals.
            let elapsedSinceGuidance = ContinuousClock.now - lastGuidanceUpdate
            if elapsedSinceGuidance >= guidanceInterval, let frame = frame {
                let confidence = frame?.camera.trackingState == .limited ? 0.3 : 0.6
                let direction = relocalizationGuide.analyzeFrame(frame, confidence: confidence)
                
                if direction != .none {
                    await MainActor.run {
                        let progress = min(self.relocalizationProgress, 0.9)
                        self.relocalizationState = .failing(lookDirection: direction, progress: progress)
                    }
                }
                
                lastGuidanceUpdate = .now
            }
            
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
                    // Provide final directional guidance before failure.
                    if let frame = frame {
                        let direction = relocalizationGuide.analyzeFrame(frame, confidence: 0.1)
                        if direction != .none {
                            self.relocalizationState = .failing(lookDirection: direction, progress: 0.0)
                        } else {
                            self.relocalizationState = .failed
                        }
                    } else {
                        self.relocalizationState = .failed
                    }
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
    
    /// Monitor ARKit anchors for object anchor matches during relocalization.
    /// Continuously checks for new anchors and matches them against persisted
    /// fixture archetypes for faster relocalization.
    private func monitorObjectAnchorMatches() async {
        guard let session = arView?.session as? ARSession else { return }
        
        let checkInterval = Duration.milliseconds(500)
        let timeout = Duration.seconds(12)
        let startTime = ContinuousClock.now
        
        while !Task.isCancelled {
            let elapsed = ContinuousClock.now - startTime
            if elapsed >= timeout {
                break
            }
            
            // Check current anchors for object anchor matches.
            let anchors = session.currentFrame?.anchors ?? []
            let objectAnchorIDs = anchors.compactMap { anchor -> String? in
                if let objectAnchor = anchor as? ARObjectAnchor {
                    return objectAnchor.name
                }
                return nil
            }
            
            if !objectAnchorIDs.isEmpty {
                await MainActor.run {
                    self.objectAnchorService.matchObjectAnchors(to: objectAnchorIDs)
                }
                
                if objectAnchorService.isRelocalized {
                    break
                }
            }
            
            try? await Task.sleep(for: checkInterval)
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
        fixturePersistence.deleteObjectAnchors()
        objectAnchorService.clearAllArchetypes()
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
                    self.relocalizationGuide.reset()
                    logger.info("Relocalization completed from frame tracking")
                } else {
                    // Update feature density for trend analysis during relocalization.
                    let depthMap = frame.sceneDepth?.depthMap
                    if let depthMap = depthMap {
                        let density = self.computeFeatureDensity(depthMap)
                        self.relocalizationGuide.updateFeatureDensity(density)
                    }
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
    /// Also registers archetypal fixtures as object anchors for faster relocalization.
    func onFixtureLinked(_ fixture: TrackedFixture) async {
        // Update the fixture's mapped light ID
        if let idx = trackedFixtures.firstIndex(where: { $0.id == fixture.id }) {
            trackedFixtures[idx].mappedHueLightId = fixture.mappedHueLightId
        }
        
        // Register archetypal fixtures as object anchors for faster relocalization.
        // Archetypal types (Chandelier, Sconce, Desk Lamp, Pendant) benefit most
        // from object anchor tracking as ARKit can recognize their geometric signatures.
        let objectAnchorName = "fixture_\(fixture.type.rawValue)_\(fixture.id.uuidString.prefix(8))"
        objectAnchorService.registerArchetype(
            fixtureType: fixture.type,
            objectAnchorName: objectAnchorName,
            position: fixture.position,
            orientation: fixture.orientation,
            confidence: Float(fixture.confidence)
        )
        
        // Capture and save the world map for session persistence
        await captureAndSaveWorldMap()
    }
    
    /// Compute the feature density from a depth map.
    /// Returns a value between 0.0 and 1.0 representing the ratio of
    /// valid depth pixels to total pixels, indicating how many visual
    /// features are available for ARKit tracking.
    private func computeFeatureDensity(_ depthMap: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        
        guard let pointer = CVPixelBufferGetBaseAddress(depthMap) else {
            return 0.0
        }
        
        var validCount = 0
        let totalPixels = width * height
        
        // Sample a subset of pixels for performance (every 4th pixel).
        let stride = 4
        let sampleWidth = (width + stride - 1) / stride
        let sampleHeight = (height + stride - 1) / stride
        let totalSamples = sampleWidth * sampleHeight
        
        for y in stride.stride(to: height, by: stride) {
            for x in stride.stride(to: width, by: stride) {
                let byteOffset = y * bytesPerRow + x * 4
                let depthValue = Int32(pointer.load(fromByteOffset: byteOffset, as: Int32.self))
                
                // Valid depth values are positive and within reasonable range.
                if depthValue > 0 && depthValue < 65535 {
                    validCount += 1
                }
            }
        }
        
        return Float(validCount) / Float(totalSamples)
    }
    
}

/// Tracking state representation.
enum ARTrackingState: Sendable {
    case notAvailable
    case limited
    case tracking
}
