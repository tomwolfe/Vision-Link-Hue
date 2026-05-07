import SwiftUI
import ARKit

/// Protocol for creating `HueStateStream` instances.
/// Enables dependency injection of mock streams in tests.
@MainActor
protocol HueStateStreamFactory {
    func create(persistence: FixturePersistence) -> HueStateStream
}

/// Protocol for creating `HueClient` instances.
/// Enables dependency injection of mock clients in tests.
@MainActor
protocol HueClientFactory {
    func create(stateStream: HueStateStream) -> HueClient
}

/// Protocol for creating `DetectionEngine` instances.
/// The factory returns the concrete type so that `AppContainer` can wire
/// up callbacks like `configureARSessionPauseHandler` and `configureTelemetryService`.
/// The `DetectionProvider` protocol abstracts the interface for `ARSessionManager`,
/// enabling a future "Core AI" swap without refactoring the session manager.
@MainActor
protocol DetectionEngineFactory {
    func create(stateStream: HueStateStream, detectionSettings: DetectionSettings) -> DetectionEngine
}

/// Protocol for creating `SpatialProjector` instances.
/// Enables dependency injection of mock projectors in tests.
@MainActor
protocol SpatialProjectorFactory {
    func create() -> SpatialProjector
}

/// Protocol for creating `ARSessionManager` instances.
/// Enables dependency injection of mock managers for tests.
@MainActor
protocol ARSessionManagerFactory {
    func create(
        detectionEngine: DetectionEngine,
        spatialProjector: SpatialProjector,
        hueClient: HueClient,
        stateStream: HueStateStream,
        fixturePersistence: FixturePersistence,
        objectAnchorService: ObjectAnchorPersistenceService,
        clusterEngine: SpatialClusterEngine,
        detectionSettings: DetectionSettings,
        relocalizationMonitor: RelocalizationMonitoringService
    ) -> ARSessionManager
}

/// Protocol for creating `MatterBridgeService` instances.
/// Enables dependency injection of mock Matter services in tests.
@MainActor
protocol MatterBridgeServiceFactory {
    func create() -> MatterBridgeService
}

/// Protocol for creating `SpatialSyncService` instances.
/// Enables dependency injection of mock sync services in tests.
@MainActor
protocol SpatialSyncServiceFactory {
    func create() -> SpatialSyncService
}

/// Protocol for creating `MetricKitTelemetryService` instances.
/// Enables dependency injection of mock telemetry services in tests.
@MainActor
protocol MetricKitTelemetryServiceFactory {
    func create() -> MetricKitTelemetryService
}

/// Protocol for creating `LocalSyncActor` instances.
/// Enables dependency injection of mock local sync actors in tests.
@MainActor
protocol LocalSyncActorFactory {
    func create() -> LocalSyncActor
}

/// Default implementations of all factory protocols.
/// Used by `AppContainer` for production dependency creation.
@MainActor
final class DefaultFactories: @unchecked Sendable {
    
    let stateStreamFactory: HueStateStreamFactory
    let hueClientFactory: HueClientFactory
    let detectionEngineFactory: DetectionEngineFactory
    let spatialProjectorFactory: SpatialProjectorFactory
    let arSessionManagerFactory: ARSessionManagerFactory
    let matterBridgeServiceFactory: MatterBridgeServiceFactory
    let spatialSyncServiceFactory: SpatialSyncServiceFactory
    let metricKitTelemetryFactory: MetricKitTelemetryServiceFactory
    let localSyncActorFactory: LocalSyncActorFactory
    
    init(
        stateStreamFactory: HueStateStreamFactory = DefaultHueStateStreamFactory(),
        hueClientFactory: HueClientFactory = DefaultHueClientFactory(),
        detectionEngineFactory: DetectionEngineFactory = DefaultDetectionEngineFactory(),
        spatialProjectorFactory: SpatialProjectorFactory = DefaultSpatialProjectorFactory(),
        arSessionManagerFactory: ARSessionManagerFactory = DefaultARSessionManagerFactory(),
        matterBridgeServiceFactory: MatterBridgeServiceFactory = DefaultMatterBridgeServiceFactory(),
        spatialSyncServiceFactory: SpatialSyncServiceFactory = DefaultSpatialSyncServiceFactory(),
        metricKitTelemetryFactory: MetricKitTelemetryServiceFactory = DefaultMetricKitTelemetryServiceFactory(),
        localSyncActorFactory: LocalSyncActorFactory = DefaultLocalSyncActorFactory()
    ) {
        self.stateStreamFactory = stateStreamFactory
        self.hueClientFactory = hueClientFactory
        self.detectionEngineFactory = detectionEngineFactory
        self.spatialProjectorFactory = spatialProjectorFactory
        self.arSessionManagerFactory = arSessionManagerFactory
        self.matterBridgeServiceFactory = matterBridgeServiceFactory
        self.spatialSyncServiceFactory = spatialSyncServiceFactory
        self.metricKitTelemetryFactory = metricKitTelemetryFactory
        self.localSyncActorFactory = localSyncActorFactory
    }
}

