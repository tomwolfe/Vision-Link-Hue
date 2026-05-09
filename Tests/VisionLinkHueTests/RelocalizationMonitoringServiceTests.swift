import XCTest
@testable import VisionLinkHue

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
    
    func testInitialSuccessRatesAreZero() async {
        let worldMapSuccessRate = await monitor.worldMapSuccessRate
        XCTAssertEqual(worldMapSuccessRate, 0.0)
        let objectAnchorSuccessRate = await monitor.objectAnchorSuccessRate
        XCTAssertEqual(objectAnchorSuccessRate, 0.0)
        let worldMapAverageTime = await monitor.worldMapAverageTime
        XCTAssertEqual(worldMapAverageTime, 0.0)
        let objectAnchorAverageTime = await monitor.objectAnchorAverageTime
        XCTAssertEqual(objectAnchorAverageTime, 0.0)
        let objectAnchorPreferred = await monitor.objectAnchorPreferred
        XCTAssertFalse(objectAnchorPreferred)
    }
    
    // MARK: - ARWorldMap Recording Tests
    
    func testRecordWorldMapAttemptIncrementsAttempts() async {
        await monitor.recordWorldMapAttempt()
        await monitor.recordWorldMapAttempt()
        await monitor.recordWorldMapAttempt()
        
        let attempts = await monitor.worldMapAttempts
        let successes = await monitor.worldMapSuccesses
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(successes, 0)
    }
    
    func testRecordWorldMapSuccessIncrementsSuccessAndTime() async {
        await monitor.recordWorldMapAttempt()
        await monitor.recordWorldMapSuccess(elapsedTime: 2.5)
        
        let attempts = await monitor.worldMapAttempts
        XCTAssertEqual(attempts, 1)
        let successes = await monitor.worldMapSuccesses
        XCTAssertEqual(successes, 1)
        let totalTime = await monitor.worldMapTotalTime
        XCTAssertEqual(totalTime, 2.5, accuracy: 0.001)
        let successRate = await monitor.worldMapSuccessRate
        XCTAssertEqual(successRate, 1.0)
        let averageTime = await monitor.worldMapAverageTime
        XCTAssertEqual(averageTime, 2.5, accuracy: 0.001)
    }
    
    func testRecordWorldMapFailureOnlyIncrementsAttempts() async {
        await monitor.recordWorldMapAttempt()
        await monitor.recordWorldMapFailure()
        
        let attempts = await monitor.worldMapAttempts
        XCTAssertEqual(attempts, 1)
        let successes = await monitor.worldMapSuccesses
        XCTAssertEqual(successes, 0)
        let successRate = await monitor.worldMapSuccessRate
        XCTAssertEqual(successRate, 0.0)
    }
    
    func testMultipleWorldMapSuccessesComputeCorrectAverage() async {
        await monitor.recordWorldMapAttempt()
        await monitor.recordWorldMapSuccess(elapsedTime: 2.0)
        
        await monitor.recordWorldMapAttempt()
        await monitor.recordWorldMapSuccess(elapsedTime: 4.0)
        
        let successes = await monitor.worldMapSuccesses
        XCTAssertEqual(successes, 2)
        let averageTime = await monitor.worldMapAverageTime
        XCTAssertEqual(averageTime, 3.0, accuracy: 0.001)
    }
    
    // MARK: - ObjectAnchor Recording Tests
    
    func testRecordObjectAnchorAttemptIncrementsAttempts() async {
        await monitor.recordObjectAnchorAttempt()
        await monitor.recordObjectAnchorAttempt()
        
        let attempts = await monitor.objectAnchorAttempts
        XCTAssertEqual(attempts, 2)
        let successes = await monitor.objectAnchorSuccesses
        XCTAssertEqual(successes, 0)
    }
    
    func testRecordObjectAnchorSuccessIncrementsSuccessAndTime() async {
        await monitor.recordObjectAnchorAttempt()
        await monitor.recordObjectAnchorSuccess(elapsedTime: 1.5)
        
        let attempts = await monitor.objectAnchorAttempts
        XCTAssertEqual(attempts, 1)
        let successes = await monitor.objectAnchorSuccesses
        XCTAssertEqual(successes, 1)
        let successRate = await monitor.objectAnchorSuccessRate
        XCTAssertEqual(successRate, 1.0)
        let averageTime = await monitor.objectAnchorAverageTime
        XCTAssertEqual(averageTime, 1.5, accuracy: 0.001)
    }
    
    func testRecordObjectAnchorFailureOnlyIncrementsAttempts() async {
        await monitor.recordObjectAnchorAttempt()
        await monitor.recordObjectAnchorFailure()
        
        let attempts = await monitor.objectAnchorAttempts
        XCTAssertEqual(attempts, 1)
        let successes = await monitor.objectAnchorSuccesses
        XCTAssertEqual(successes, 0)
    }
    
    // MARK: - Mixed Scenario Tests
    
    func testMixedRelocalizationAttemptsComputeCorrectRates() async {
        // ARWorldMap: 3 successes out of 5 attempts (60%)
        for _ in 0..<5 {
            await monitor.recordWorldMapAttempt()
        }
        await monitor.recordWorldMapSuccess(elapsedTime: 2.0)
        await monitor.recordWorldMapFailure()
        await monitor.recordWorldMapSuccess(elapsedTime: 3.0)
        await monitor.recordWorldMapFailure()
        await monitor.recordWorldMapSuccess(elapsedTime: 2.5)
        
        // ObjectAnchor: 4 successes out of 5 attempts (80%)
        for _ in 0..<5 {
            await monitor.recordObjectAnchorAttempt()
        }
        await monitor.recordObjectAnchorSuccess(elapsedTime: 1.0)
        await monitor.recordObjectAnchorSuccess(elapsedTime: 1.5)
        await monitor.recordObjectAnchorFailure()
        await monitor.recordObjectAnchorSuccess(elapsedTime: 0.8)
        await monitor.recordObjectAnchorSuccess(elapsedTime: 1.2)
        
        let worldMapSuccessRate = await monitor.worldMapSuccessRate
        XCTAssertEqual(worldMapSuccessRate, 0.6, accuracy: 0.01)
        let objectAnchorSuccessRate = await monitor.objectAnchorSuccessRate
        XCTAssertEqual(objectAnchorSuccessRate, 0.8, accuracy: 0.01)
    }
    
    func testObjectAnchorPreferredReturnsTrueWhenRateDiffExceedsThreshold() async {
        // Need at least 5 attempts of each type
        for _ in 0..<5 {
            await monitor.recordWorldMapAttempt()
            await monitor.recordWorldMapFailure()
        }
        
        for _ in 0..<5 {
            await monitor.recordObjectAnchorAttempt()
            await monitor.recordObjectAnchorSuccess(elapsedTime: 1.0)
        }
        
        // ObjectAnchor has 100% success vs 0% for WorldMap, diff = 1.0 > 0.1
        let preferred = await monitor.objectAnchorPreferred
        XCTAssertTrue(preferred)
    }
    
    func testObjectAnchorPreferredReturnsFalseWhenInsufficientData() async {
        await monitor.recordWorldMapAttempt()
        await monitor.recordWorldMapSuccess(elapsedTime: 2.0)
        
        await monitor.recordObjectAnchorAttempt()
        await monitor.recordObjectAnchorSuccess(elapsedTime: 1.0)
        
        // Only 1 attempt each, need >= 5
        let preferred2 = await monitor.objectAnchorPreferred
        XCTAssertFalse(preferred2)
    }
    
    func testObjectAnchorPreferredReturnsFalseWhenWorldMapIsBetter() async {
        for _ in 0..<5 {
            await monitor.recordWorldMapAttempt()
        }
        for _ in 0..<4 {
            await monitor.recordWorldMapSuccess(elapsedTime: 2.0)
        }
        await monitor.recordWorldMapFailure()
        
        for _ in 0..<5 {
            await monitor.recordObjectAnchorAttempt()
        }
        for _ in 0..<2 {
            await monitor.recordObjectAnchorSuccess(elapsedTime: 1.0)
        }
        for _ in 0..<3 {
            await monitor.recordObjectAnchorFailure()
        }
        
        // WorldMap 80% > ObjectAnchor 40%, diff = -0.4 < 0.1
        let preferred3 = await monitor.objectAnchorPreferred
        XCTAssertFalse(preferred3)
    }
    
    // MARK: - Summary Tests
    
    func testSummaryContainsAllMetrics() async {
        await monitor.recordWorldMapAttempt()
        await monitor.recordWorldMapSuccess(elapsedTime: 2.0)
        
        await monitor.recordObjectAnchorAttempt()
        await monitor.recordObjectAnchorSuccess(elapsedTime: 1.0)
        
        let summary = await monitor.summary
        XCTAssertTrue(summary.contains("ARWorldMap"))
        XCTAssertTrue(summary.contains("ObjectAnchor"))
        XCTAssertTrue(summary.contains("Recommended"))
        XCTAssertTrue(summary.contains("100.0%"))
    }
}
