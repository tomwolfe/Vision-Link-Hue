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
/// Enables dependency injection of mock engines in tests.
@MainActor
protocol DetectionEngineFactory {
    func create() -> DetectionEngine
}

/// Protocol for creating `SpatialProjector` instances.
/// Enables dependency injection of mock projectors in tests.
@MainActor
protocol SpatialProjectorFactory {
    func create() -> SpatialProjector
}

/// Protocol for creating `ARSessionManager` instances.
/// Enables dependency injection of mock managers in tests.
@MainActor
protocol ARSessionManagerFactory {
    func create(
        detectionEngine: DetectionEngine,
        spatialProjector: SpatialProjector,
        hueClient: HueClient,
        stateStream: HueStateStream,
        fixturePersistence: FixturePersistence,
        objectAnchorService: ObjectAnchorPersistenceService,
        clusterEngine: SpatialClusterEngine
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
    
    init(
        stateStreamFactory: HueStateStreamFactory = DefaultHueStateStreamFactory(),
        hueClientFactory: HueClientFactory = DefaultHueClientFactory(),
        detectionEngineFactory: DetectionEngineFactory = DefaultDetectionEngineFactory(),
        spatialProjectorFactory: SpatialProjectorFactory = DefaultSpatialProjectorFactory(),
        arSessionManagerFactory: ARSessionManagerFactory = DefaultARSessionManagerFactory(),
        matterBridgeServiceFactory: MatterBridgeServiceFactory = DefaultMatterBridgeServiceFactory(),
        spatialSyncServiceFactory: SpatialSyncServiceFactory = DefaultSpatialSyncServiceFactory()
    ) {
        self.stateStreamFactory = stateStreamFactory
        self.hueClientFactory = hueClientFactory
        self.detectionEngineFactory = detectionEngineFactory
        self.spatialProjectorFactory = spatialProjectorFactory
        self.arSessionManagerFactory = arSessionManagerFactory
        self.matterBridgeServiceFactory = matterBridgeServiceFactory
        self.spatialSyncServiceFactory = spatialSyncServiceFactory
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
    func create() -> DetectionEngine {
        DetectionEngine()
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
        clusterEngine: SpatialClusterEngine
    ) -> ARSessionManager {
        ARSessionManager(
            detectionEngine: detectionEngine,
            spatialProjector: spatialProjector,
            hueClient: hueClient,
            stateStream: stateStream,
            fixturePersistence: fixturePersistence,
            objectAnchorService: objectAnchorService,
            clusterEngine: clusterEngine
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
        SpatialSyncService()
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
    let matterService: MatterBridgeService
    let spatialSyncService: SpatialSyncService
    
    private let factories: DefaultFactories
    
    private init(factories: DefaultFactories = DefaultFactories()) {
        self.factories = factories
        
        let persistence = FixturePersistence.shared
        let objectAnchorService = ObjectAnchorPersistenceService()
        
        // Create dependencies through factories for testability.
        let stream = factories.stateStreamFactory.create(persistence: persistence)
        let client = factories.hueClientFactory.create(stateStream: stream)
        let detector = factories.detectionEngineFactory.create()
        let projector = factories.spatialProjectorFactory.create()
        let clusterEngine = SpatialClusterEngine()
        
        let manager = factories.arSessionManagerFactory.create(
            detectionEngine: detector,
            spatialProjector: projector,
            hueClient: client,
            stateStream: stream,
            fixturePersistence: persistence,
            objectAnchorService: objectAnchorService,
            clusterEngine: clusterEngine
        )
        
        // Wire up calibration persistence to the spatial service's engine
        let keychainManager = KeychainManager()
        let calibrationStore = KeychainCalibrationStore(keychainManager: keychainManager)
        client.spatialService?.calibrationEngine.persistenceStore = calibrationStore
        
        let matterService = factories.matterBridgeServiceFactory.create()
        client.matterService = matterService
        
        let spatialSyncService = factories.spatialSyncServiceFactory.create()
        
        self.stateStream = stream
        self.hueClient = client
        self.detectionEngine = detector
        self.arSessionManager = manager
        self.spatialProjector = projector
        self.matterService = matterService
        self.spatialSyncService = spatialSyncService
    }
}