/// Default factory for `HueStateStream`.
@MainActor
final class DefaultHueStateStreamFactory: HueStateStreamFactory {
    func create(persistence: FixturePersistence) -> HueStateStream {
        let stream = HueStateStream(persistence: persistence)
        stream.configure()
        return stream
    }
}

/// Default factory for `HueClient`.
@MainActor
final class DefaultHueClientFactory: HueClientFactory {
    func create(stateStream: HueStateStream) -> HueClient {
        let client = HueClient(stateStream: stateStream)
        client.spatialService?.setHueClient(client)
        return client
    }
}

/// Default factory for `DetectionEngine`.
@MainActor
final class DefaultDetectionEngineFactory: DetectionEngineFactory {
    func create(stateStream: HueStateStream, detectionSettings: DetectionSettings) -> DetectionEngine {
        DetectionEngine(stateStream: stateStream, detectionSettings: detectionSettings)
    }
}

/// Default factory for `SpatialProjector`.
@MainActor
final class DefaultSpatialProjectorFactory: SpatialProjectorFactory {
    func create() -> SpatialProjector {
        SpatialProjector()
    }
}

/// Default factory for `ARSessionManager`.
@MainActor
final class DefaultARSessionManagerFactory: ARSessionManagerFactory {
    func create(
        detectionEngine: DetectionEngine,
        spatialProjector: SpatialProjector,
        hueClient: HueClient,
        stateStream: HueStateStream,
        fixturePersistence: FixturePersistence,
        objectAnchorService: ObjectAnchorPersistenceService,
        clusterEngine: SpatialClusterEngine,
        detectionSettings: DetectionSettings,
        relocalizationMonitor: RelocalizationMonitoringService
    ) -> ARSessionManager {
        ARSessionManager(
            detectionEngine: detectionEngine,
            spatialProjector: spatialProjector,
            hueClient: hueClient,
            stateStream: stateStream,
            fixturePersistence: fixturePersistence,
            objectAnchorService: objectAnchorService,
            clusterEngine: clusterEngine,
            detectionSettings: detectionSettings,
            relocalizationMonitor: relocalizationMonitor
        )
    }
}

/// Default factory for `MatterBridgeService`.
@MainActor
final class DefaultMatterBridgeServiceFactory: MatterBridgeServiceFactory {
    func create() -> MatterBridgeService {
        MatterBridgeService()
    }
}

/// Default factory for `SpatialSyncService`.
@MainActor
final class DefaultSpatialSyncServiceFactory: SpatialSyncServiceFactory {
    func create() -> SpatialSyncService {
        SpatialSyncService.shared
    }
}

/// Default factory for `MetricKitTelemetryService`.
@MainActor
final class DefaultMetricKitTelemetryServiceFactory: MetricKitTelemetryServiceFactory {
    func create() -> MetricKitTelemetryService {
        MetricKitTelemetryService()
    }
}

/// Default factory for `LocalSyncActor`.
@MainActor
final class DefaultLocalSyncActorFactory: LocalSyncActorFactory {
    func create() -> LocalSyncActor {
        LocalSyncActor()
    }
}

/// Centralized dependency injection container for the application.
/// Initializes all core services once at app launch and provides
/// deterministic access to dependencies throughout the view hierarchy.
///
/// Uses protocol-based factories for creating dependencies, enabling
/// deep unit testing of the View layer with mock implementations.
@MainActor
final class AppContainer {
    
    static let shared = AppContainer()
    
