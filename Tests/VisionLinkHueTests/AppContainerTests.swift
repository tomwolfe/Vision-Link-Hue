import XCTest
import ARKit
@testable import VisionLinkHue

/// Unit tests for the AppContainer factory-based dependency injection pattern.
/// Validates that factory protocols can be implemented with custom/mock
/// factories for testability.
@MainActor
final class AppContainerTests: XCTestCase {
    
    // MARK: - Factory Protocol Tests
    
    @MainActor
    func testDefaultHueStateStreamFactoryCreatesStream() {
        let factory = DefaultHueStateStreamFactory()
        let persistence = FixturePersistence.shared
        
        let stream = factory.create(persistence: persistence)
        XCTAssertNotNil(stream)
        XCTAssertTrue(stream is HueStateStream)
    }
    
    @MainActor
    func testDefaultHueClientFactoryCreatesClient() {
        let factory = DefaultHueClientFactory()
        let persistence = FixturePersistence.shared
        let stream = HueStateStream(persistence: persistence)
        stream.configure()
        
        let client = factory.create(stateStream: stream)
        XCTAssertNotNil(client)
        XCTAssertTrue(client is HueClient)
    }
    
    @MainActor
    func testDefaultDetectionEngineFactoryCreatesEngine() {
        let factory = DefaultDetectionEngineFactory()
        let persistence = FixturePersistence.shared
        let stream = HueStateStream(persistence: persistence)
        let settings = DetectionSettings()
        let engine = factory.create(stateStream: stream, detectionSettings: settings)
        XCTAssertNotNil(engine)
        XCTAssertTrue(engine is DetectionEngine)
    }
    
    @MainActor
    func testDefaultSpatialProjectorFactoryCreatesProjector() {
        let factory = DefaultSpatialProjectorFactory()
        let projector = factory.create()
        XCTAssertNotNil(projector)
        XCTAssertTrue(projector is SpatialProjector)
    }
    
    @MainActor
    func testDefaultARSessionManagerFactoryCreatesManager() {
        let factory = DefaultARSessionManagerFactory()
        let persistence = FixturePersistence.shared
        let stream = HueStateStream(persistence: persistence)
        stream.configure()
        let client = HueClient(stateStream: stream)
        let engine = DetectionEngine(stateStream: stream)
        let projector = SpatialProjector()
        let settings = DetectionSettings()
        
        let manager = factory.create(
            detectionEngine: engine,
            spatialProjector: projector,
            hueClient: client,
            stateStream: stream,
            fixturePersistence: persistence,
            objectAnchorService: ObjectAnchorPersistenceService(detectionSettings: settings),
            clusterEngine: SpatialClusterEngine(),
            detectionSettings: settings,
            relocalizationMonitor: RelocalizationMonitoringService()
        )
        XCTAssertNotNil(manager)
        XCTAssertTrue(manager is ARSessionManager)
    }
    
    // MARK: - Custom Factory Tests
    
    func testCustomFactoryProtocolImplementation() {
        // Verify that a custom factory can conform to the protocol.
        let customFactory = MockHueClientFactory()
        let persistence = FixturePersistence.shared
        let stream = HueStateStream(persistence: persistence)
        stream.configure()
        let client = customFactory.create(stateStream: stream)
        XCTAssertNotNil(client)
        XCTAssertTrue(client is HueClient)
    }
    
    func testAppContainerUsesFactories() {
        // The shared container should be creatable via the default factories.
        let container = AppContainer()
        XCTAssertNotNil(container.stateStream)
        XCTAssertNotNil(container.hueClient)
        XCTAssertNotNil(container.detectionEngine)
        XCTAssertNotNil(container.arSessionManager)
        XCTAssertNotNil(container.spatialProjector)
        XCTAssertNotNil(container.detectionSettings)
    }
    
    func testAppContainerWithCustomFactories() {
        let customFactories = MockAllFactories()
        let container = AppContainer(factories: customFactories)
        XCTAssertNotNil(container.stateStream)
        XCTAssertNotNil(container.hueClient)
        XCTAssertNotNil(container.detectionEngine)
        XCTAssertNotNil(container.arSessionManager)
        XCTAssertNotNil(container.spatialProjector)
    }
    
    // MARK: - Helper Classes
    
    private final class MockHueClientFactory: HueClientFactory {
        func create(stateStream: HueStateStream) -> HueClient {
            HueClient(stateStream: stateStream)
        }
    }
    
    private final class MockAllFactories: DefaultFactories {
        override init(
            stateStreamFactory: HueStateStreamFactory = MockStateStreamFactory(),
            hueClientFactory: HueClientFactory = MockHueClientFactory(),
            detectionEngineFactory: DetectionEngineFactory = MockDetectionEngineFactory(),
            spatialProjectorFactory: SpatialProjectorFactory = MockSpatialProjectorFactory(),
            arSessionManagerFactory: ARSessionManagerFactory = MockARSessionManagerFactory(),
            matterBridgeServiceFactory: MatterBridgeServiceFactory = MockMatterBridgeServiceFactory(),
            metricKitTelemetryFactory: MetricKitTelemetryServiceFactory = MockMetricKitTelemetryFactory()
        ) {
            super.init(
                stateStreamFactory: stateStreamFactory,
                hueClientFactory: hueClientFactory,
                detectionEngineFactory: detectionEngineFactory,
                spatialProjectorFactory: spatialProjectorFactory,
                arSessionManagerFactory: arSessionManagerFactory,
                matterBridgeServiceFactory: matterBridgeServiceFactory,
                metricKitTelemetryFactory: metricKitTelemetryFactory
            )
        }
    }
    
    private final class MockStateStreamFactory: HueStateStreamFactory {
        func create(persistence: FixturePersistence) -> HueStateStream {
            let stream = HueStateStream(persistence: persistence)
            stream.configure()
            return stream
        }
    }
    
    private final class MockDetectionEngineFactory: DetectionEngineFactory {
        func create(stateStream: HueStateStream, detectionSettings: DetectionSettings) -> DetectionEngine {
            DetectionEngine(stateStream: stateStream, detectionSettings: detectionSettings)
        }
    }
    
    private final class MockSpatialProjectorFactory: SpatialProjectorFactory {
        func create() -> SpatialProjector {
            SpatialProjector()
        }
    }
    
    private final class MockARSessionManagerFactory: ARSessionManagerFactory {
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
    
    private final class MockMatterBridgeServiceFactory: MatterBridgeServiceFactory {
        func create() -> MatterBridgeService {
            MatterBridgeService()
        }
    }
    
    private final class MockMetricKitTelemetryFactory: MetricKitTelemetryServiceFactory {
        func create() -> MetricKitTelemetryService {
            MetricKitTelemetryService()
        }
    }
}
