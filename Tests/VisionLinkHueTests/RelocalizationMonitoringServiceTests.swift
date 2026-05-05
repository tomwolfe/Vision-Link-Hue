import XCTest
import @testable VisionLinkHue

/// Unit tests for `RelocalizationMonitoringService`.
///
/// Verifies that the service correctly tracks ARWorldMap vs ObjectAnchor
/// relocalization attempts, computes success rates, and provides correct
/// recommendations for Extended Relocalization Mode.
final class RelocalizationMonitoringServiceTests: XCTestCase {
    
    private var monitor: RelocalizationMonitoringService!
    
    override func setUp() {
        super.setUp()
        monitor = RelocalizationMonitoringService()
    }
    
    override func tearDown() {
        monitor = nil
        super.tearDown()
    }
    
    // MARK: - Initial State Tests
    
    func testInitialSuccessRatesAreZero() {
        XCTAssertEqual(monitor.worldMapSuccessRate, 0.0)
        XCTAssertEqual(monitor.objectAnchorSuccessRate, 0.0)
        XCTAssertEqual(monitor.worldMapAverageTime, 0.0)
        XCTAssertEqual(monitor.objectAnchorAverageTime, 0.0)
        XCTAssertFalse(monitor.objectAnchorPreferred)
    }
    
    // MARK: - ARWorldMap Recording Tests
    
    func testRecordWorldMapAttemptIncrementsAttempts() {
        monitor.recordWorldMapAttempt()
        monitor.recordWorldMapAttempt()
        monitor.recordWorldMapAttempt()
        
        XCTAssertEqual(monitor.worldMapAttempts, 3)
        XCTAssertEqual(monitor.worldMapSuccesses, 0)
    }
    
    func testRecordWorldMapSuccessIncrementsSuccessAndTime() {
        monitor.recordWorldMapAttempt()
        monitor.recordWorldMapSuccess(elapsedTime: 2.5)
        
        XCTAssertEqual(monitor.worldMapAttempts, 1)
        XCTAssertEqual(monitor.worldMapSuccesses, 1)
        XCTAssertEqual(monitor.worldMapTotalTime, 2.5, accuracy: 0.001)
        XCTAssertEqual(monitor.worldMapSuccessRate, 1.0)
        XCTAssertEqual(monitor.worldMapAverageTime, 2.5, accuracy: 0.001)
    }
    
    func testRecordWorldMapFailureOnlyIncrementsAttempts() {
        monitor.recordWorldMapAttempt()
        monitor.recordWorldMapFailure()
        
        XCTAssertEqual(monitor.worldMapAttempts, 1)
        XCTAssertEqual(monitor.worldMapSuccesses, 0)
        XCTAssertEqual(monitor.worldMapSuccessRate, 0.0)
    }
    
    func testMultipleWorldMapSuccessesComputeCorrectAverage() {
        monitor.recordWorldMapAttempt()
        monitor.recordWorldMapSuccess(elapsedTime: 2.0)
        
        monitor.recordWorldMapAttempt()
        monitor.recordWorldMapSuccess(elapsedTime: 4.0)
        
        XCTAssertEqual(monitor.worldMapSuccesses, 2)
        XCTAssertEqual(monitor.worldMapAverageTime, 3.0, accuracy: 0.001)
    }
    
    // MARK: - ObjectAnchor Recording Tests
    
    func testRecordObjectAnchorAttemptIncrementsAttempts() {
        monitor.recordObjectAnchorAttempt()
        monitor.recordObjectAnchorAttempt()
        
        XCTAssertEqual(monitor.objectAnchorAttempts, 2)
        XCTAssertEqual(monitor.objectAnchorSuccesses, 0)
    }
    
    func testRecordObjectAnchorSuccessIncrementsSuccessAndTime() {
        monitor.recordObjectAnchorAttempt()
        monitor.recordObjectAnchorSuccess(elapsedTime: 1.5)
        
        XCTAssertEqual(monitor.objectAnchorAttempts, 1)
        XCTAssertEqual(monitor.objectAnchorSuccesses, 1)
        XCTAssertEqual(monitor.objectAnchorSuccessRate, 1.0)
        XCTAssertEqual(monitor.objectAnchorAverageTime, 1.5, accuracy: 0.001)
    }
    
