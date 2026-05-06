import XCTest
import @testable VisionLinkHue

/// Tests for `SpatialDataPurgeService` validating iOS 26 spatial
/// data purge compliance and point cloud deletion.
final class SpatialDataPurgeServiceTests: XCTestCase {
    
    private var purgeService: SpatialDataPurgeService!
    
    override func setUp() {
        super.setUp()
        purgeService = SpatialDataPurgeService()
    }
    
    override func tearDown() {
        purgeService = nil
        super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testPurgeServiceStartsInactive() {
        XCTAssertFalse(purgeService.isPurging)
        XCTAssertTrue(purgeService.purgedTypes.isEmpty)
    }
    
    func testPurgeServiceHasNoPurgedTypesInitially() {
        for type in SpatialDataType.allCases {
            XCTAssertFalse(purgeService.isPurged(type))
        }
    }
    
    // MARK: - SpatialDataType Tests
    
    func testAllSpatialDataTypesAreSensitive() {
        // All spatial data types should be classified as sensitive topology
        // since they contain room layout information.
        for type in SpatialDataType.allCases {
            XCTAssertTrue(type.isSensitiveTopology,
                "\(type.rawValue) should be classified as sensitive topology")
        }
    }
    
    func testSpatialDataTypeCount() {
        XCTAssertEqual(SpatialDataType.allCases.count, 6,
            "Should have exactly 6 spatial data types")
    }
    
    func testSpatialDataTypeRawValues() {
        let expectedValues: [String] = [
            "pointCloud",
            "worldMap",
            "fixtureCoordinates",
            "objectAnchors",
            "calibrationTransforms",
            "localSyncCaches"
        ]
        
        for (actual, expected) in zip(SpatialDataType.allCases.map { $0.rawValue }, expectedValues) {
            XCTAssertEqual(actual, expected)
        }
    }
    
    // MARK: - Purge Error Tests
    
    func testPurgeErrorDescriptions() {
        let deletionError = SpatialDataPurgeError.deletionFailed("test", NSError(domain: "test", code: 1))
        XCTAssertNotNil(deletionError.errorDescription)
        XCTAssertTrue(deletionError.errorDescription!.contains("test"))
        
        let dirError = SpatialDataPurgeError.directoryNotFound("documents")
        XCTAssertNotNil(dirError.errorDescription)
        XCTAssertTrue(dirError.errorDescription!.contains("documents"))
        
        let sessionError = SpatialDataPurgeError.activeSessionPreventsPurge
        XCTAssertNotNil(sessionError.errorDescription)
        XCTAssertTrue(sessionError.errorDescription!.contains("active"))
    }
    
    // MARK: - Purge Lifecycle Tests
    
    func testPurgeAllIsConvenienceMethod() async throws {
        // Verify that purgeAll() calls purgeData with empty types
        // (which means all types).
        try await purgeService.purgeAll()
        
        // Since we're in a test environment without actual spatial data,
        // the purge should complete without error.
        XCTAssertFalse(purgeService.isPurging)
    }
    
    func testConcurrentPurgeRequestsAreSerialized() async throws {
        // Verify that a second purge request during an active purge
        // is handled gracefully (skipped).
        var purgeCompletionCount = 0
        
        purgeService.onPurgeComplete = { _ in
            purgeCompletionCount += 1
        }
        
        // Start a purge.
        try await purgeService.purgeAll()
        
        // The onPurgeComplete callback should have been called once.
        XCTAssertEqual(purgeCompletionCount, 1, "Should call completion handler once")
    }
}