    let stateStream: HueStateStream
    let hueClient: HueClient
    let detectionEngine: DetectionEngine
    let arSessionManager: ARSessionManager
    let spatialProjector: SpatialProjector
    let gestureManager: GestureManager
    let matterService: MatterBridgeService
    let spatialSyncService: SpatialSyncService
    let telemetryService: MetricKitTelemetryService
    let localSyncActor: LocalSyncActor
    let detectionSettings: DetectionSettings
    let relocalizationMonitor: RelocalizationMonitoringService
    
    private let factories: DefaultFactories
    
    private init(factories: DefaultFactories = DefaultFactories()) {
        self.factories = factories
        
        let persistence = FixturePersistence.shared
        let detectionSettings = DetectionSettings()
        self.detectionSettings = detectionSettings
        let objectAnchorService = ObjectAnchorPersistenceService(detectionSettings: detectionSettings)
        let relocalizationMonitor = RelocalizationMonitoringService()
        
        // Create dependencies through factories for testability.
        let stream = factories.stateStreamFactory.create(persistence: persistence)
        let client = factories.hueClientFactory.create(stateStream: stream)
        let detector = factories.detectionEngineFactory.create(stateStream: stream, detectionSettings: detectionSettings)
        let projector = factories.spatialProjectorFactory.create()
        let clusterEngine = SpatialClusterEngine()
        
        let manager = factories.arSessionManagerFactory.create(
            detectionEngine: detector,
            spatialProjector: projector,
            hueClient: client,
            stateStream: stream,
            fixturePersistence: persistence,
            objectAnchorService: objectAnchorService,
            clusterEngine: clusterEngine,
            detectionSettings: detectionSettings,
            relocalizationMonitor: relocalizationMonitor
        )
        
        // Wire the ARSession pause/resume callback to the detection engine.
        // This prevents memory spikes on A13+ devices when loading an unquantized
        // CoreML model while ARKit Neural Surface Synthesis is running.
        detector.configureARSessionPauseHandler { [weak manager] shouldPause in
            guard let manager else { return }
            Task { @MainActor in
                if shouldPause {
                    manager.pauseForMemoryPressure()
                } else {
                    manager.resumeAfterMemoryPressure()
                }
            }
        }
        
        // Wire up calibration persistence to the spatial service's engine
        let keychainManager = KeychainManager()
        let calibrationStore = KeychainCalibrationStore(keychainManager: keychainManager)
        client.spatialService?.calibrationEngine.persistenceStore = calibrationStore
        
        // Wire up GestureManager for haptic feedback during calibration.
        // The calibration engine's onCalibrationPointAdded callback triggers
        // a transient double-tap haptic pattern to confirm point registration
        // without requiring the user to look away from the fixture.
        let gestureManager = GestureManager()
        client.spatialService?.calibrationEngine.onCalibrationPointAdded = {
            gestureManager.provideCalibrationPointHaptic()
        }
        
        let matterService = factories.matterBridgeServiceFactory.create()
        client.matterService = matterService
        
        let spatialSyncService = factories.spatialSyncServiceFactory.create()
        
        let telemetryService = factories.metricKitTelemetryFactory.create()
        let localSyncActor = factories.localSyncActorFactory.create()
        
        // Wire up telemetry service to detection engine for inference latency reporting.
        // Telemetry records are collected periodically and submitted via MetricKit
        // for correlation with real-world device thermals across A15-M4 chips.
        detector.configureTelemetryService(telemetryService)
        
        // Wire up local sync actor for P2P spatial data sharing.
        // Provides real-time coordinate sharing between Vision Pro and iPhone
        // on the local network, bypassing CloudKit latency.
        localSyncActor.onSpatialSyncReceived = { [weak spatialSyncService] payload in
            guard let syncService = spatialSyncService else { return }
            Task {
                await syncService.applyRemoteSpatialSync(payload)
            }
        }
        
        // Start local sync actor for P2P discovery.
        Task {
            try? await localSyncActor.start()
            await localSyncActor.discoverPeers()
        }
        
        self.stateStream = stream
        self.hueClient = client
        self.detectionEngine = detector
        self.arSessionManager = manager
        self.spatialProjector = projector
        self.gestureManager = gestureManager
        self.matterService = matterService
        self.spatialSyncService = spatialSyncService
        self.telemetryService = telemetryService
        self.localSyncActor = localSyncActor
        self.relocalizationMonitor = relocalizationMonitor
    }
}
