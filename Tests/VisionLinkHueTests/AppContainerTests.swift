import XCTest
import @testable VisionLinkHue

/// Unit tests for the AppContainer factory-based dependency injection pattern.
/// Validates that factory protocols can be implemented with custom/mock
/// factories for testability.
final class AppContainerTests: XCTestCase {
    
    // MARK: - Factory Protocol Tests
    
    func testDefaultHueStateStreamFactoryCreatesStream() {
        let factory = DefaultHueStateStreamFactory()
        let persistence = FixturePersistence.shared
        
        let stream = factory.create(persistence: persistence)
        XCTAssertNotNil(stream)
        XCTAssertTrue(stream is HueStateStream)
    }
    
    func testDefaultHueClientFactoryCreatesClient() {
        let factory = DefaultHueClientFactory()
        let persistence = FixturePersistence.shared
        let stream = HueStateStream(persistence: persistence)
        stream.configure()
        
        let client = factory.create(stateStream: stream)
        XCTAssertNotNil(client)
        XCTAssertTrue(client is HueClient)
    }
    
    func testDefaultDetectionEngineFactoryCreatesEngine() {
        let factory = DefaultDetectionEngineFactory()
        let persistence = FixturePersistence.shared
        let stream = HueStateStream(persistence: persistence)
        let engine = factory.create(stateStream: stream)
        XCTAssertNotNil(engine)
        XCTAssertTrue(engine is DetectionEngine)
    }
    
    func testDefaultSpatialProjectorFactoryCreatesProjector() {
        let factory = DefaultSpatialProjectorFactory()
        let projector = factory.create()
        XCTAssertNotNil(projector)
        XCTAssertTrue(projector is SpatialProjector)
    }
    
    func testDefaultARSessionManagerFactoryCreatesManager() {
        let factory = DefaultARSessionManagerFactory()
        let persistence = FixturePersistence.shared
        let stream = HueStateStream(persistence: persistence)
        stream.configure()
        let client = HueClient(stateStream: stream)
        let engine = DetectionEngine(stateStream: stream)
        let projector = SpatialProjector()
        
        let manager = factory.create(
            detectionEngine: engine,
            spatialProjector: projector,
            hueClient: client,
            stateStream: stream,
            fixturePersistence: persistence
        )
        XCTAssertNotNil(manager)
        XCTAssertTrue(manager is ARSessionManager)
    }
    
    // MARK: - Custom Factory Tests
    
    func testCustomFactoryProtocolImplementation() {
        // Verify that a custom factory can conform to the protocol.
        let customFactory = MockHueClientFactory()
        let client = customFactory.create(stateStream: MockHueClient())
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
    }
    
    func testAppContainerWithCustomFactories() {
        let customFactory = MockAllFactory()
        let container = AppContainer(factories: customFactory)
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
    
    private final class MockAllFactory: DefaultFactories {
        override init(
            stateStreamFactory: HueStateStreamFactory = MockStateStreamFactory(),
            hueClientFactory: HueClientFactory = MockHueClientFactory(),
            detectionEngineFactory: DetectionEngineFactory = MockDetectionEngineFactory(),
            spatialProjectorFactory: SpatialProjectorFactory = MockSpatialProjectorFactory(),
            arSessionManagerFactory: ARSessionManagerFactory = MockARSessionManagerFactory()
        ) {
            super.init(
                stateStreamFactory: stateStreamFactory,
                hueClientFactory: hueClientFactory,
                detectionEngineFactory: detectionEngineFactory,
                spatialProjectorFactory: spatialProjectorFactory,
                arSessionManagerFactory: arSessionManagerFactory
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
        func create(stateStream: HueStateStream) -> DetectionEngine {
            DetectionEngine(stateStream: stateStream)
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
            fixturePersistence: FixturePersistence
        ) -> ARSessionManager {
            ARSessionManager(
                detectionEngine: detectionEngine,
                spatialProjector: spatialProjector,
                hueClient: hueClient,
                stateStream: stateStream,
                fixturePersistence: fixturePersistence
            )
        }
    }
}