    func testRecordObjectAnchorFailureOnlyIncrementsAttempts() {
        monitor.recordObjectAnchorAttempt()
        monitor.recordObjectAnchorFailure()
        
        XCTAssertEqual(monitor.objectAnchorAttempts, 1)
        XCTAssertEqual(monitor.objectAnchorSuccesses, 0)
    }
    
    // MARK: - Mixed Scenario Tests
    
    func testMixedRelocalizationAttemptsComputeCorrectRates() {
        // ARWorldMap: 3 successes out of 5 attempts (60%)
        for _ in 0..<5 {
            monitor.recordWorldMapAttempt()
        }
        monitor.recordWorldMapSuccess(elapsedTime: 2.0)
        monitor.recordWorldMapFailure()
        monitor.recordWorldMapSuccess(elapsedTime: 3.0)
        monitor.recordWorldMapFailure()
        monitor.recordWorldMapSuccess(elapsedTime: 2.5)
        
        // ObjectAnchor: 4 successes out of 5 attempts (80%)
        for _ in 0..<5 {
            monitor.recordObjectAnchorAttempt()
        }
        monitor.recordObjectAnchorSuccess(elapsedTime: 1.0)
        monitor.recordObjectAnchorSuccess(elapsedTime: 1.5)
        monitor.recordObjectAnchorFailure()
        monitor.recordObjectAnchorSuccess(elapsedTime: 0.8)
        monitor.recordObjectAnchorSuccess(elapsedTime: 1.2)
        
        XCTAssertEqual(monitor.worldMapSuccessRate, 0.6, accuracy: 0.01)
        XCTAssertEqual(monitor.objectAnchorSuccessRate, 0.8, accuracy: 0.01)
    }
    
    func testObjectAnchorPreferredReturnsTrueWhenRateDiffExceedsThreshold() {
        // Need at least 5 attempts of each type
        for _ in 0..<5 {
            monitor.recordWorldMapAttempt()
            monitor.recordWorldMapFailure()
        }
        
        for _ in 0..<5 {
            monitor.recordObjectAnchorAttempt()
            monitor.recordObjectAnchorSuccess(elapsedTime: 1.0)
        }
        
        // ObjectAnchor has 100% success vs 0% for WorldMap, diff = 1.0 > 0.1
        XCTAssertTrue(monitor.objectAnchorPreferred)
    }
    
    func testObjectAnchorPreferredReturnsFalseWhenInsufficientData() {
        monitor.recordWorldMapAttempt()
        monitor.recordWorldMapSuccess(elapsedTime: 2.0)
        
        monitor.recordObjectAnchorAttempt()
        monitor.recordObjectAnchorSuccess(elapsedTime: 1.0)
        
        // Only 1 attempt each, need >= 5
        XCTAssertFalse(monitor.objectAnchorPreferred)
    }
    
    func testObjectAnchorPreferredReturnsFalseWhenWorldMapIsBetter() {
        for _ in 0..<5 {
            monitor.recordWorldMapAttempt()
        }
        for _ in 0..<4 {
            monitor.recordWorldMapSuccess(elapsedTime: 2.0)
        }
        monitor.recordWorldMapFailure()
        
        for _ in 0..<5 {
            monitor.recordObjectAnchorAttempt()
        }
        for _ in 0..<2 {
            monitor.recordObjectAnchorSuccess(elapsedTime: 1.0)
        }
        for _ in 0..<3 {
            monitor.recordObjectAnchorFailure()
        }
        
        // WorldMap 80% > ObjectAnchor 40%, diff = -0.4 < 0.1
        XCTAssertFalse(monitor.objectAnchorPreferred)
    }
    
    // MARK: - Summary Tests
    
    func testSummaryContainsAllMetrics() {
        monitor.recordWorldMapAttempt()
        monitor.recordWorldMapSuccess(elapsedTime: 2.0)
        
        monitor.recordObjectAnchorAttempt()
        monitor.recordObjectAnchorSuccess(elapsedTime: 1.0)
        
        let summary = monitor.summary
        XCTAssertTrue(summary.contains("ARWorldMap"))
        XCTAssertTrue(summary.contains("ObjectAnchor"))
        XCTAssertTrue(summary.contains("Recommended"))
        XCTAssertTrue(summary.contains("100.0%"))
    }
}
