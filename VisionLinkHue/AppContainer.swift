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
        hudFactory: FixtureHUDFactory,
        provider: CameraConfigurationProvider,
        relocalizationGuide: RelocalizationGuide,
        relocalizationMonitor: RelocalizationMonitoringService,
        objectAnchorService: ObjectAnchorPersistenceService,
        clusterEngine: SpatialClusterEngine,
        detectionSettings: DetectionSettings
    ) -> ARSessionManager
}

/// Protocol for creating `MatterBridgeService` instances.
/// Enables dependency injection of mock Matter services in tests.
@MainActor
protocol MatterBridgeServiceFactory {
    func create() -> MatterBridgeService
}

/// Protocol for creating `MetricKitTelemetryService` instances.
/// Enables dependency injection of mock telemetry services in tests.
@MainActor
protocol MetricKitTelemetryServiceFactory {
    func create() -> MetricKitTelemetryService
}

/// Default implementations of all factory protocols.
/// Used by `AppContainer` for production dependency creation.
@MainActor
class DefaultFactories: @unchecked Sendable {
    
    let stateStreamFactory: HueStateStreamFactory
    let hueClientFactory: HueClientFactory
    let detectionEngineFactory: DetectionEngineFactory
    let spatialProjectorFactory: SpatialProjectorFactory
    let arSessionManagerFactory: ARSessionManagerFactory
    let matterBridgeServiceFactory: MatterBridgeServiceFactory
    let metricKitTelemetryFactory: MetricKitTelemetryServiceFactory
    
    init(
        stateStreamFactory: HueStateStreamFactory = DefaultHueStateStreamFactory(),
        hueClientFactory: HueClientFactory = DefaultHueClientFactory(),
        detectionEngineFactory: DetectionEngineFactory = DefaultDetectionEngineFactory(),
        spatialProjectorFactory: SpatialProjectorFactory = DefaultSpatialProjectorFactory(),
        arSessionManagerFactory: ARSessionManagerFactory = DefaultARSessionManagerFactory(),
        matterBridgeServiceFactory: MatterBridgeServiceFactory = DefaultMatterBridgeServiceFactory(),
        metricKitTelemetryFactory: MetricKitTelemetryServiceFactory = DefaultMetricKitTelemetryServiceFactory()
    ) {
        self.stateStreamFactory = stateStreamFactory
        self.hueClientFactory = hueClientFactory
        self.detectionEngineFactory = detectionEngineFactory
        self.spatialProjectorFactory = spatialProjectorFactory
        self.arSessionManagerFactory = arSessionManagerFactory
        self.matterBridgeServiceFactory = matterBridgeServiceFactory
        self.metricKitTelemetryFactory = metricKitTelemetryFactory
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
        hudFactory: FixtureHUDFactory,
        provider: CameraConfigurationProvider,
        relocalizationGuide: RelocalizationGuide,
        relocalizationMonitor: RelocalizationMonitoringService,
        objectAnchorService: ObjectAnchorPersistenceService,
        clusterEngine: SpatialClusterEngine,
        detectionSettings: DetectionSettings
    ) -> ARSessionManager {
        ARSessionManager(
            detectionEngine: detectionEngine,
            spatialProjector: spatialProjector,
            hueClient: hueClient,
            stateStream: stateStream,
            fixturePersistence: fixturePersistence,
            hudFactory: hudFactory,
            provider: provider,
            relocalizationGuide: relocalizationGuide,
            relocalizationMonitor: relocalizationMonitor,
            objectAnchorService: objectAnchorService,
            clusterEngine: clusterEngine,
            detectionSettings: detectionSettings
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

/// Default factory for `MetricKitTelemetryService`.
@MainActor
final class DefaultMetricKitTelemetryServiceFactory: MetricKitTelemetryServiceFactory {
    func create() -> MetricKitTelemetryService {
        MetricKitTelemetryService()
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
    let telemetryService: MetricKitTelemetryService
    let detectionSettings: DetectionSettings
    
    private let factories: DefaultFactories
    
    init(factories: DefaultFactories = DefaultFactories()) {
        self.factories = factories
        
        let persistence = FixturePersistence.shared
        let detectionSettings = DetectionSettings()
        self.detectionSettings = detectionSettings
        let objectAnchorService = ObjectAnchorPersistenceService(detectionSettings: detectionSettings)
        let relocalizationGuide = RelocalizationGuide()
        let relocalizationMonitor = RelocalizationMonitoringService()
        
        // Create dependencies through factories for testability.
        let stream = factories.stateStreamFactory.create(persistence: persistence)
        let client = factories.hueClientFactory.create(stateStream: stream)
        let detector = factories.detectionEngineFactory.create(stateStream: stream, detectionSettings: detectionSettings)
        let projector = factories.spatialProjectorFactory.create()
        let clusterEngine = SpatialClusterEngine()
        
        let hudFactory = FixtureHUDFactory()
        let cameraProvider = DefaultCameraConfigurationProvider()
        
        let manager = factories.arSessionManagerFactory.create(
            detectionEngine: detector,
            spatialProjector: projector,
            hueClient: client,
            stateStream: stream,
            fixturePersistence: persistence,
            hudFactory: hudFactory,
            provider: cameraProvider,
            relocalizationGuide: relocalizationGuide,
            relocalizationMonitor: relocalizationMonitor,
            objectAnchorService: objectAnchorService,
            clusterEngine: clusterEngine,
            detectionSettings: detectionSettings
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
        
        let telemetryService = factories.metricKitTelemetryFactory.create()
        detector.configureTelemetryService(telemetryService)
        
        self.stateStream = stream
        self.hueClient = client
        self.detectionEngine = detector
        self.arSessionManager = manager
        self.spatialProjector = projector
        self.gestureManager = gestureManager
        self.matterService = matterService
        self.telemetryService = telemetryService
    }
}
