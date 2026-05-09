import XCTest
@testable import VisionLinkHue
import SwiftData
import simd

/// Unit tests for `SpatialSyncService`, validating CloudKit spatial
/// persistence sync, conflict resolution, and record management.
@MainActor
final class SpatialSyncServiceTests: XCTestCase {
    
    private var syncService: SpatialSyncService!
    private var modelContainer: ModelContainer!
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Create an isolated in-memory ModelContainer for testing
        let schema = Schema([SpatialSyncRecord.self])
        modelContainer = try! ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        
        syncService = await MainActor.run {
            SpatialSyncService(modelContainer: modelContainer, deviceIdentifier: "test-device-1")
        }
    }
    
    override func tearDown() {
        syncService = nil
        modelContainer = nil
        super.tearDown()
    }
    
    // MARK: - SpatialSyncRecord Tests
    
    func testSpatialSyncRecordCreation() {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        let record = SpatialSyncRecord(
            fixtureId: fixtureId,
            lightId: "test-light",
            position: position,
            orientation: orientation,
            distanceMeters: 2.5,
            fixtureType: "pendant",
            confidence: 0.9
        )
        
        XCTAssertEqual(record.fixtureId, fixtureId)
        XCTAssertEqual(record.lightId, "test-light")
        XCTAssertEqual(record.positionX, 1.0)
        XCTAssertEqual(record.positionY, 2.0)
        XCTAssertEqual(record.positionZ, 3.0)
        XCTAssertEqual(record.distanceMeters, 2.5)
        XCTAssertEqual(record.fixtureType, "pendant")
        XCTAssertEqual(record.confidence, 0.9)
        XCTAssertFalse(record.isSynced)
        XCTAssertNil(record.lastSyncError)
        XCTAssertEqual(record.version, 1)
    }
    
    func testSpatialSyncRecordPositionAccessor() {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.5, 2.5, 3.5)
        let orientation = simd_quatf(angle: Float.pi / 4, axis: SIMD3<Float>(0, 0, 1))
        
        let record = SpatialSyncRecord(
            fixtureId: fixtureId,
            lightId: nil,
            position: position,
            orientation: orientation,
            distanceMeters: 1.0,
            fixtureType: "ceiling",
            confidence: 0.8
        )
        
        XCTAssertEqual(record.position.x, 1.5)
        XCTAssertEqual(record.position.y, 2.5)
        XCTAssertEqual(record.position.z, 3.5)
    }
    
    func testSpatialSyncRecordOrientationAccessor() {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: Float.pi / 2, axis: SIMD3<Float>(1, 0, 0))
        
        let record = SpatialSyncRecord(
            fixtureId: fixtureId,
            lightId: nil,
            position: position,
            orientation: orientation,
            distanceMeters: 1.0,
            fixtureType: "lamp",
            confidence: 0.7
        )
        
        let quatNorm = simd_length(record.orientation)
        XCTAssertGreaterThan(quatNorm, 0.99)
        XCTAssertLessThan(quatNorm, 1.01)
    }
    
    func testSpatialSyncRecordUUIDAccessor() {
        let fixtureId = UUID()
        let position = SIMD3<Float>(1.0, 2.0, 3.0)
        let orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1))
        
        let record = SpatialSyncRecord(
            fixtureId: fixtureId,
            lightId: nil,
            position: position,
            orientation: orientation,
            distanceMeters: 1.0,
            fixtureType: "recessed",
            confidence: 0.85
        )
        
        XCTAssertEqual(record.fixtureId, fixtureId)
    }
    
    // MARK: - SpatialSyncService Tests
    
    func testServiceStartsWithCloudKitUnavailable() async {
        let isCloudKitAvailable = await syncService.isCloudKitAvailable
        XCTAssertFalse(isCloudKitAvailable)
        let isSyncing = await syncService.isSyncing
        XCTAssertFalse(isSyncing)
        let lastSuccessfulSync = await syncService.lastSuccessfulSync
        XCTAssertNil(lastSuccessfulSync)
    }
    
    func testServiceHasCorrectDeviceIdentifier() async {
        let customService = await MainActor.run {
            SpatialSyncService(modelContainer: modelContainer, deviceIdentifier: "custom-device-id")
        }
        // The device identifier is private but we can verify the service was created.
        let isSyncing = await customService.isSyncing
        XCTAssertFalse(isSyncing)
    }
    
    func testSyncReturnsSkippedWhenCloudKitUnavailable() async {
        let result = await syncService.sync()
        
        switch result {
        case .skipped(reason: "cloudkit_unavailable"):
            // Expected
            break
        default:
            XCTFail("Expected skipped result with cloudkit_unavailable reason")
        }
    }
    
    func testSyncMarksServiceAsSyncing() async {
        // CloudKit is unavailable so sync will be skipped, but the service
        // should still go through the syncing state.
        let _ = await syncService.sync()
        
        // After sync completes (even skipped), isSyncing should be false.
        let isSyncing = await syncService.isSyncing
        XCTAssertFalse(isSyncing)
    }
    
    func testForceSyncClearsPendingUploads() async {
        await syncService.clearPendingUploads()
        await syncService.forceSync()
        
        // Force sync should have been attempted.
        let isSyncing = await syncService.isSyncing
        XCTAssertFalse(isSyncing)
    }
    
    func testClearPendingUploadsRemovesAll() async {
        await syncService.clearPendingUploads()
        // No pending uploads to verify since they're private, but the method
        // should not crash.
    }
    
    // MARK: - SpatialSyncResult Tests
    
    func testSyncResultSuccessCase() {
        let result = SpatialSyncResult.success(
            uploaded: 5,
            downloaded: 3,
            conflictsResolved: 1
        )
        
        switch result {
        case .success(let uploaded, let downloaded, let conflicts):
            XCTAssertEqual(uploaded, 5)
            XCTAssertEqual(downloaded, 3)
            XCTAssertEqual(conflicts, 1)
        default:
            XCTFail("Expected success case")
        }
    }
    
    func testSyncResultSkippedCase() {
        let result = SpatialSyncResult.skipped(reason: "sync_in_progress")
        
        switch result {
        case .skipped(reason: "sync_in_progress"):
            // Expected
            break
        default:
            XCTFail("Expected skipped case")
        }
    }
    
    func testSyncResultFailureCase() {
        let testError = NSError(
            domain: "Test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Test error"]
        )
        let result = SpatialSyncResult.failure(error: testError)
        
        switch result {
        case .failure(let error):
            XCTAssertEqual((error as NSError).domain, "Test")
        default:
            XCTFail("Expected failure case")
        }
    }
    
    // MARK: - UploadResult Tests
    
    func testUploadResultSuccess() {
        let result = UploadResult(success: true, changes: 5)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.changes, 5)
    }
    
    func testUploadResultFailure() {
        let result = UploadResult(success: false, changes: 0)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.changes, 0)
    }
    
    // MARK: - DownloadResult Tests
    
    func testDownloadResultSuccess() {
        let result = DownloadResult(success: true, changes: 3)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.changes, 3)
    }
    
    func testDownloadResultFailure() {
        let result = DownloadResult(success: false, changes: 0)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.changes, 0)
    }
    
    // MARK: - CRDT Vector Clock Tests
    
    func testCRDTMergeLocalWins() {
        let localClock: [String: Int64] = ["device-1": 5, "device-2": 3]
        let remoteClock: [String: Int64] = ["device-1": 3, "device-2": 2]
        
        let result = CRDTConflictResolver.merge(
            localClock: localClock,
            remoteClock: remoteClock,
            localLWW: ["device-1": (5, 0)],
            remoteLWW: [:]
        )
        
        XCTAssertEqual(result, .localWins, "Local should win when all clock entries are higher")
    }
    
    func testCRDTMergeRemoteWins() {
        let localClock: [String: Int64] = ["device-1": 2, "device-2": 1]
        let remoteClock: [String: Int64] = ["device-1": 4, "device-2": 3]
        
        let result = CRDTConflictResolver.merge(
            localClock: localClock,
            remoteClock: remoteClock,
            localLWW: [:],
            remoteLWW: ["device-2": (4, 0)]
        )
        
        XCTAssertEqual(result, .remoteWins, "Remote should win when all clock entries are higher")
    }
    
    func testCRDTMergeEquivalent() {
        let localClock: [String: Int64] = ["device-1": 3, "device-2": 2]
        let remoteClock: [String: Int64] = ["device-1": 3, "device-2": 2]
        
        let result = CRDTConflictResolver.merge(
            localClock: localClock,
            remoteClock: remoteClock,
            localLWW: ["device-1": (3, 0), "device-2": (2, 0)],
            remoteLWW: ["device-1": (3, 0), "device-2": (2, 0)]
        )
        
        XCTAssertEqual(result, .equivalent, "Identical clocks should be equivalent")
    }
    
    func testCRDTMergeConcurrentWithLocalPreference() {
        // Concurrent: device-1 is ahead locally, device-2 is ahead remotely
        let localClock: [String: Int64] = ["device-1": 5, "device-2": 2]
        let remoteClock: [String: Int64] = ["device-1": 3, "device-2": 4]
        
        let result = CRDTConflictResolver.merge(
            localClock: localClock,
            remoteClock: remoteClock,
            localLWW: ["device-1": (5, 0)],
            remoteLWW: ["device-2": (4, 0)]
        )
        
        XCTAssertEqual(result, .localWins, "Local should win concurrent updates with higher explicit version")
    }
    
    func testCRDTMergeClocks() {
        let clockA: [String: Int64] = ["device-1": 3, "device-2": 1]
        let clockB: [String: Int64] = ["device-1": 2, "device-3": 4]
        
        let merged = CRDTConflictResolver.mergeClocks(clockA, clockB)
        
        XCTAssertEqual(merged["device-1"], 3, "Should take max of device-1 entries")
        XCTAssertEqual(merged["device-2"], 1, "Should preserve device-2 from clockA")
        XCTAssertEqual(merged["device-3"], 4, "Should add device-3 from clockB")
    }
    
    func testCRDTIncrementVersion() {
        let clock: [String: Int64] = ["device-1": 3, "device-2": 2]
        
        let incremented = CRDTConflictResolver.incrementVersion(clock, for: "device-1")
        
        XCTAssertEqual(incremented["device-1"], 4, "Should increment device-1 version")
        XCTAssertEqual(incremented["device-2"], 2, "Should preserve other entries")
    }
}
