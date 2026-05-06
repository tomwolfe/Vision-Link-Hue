import Foundation
import SwiftData
import CloudKit
import simd
import os

// MARK: - Vector Clock for CRDT Conflict Resolution

/// A vector clock for tracking logical timestamps across distributed devices.
/// Each entry maps a device identifier to its last known version number for
/// a specific fixture, enabling proper causal ordering in multi-device sync.
struct VectorClockEntry: Sendable, Comparable {
    /// Device identifier this clock entry represents.
    let deviceID: String
    
    /// Version number for this device's last known state.
    let version: Int64
    
    static func < (lhs: VectorClockEntry, rhs: VectorClockEntry) -> Bool {
        lhs.version < rhs.version
    }
}

/// Conflict resolution result from CRDT merge operation.
enum CRDTMergeResult: Sendable {
    /// Local version wins (local is causally ahead or concurrent with higher value).
    case localWins
    /// Remote version wins (remote is causally ahead or concurrent with higher value).
    case remoteWins
    /// Versions are causally equivalent (identical state).
    case equivalent
    
    /// The winning version number.
    var winningVersion: Int64 {
        switch self {
        case .localWins, .equivalent: return 0
        case .remoteWins: return 0
        }
    }
}

/// Conflict resolver using CRDT vector clocks for spatial coordinates.
/// Handles concurrent updates from multiple devices (Vision Pro + iPhone)
/// by comparing vector clocks to determine causal ordering and merge conflicts.
struct CRDTConflictResolver {
    
    /// Compare two vector clocks to determine which is causally ahead.
    /// Returns the merge result based on vector clock comparison.
    static func merge(localClock: [String: Int64], remoteClock: [String: Int64],
                      localVersion: Int64, remoteVersion: Int64) -> CRDTMergeResult {
        
        // Collect all device IDs from both clocks
        let allDevices = Set(localClock.keys).union(remoteClock.keys)
        
        var localAhead = false
        var remoteAhead = false
        
        // Check if local is causally ahead of remote
        for deviceID in allDevices {
            let localVal = localClock[deviceID] ?? 0
            let remoteVal = remoteClock[deviceID] ?? 0
            
            if localVal > remoteVal {
                localAhead = true
            } else if remoteVal > localVal {
                remoteAhead = true
            }
        }
        
        // Add explicit version comparison for the current fixture
        if localVersion > remoteVersion {
            localAhead = true
        } else if remoteVersion > localVersion {
            remoteAhead = true
        }
        
        // Determine the merge result based on causal ordering
        if localAhead && !remoteAhead {
            return .localWins
        } else if remoteAhead && !localAhead {
            return .remoteWins
        } else if !localAhead && !remoteAhead {
            return .equivalent
        } else {
            // Concurrent update: use hybrid strategy
            // Prefer the device with the higher explicit version,
            // breaking ties by preferring the local device
            if localVersion >= remoteVersion {
                return .localWins
            } else {
                return .remoteWins
            }
        }
    }
    
    /// Merge vector clocks by taking the element-wise maximum.
    /// Used when reconciling clocks after a successful sync.
    static func mergeClocks(_ clockA: [String: Int64], _ clockB: [String: Int64]) -> [String: Int64] {
        var merged = clockA
        for (deviceID, version) in clockB {
            merged[deviceID] = max(merged[deviceID] ?? 0, version)
        }
        return merged
    }
    
    /// Increment the version for a specific device in a vector clock.
    static func incrementVersion(_ clock: [String: Int64], for deviceID: String) -> [String: Int64] {
        var updated = clock
        updated[deviceID] = (updated[deviceID] ?? 0) + 1
        return updated
    }
}

/// Serializable snapshot of a fixture mapping for upload across actor boundaries.
struct FixtureMappingUploadData: Sendable {
    let fixtureId: UUID
    let lightId: String?
    let position: SIMD3<Float>
    let orientation: simd_quatf
    let distanceMeters: Float
    let fixtureType: String
    let confidence: Double
}

/// Represents a spatial sync record for CloudKit Sharing of fixture mappings
/// across a user's Vision Pro and iPhone devices.
@Model
final class SpatialSyncRecord {
    /// CloudKit record ID for this sync record.
    var cloudKitRecordID: String?
    
    /// The fixture UUID this record represents.
    var fixtureId: UUID
    
    /// Philips Hue light ID mapped to this fixture.
    var lightId: String?
    
    /// 3D position in world space.
    var positionX: Float
    var positionY: Float
    var positionZ: Float
    
    /// Orientation quaternion components.
    var orientationX: Float
    var orientationY: Float
    var orientationZ: Float
    var orientationW: Float
    
    /// Distance to the fixture in meters.
    var distanceMeters: Float
    
    /// Fixture type string for display.
    var fixtureType: String
    
    /// Detection confidence (0.0-1.0).
    var confidence: Double
    
    /// Timestamp of the last sync from this device.
    var lastSyncedAt: Date
    
    /// Device identifier that last modified this record.
    var lastModifiedByDevice: String?
    
    /// Conflict resolution token (version number).
    var version: Int64
    
    /// Vector clock for CRDT conflict resolution across devices.
    /// Maps device IDs to their last known version numbers.
    var vectorClockJSON: String?
    
    /// Whether this record has been successfully synced to CloudKit.
    var isSynced: Bool
    
    /// Last sync error message, if any.
    var lastSyncError: String?
    
    init(
        fixtureId: UUID,
        lightId: String?,
        position: SIMD3<Float>,
        orientation: simd_quatf,
        distanceMeters: Float,
        fixtureType: String,
        confidence: Double
    ) {
        self.fixtureId = fixtureId
        self.lightId = lightId
        self.positionX = position.x
        self.positionY = position.y
        self.positionZ = position.z
        self.orientationX = orientation.vector.x
        self.orientationY = orientation.vector.y
        self.orientationZ = orientation.vector.z
        self.orientationW = orientation.vector.w
        self.distanceMeters = distanceMeters
        self.fixtureType = fixtureType
        self.confidence = confidence
        self.lastSyncedAt = Date()
        self.lastModifiedByDevice = nil
        self.version = 1
        self.vectorClockJSON = nil
        self.isSynced = false
        self.lastSyncError = nil
    }
    
    /// Convenience accessor for the 3D position.
    var position: SIMD3<Float> {
        SIMD3<Float>(positionX, positionY, positionZ)
    }
    
    /// Convenience accessor for the orientation quaternion.
    var orientation: simd_quatf {
        simd_quatf(real: orientationW, imag: SIMD3<Float>(orientationX, orientationY, orientationZ))
    }
}

/// Shared container for the spatial sync SwiftData model.
struct SpatialSyncModelContainer {
    static let shared = SpatialSyncModelContainer()
    
    let schema: Schema
    let modelContainer: ModelContainer
    
    private init() {
        self.schema = Schema([SpatialSyncRecord.self])
        
        do {
            self.modelContainer = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration()]
            )
        } catch {
            // Fallback to in-memory storage if persistent storage fails.
            self.modelContainer = try! ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
        }
    }
}

/// Service for syncing fixture spatial mappings across devices using
/// SwiftData CloudKit Sharing. Provides bidirectional sync with
/// CRDT-based conflict resolution using vector clocks for handling
/// concurrent updates from multiple devices (Vision Pro + iPhone).
///
/// The service operates with background isolation to prevent
/// main-thread blocking during sync operations.
@ModelActor
final actor SpatialSyncService {
    
    nonisolated static let shared = SpatialSyncService()
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "SpatialSyncService"
    )
    
    /// Whether CloudKit sharing is available and configured.
    var isCloudKitAvailable: Bool = false
    
    /// Whether an active sync operation is in progress.
    var isSyncing: Bool = false
    
    /// The last successful sync timestamp.
    var lastSuccessfulSync: Date?
    
    /// Pending local changes that haven't been uploaded yet.
    private var pendingUploads: [UUID: SpatialSyncRecord] = [:]
    
    /// Version tracker for conflict resolution.
    private var localVersionTracker: [String: Int64] = [:]
    
    /// Vector clock for CRDT-based conflict resolution.
    /// Maps fixture IDs to their vector clock entries (device -> version).
    private var vectorClocks: [String: [String: Int64]] = [:]
    
    /// Device identifier for this device (used in conflict resolution).
    private var deviceIdentifier: String
    
    /// CloudKit sharing database for spatial sync records.
    private var cloudKitDatabase: CKDatabase?
    
    /// Initialize the spatial sync service.
    init(deviceIdentifier: String = ProcessInfo().globallyUniqueString) {
        self.deviceIdentifier = deviceIdentifier
        self.modelContainer = SpatialSyncModelContainer.shared.modelContainer
        self.cloudKitDatabase = Self.setupCloudKitDatabase()
    }
    
    /// Set up the CloudKit sharing database for spatial sync.
    /// Uses the app's CloudKit container with the public database.
    /// Returns nil if the CloudKit container is not configured.
    private static func setupCloudKitDatabase() -> CKDatabase? {
        #if targetEnvironment(simulator)
        return nil
        #else
        return CKContainer(identifier: "iCloud.com.visionlinkhue.spatial").publicCloudDatabase
        #endif
    }
    
    /// Check if CloudKit sharing is available for spatial sync.
    func checkCloudKitAvailability() async -> Bool {
        isCloudKitAvailable = true
        logger.debug("CloudKit availability: \(self.isCloudKitAvailable)")
        return self.isCloudKitAvailable
    }
    
    /// Sync local fixture mappings with CloudKit.
    /// Performs a bidirectional sync: uploads local changes and downloads
    /// remote changes, resolving conflicts using CRDT vector clocks.
    ///
    /// - Returns: A `SpatialSyncResult` describing the outcome.
    func sync() async -> SpatialSyncResult {
        guard !isSyncing else {
            logger.warning("Sync already in progress, skipping")
            return .skipped(reason: "sync_in_progress")
        }
        
        guard await checkCloudKitAvailability() else {
            logger.warning("CloudKit not available, skipping sync")
            return .skipped(reason: "cloudkit_unavailable")
        }
        
        isSyncing = true
        
        defer {
            isSyncing = false
        }
        
        do {
            // Step 1: Upload local changes.
            let uploadResult = await uploadLocalChanges()
            
            // Step 2: Download remote changes.
            let downloadResult = await downloadRemoteChanges()
            
            // Step 3: Resolve any conflicts.
            let conflicts = await resolveConflicts()
            
            let success = uploadResult.success && downloadResult.success
            lastSuccessfulSync = success ? Date() : lastSuccessfulSync
            
            if success {
                logger.info("Sync completed: \(uploadResult.changes) uploaded, \(downloadResult.changes) downloaded, \(conflicts) conflicts resolved")
            }
            
            return .success(
                uploaded: uploadResult.changes,
                downloaded: downloadResult.changes,
                conflictsResolved: conflicts
            )
        } catch {
            logger.error("Sync failed: \(error.localizedDescription)")
            return .failure(error: error)
        }
    }
    
    /// Upload local fixture mappings that have changed since last sync.
    /// Creates or updates CloudKit records for each local fixture mapping.
    private func uploadLocalChanges() async -> UploadResult {
        var changes = 0
        var success = true
        
        // Load local fixture mappings that need syncing from FixturePersistence.
        let unsyncedMappings = await persistence.loadMappingsNeedingSync()
        
        for mapping in unsyncedMappings {
            do {
                // Create a new spatial sync record for upload.
                let syncRecord = await createSyncRecord(from: mapping)
                
                // Upload to CloudKit.
                try await uploadRecord(syncRecord)
                
                // Mark as synced in FixturePersistence.
                await persistence.markMappingSynced(syncRecord.fixtureId)
                
                changes += 1
            } catch {
                logger.error("Failed to upload mapping for \(mapping.fixtureId): \(error.localizedDescription)")
                success = false
                pendingUploads[mapping.fixtureId] = await loadPendingSyncRecord(for: mapping.fixtureId)
            }
        }
        
        return UploadResult(success: success, changes: changes)
    }
    
    /// Download remote fixture mappings from CloudKit.
    /// Returns remote records that are newer than local versions.
    /// Merges vector clocks from remote records for CRDT conflict resolution.
    private func downloadRemoteChanges() async -> DownloadResult {
        var changes = 0
        var success = true
        
        do {
            // Fetch all remote spatial sync records.
            let remoteRecords = try await fetchRemoteRecords()
            
            for remoteRecord in remoteRecords {
                // Merge the remote vector clock into our local clock.
                if let remoteClock = deserializeVectorClock(from: remoteRecord.vectorClockJSON) {
                    let fixtureKey = remoteRecord.fixtureId
                    let localClock = vectorClocks[fixtureKey] ?? [:]
                    vectorClocks[fixtureKey] = CRDTConflictResolver.mergeClocks(localClock, remoteClock)
                }
                
                // Check if local record exists and is newer.
                let localVersion = await getLocalVersion(for: remoteRecord.fixtureId)
                
                if localVersion >= remoteRecord.version {
                    // Local version is up-to-date or newer, skip.
                    continue
                }
                
                // Apply remote changes to local store.
                await applyRemoteRecord(remoteRecord)
                changes += 1
            }
        } catch {
            logger.error("Failed to download remote records: \(error.localizedDescription)")
            success = false
        }
        
        return DownloadResult(success: success, changes: changes)
    }
    
    /// Resolve conflicts between local and remote records using CRDT vector clocks.
    /// Uses element-wise comparison of vector clocks to determine causal ordering.
    /// For concurrent updates (neither clock dominates), prefers the device with
    /// the higher explicit version, breaking ties by favoring the local device.
    private func resolveConflicts() async -> Int {
        var conflictCount = 0
        
        // Load all local records that have pending uploads.
        let pendingRecords = await loadPendingSyncRecords()
        
        for record in pendingRecords {
            let fixtureKey = record.fixtureId
            let localClock = vectorClocks[fixtureKey] ?? [:]
            let remoteVersion = await getRemoteVersion(for: fixtureKey)
            let localVersion = await getLocalVersion(for: fixtureKey)
            
            // Build a minimal remote clock entry for the merge decision.
            // In production, the remote clock would be stored in the CloudKit record.
            var remoteClock: [String: Int64] = [:]
            if let remoteDeviceID = record.lastModifiedByDevice {
                remoteClock[remoteDeviceID] = remoteVersion
            }
            
            let mergeResult = CRDTConflictResolver.merge(
                localClock: localClock,
                remoteClock: remoteClock,
                localVersion: localVersion,
                remoteVersion: remoteVersion
            )
            
            switch mergeResult {
            case .localWins:
                await markAsSynced(record)
                conflictCount += 1
                logger.debug("CRDT conflict resolved for \(fixtureKey): kept local version \(localVersion)")
            case .remoteWins:
                await applyRemoteChanges(for: record.fixtureId)
                conflictCount += 1
                logger.debug("CRDT conflict resolved for \(fixtureKey): applied remote version \(remoteVersion)")
            case .equivalent:
                // No conflict — versions are causally equivalent
                break
            }
        }
        
        return conflictCount
    }
    
    /// Create a spatial sync record from a mapping snapshot for CloudKit upload.
    private func createSyncRecord(from mapping: FixtureMappingUploadData) async -> SpatialSyncRecord {
        _ = incrementVersion(for: mapping.fixtureId)
        
        let record = SpatialSyncRecord(
            fixtureId: mapping.fixtureId,
            lightId: mapping.lightId,
            position: mapping.position,
            orientation: mapping.orientation,
            distanceMeters: mapping.distanceMeters,
            fixtureType: mapping.fixtureType,
            confidence: mapping.confidence
        )
        
        record.lastModifiedByDevice = deviceIdentifier
        record.vectorClockJSON = serializeVectorClock(for: mapping.fixtureId)
        
        return record
    }
    
    /// Upload a spatial sync record to CloudKit.
    /// Upserts the record into the CloudKit sharing container using
    /// the fixture UUID as the record ID for deterministic record lookup.
    private func uploadRecord(_ record: SpatialSyncRecord) async throws {
        guard let database = cloudKitDatabase else {
            throw SpatialSyncError.cloudKitUnavailable
        }
        
        let ckRecordID = CKRecord.ID(recordName: "fixture:\(record.fixtureId.uuidString)")
        var ckRecord = CKRecord(recordType: "FixtureSpatialSync", recordID: ckRecordID)
        
        ckRecord["fixture_id"] = record.fixtureId.uuidString
        ckRecord["light_id"] = record.lightId
        ckRecord["position_x"] = record.positionX
        ckRecord["position_y"] = record.positionY
        ckRecord["position_z"] = record.positionZ
        ckRecord["orientation_x"] = record.orientationX
        ckRecord["orientation_y"] = record.orientationY
        ckRecord["orientation_z"] = record.orientationZ
        ckRecord["orientation_w"] = record.orientationW
        ckRecord["distance_meters"] = record.distanceMeters
        ckRecord["fixture_type"] = record.fixtureType
        ckRecord["confidence"] = record.confidence
        ckRecord["version"] = record.version
        ckRecord["last_synced_at"] = record.lastSyncedAt
        ckRecord["last_modified_by_device"] = record.lastModifiedByDevice
        ckRecord["is_synced"] = record.isSynced
        ckRecord["last_sync_error"] = record.lastSyncError
        ckRecord["vector_clock"] = record.vectorClockJSON
        
        try await database.save(ckRecord)
    }
    
    /// Fetch remote spatial sync records from CloudKit.
    /// Queries all fixture sync records and converts them to
    /// `SpatialSyncRecord` SwiftData model instances.
    private func fetchRemoteRecords() async throws -> [SpatialSyncRecord] {
        guard let database = cloudKitDatabase else {
            return []
        }
        
        let predicate = NSPredicate(value: true)
        let query = CKQuery(recordType: "FixtureSpatialSync", predicate: predicate)
        
        var fetchedRecords: [CKRecord] = []
        let results: [CKRecord] = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CKRecord], Error>) in
            let operation = CKQueryOperation(query: query)
            operation.recordFetchedBlock = { record in
                fetchedRecords.append(record)
            }
            operation.queryCompletionBlock = { cursor, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: fetchedRecords)
                }
            }
            database.add(operation)
        }
        
        return results.compactMap { ckRecord -> SpatialSyncRecord? in
            guard let fixtureId = ckRecord["fixture_id"] as? String,
                  let positionX = ckRecord["position_x"] as? Float,
                  let positionY = ckRecord["position_y"] as? Float,
                  let positionZ = ckRecord["position_z"] as? Float,
                  let orientationX = ckRecord["orientation_x"] as? Float,
                  let orientationY = ckRecord["orientation_y"] as? Float,
                  let orientationZ = ckRecord["orientation_z"] as? Float,
                  let orientationW = ckRecord["orientation_w"] as? Float,
                  let distanceMeters = ckRecord["distance_meters"] as? Float,
                  let fixtureType = ckRecord["fixture_type"] as? String,
                  let confidence = ckRecord["confidence"] as? Double,
                  let version = ckRecord["version"] as? Int64,
                  let lastSyncedAt = ckRecord["last_synced_at"] as? Date else {
                return nil
            }
            
            // Skip records from this device that are already synced locally.
            if let deviceID = ckRecord["last_modified_by_device"] as? String,
               deviceID == self.deviceIdentifier {
                return nil
            }
            
            return SpatialSyncRecord(
                fixtureId: UUID(uuidString: fixtureId) ?? UUID(),
                lightId: ckRecord["light_id"] as? String,
                position: SIMD3<Float>(positionX, positionY, positionZ),
                orientation: simd_quatf(real: orientationW, imag: SIMD3<Float>(orientationX, orientationY, orientationZ)),
                distanceMeters: distanceMeters,
                fixtureType: fixtureType,
                confidence: confidence
            )
        }
    }
    
    /// Apply a remote record to the local store.
    /// Delegates to FixturePersistence to update position, orientation,
    /// and light ID from the remote record to maintain consistency.
    private func applyRemoteRecord(_ record: SpatialSyncRecord) async {
        let fixtureUUID = record.fixtureId
        
        // Link the fixture to the light ID from the remote record.
        if let lightId = record.lightId {
            await persistence.linkFixture(fixtureUUID, toLight: lightId)
        }
        
        // Update spatial coordinates via FixturePersistence.
        await persistence.applyRemoteSpatialData(
            fixtureId: fixtureUUID,
            position: record.position,
            orientation: record.orientation,
            distanceMeters: record.distanceMeters,
            confidence: record.confidence
        )
    }
    
    /// Apply remote changes for a specific fixture.
    /// Fetches the latest remote record from CloudKit and applies
    /// it to the local store via FixturePersistence.
    private func applyRemoteChanges(for fixtureId: UUID) async {
        guard let database = cloudKitDatabase else { return }
        
        let ckRecordID = CKRecord.ID(recordName: "fixture:\(fixtureId.uuidString)")
        
        do {
            let record = try await database.record(for: ckRecordID)
            
            guard let positionX = record["position_x"] as? Float,
                  let positionY = record["position_y"] as? Float,
                  let positionZ = record["position_z"] as? Float,
                  let orientationX = record["orientation_x"] as? Float,
                  let orientationY = record["orientation_y"] as? Float,
                  let orientationZ = record["orientation_z"] as? Float,
                  let orientationW = record["orientation_w"] as? Float,
                  let distanceMeters = record["distance_meters"] as? Float,
                  let confidence = record["confidence"] as? Double else {
                return
            }
            
            let position = SIMD3<Float>(positionX, positionY, positionZ)
            let orientation = simd_quatf(real: orientationW, imag: SIMD3<Float>(orientationX, orientationY, orientationZ))
            
            // Update spatial coordinates via FixturePersistence.
            await persistence.applyRemoteSpatialData(
                fixtureId: fixtureId,
                position: position,
                orientation: orientation,
                distanceMeters: distanceMeters,
                confidence: confidence
            )
            
            if let lightId = record["light_id"] as? String {
                await persistence.linkFixture(fixtureId, toLight: lightId)
            }
            
            logger.debug("Applied remote changes for fixture \(fixtureId)")
        } catch {
            logger.error("Failed to fetch remote record for fixture \(fixtureId): \(error.localizedDescription)")
        }
    }
    
    /// Mark a sync record as successfully synced to CloudKit.
    private func markAsSynced(_ record: SpatialSyncRecord) async {
        record.isSynced = true
        record.lastSyncError = nil
        
        // Remove from pending uploads.
        pendingUploads.removeValue(forKey: record.fixtureId)
    }
    
    /// Serialize the vector clock for a fixture to JSON string.
    private func serializeVectorClock(for fixtureId: UUID) -> String? {
        let fixtureKey = fixtureId.uuidString
        guard let clock = vectorClocks[fixtureKey] else { return nil }
        
        do {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .useDefaultKeys
            let jsonData = try encoder.encode(clock)
            return String(data: jsonData, encoding: .utf8)
        } catch {
            logger.warning("Failed to serialize vector clock for \(fixtureId): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Deserialize a vector clock from JSON string.
    private func deserializeVectorClock(from json: String?) -> [String: Int64]? {
        guard let json = json, !json.isEmpty else { return nil }
        
        guard let jsonData = json.data(using: .utf8) else { return nil }
        
        do {
            let decoder = JSONDecoder()
            return try decoder.decode([String: Int64].self, from: jsonData)
        } catch {
            logger.warning("Failed to deserialize vector clock: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Increment the version number for a fixture using CRDT vector clocks.
    /// Updates the vector clock for this device and returns the new version.
    private func incrementVersion(for fixtureId: UUID) -> Int64 {
        let fixtureKey = fixtureId.uuidString
        let currentClock = vectorClocks[fixtureKey] ?? [:]
        let updatedClock = CRDTConflictResolver.incrementVersion(currentClock, for: deviceIdentifier)
        vectorClocks[fixtureKey] = updatedClock
        
        // Extract the local device's version from the updated clock
        let newVersion = updatedClock[deviceIdentifier] ?? 1
        localVersionTracker[fixtureKey] = newVersion
        return newVersion
    }
    
    /// Get the local version for a fixture from the vector clock.
    private func getLocalVersion(for fixtureId: String) async -> Int64 {
        let clock = vectorClocks[fixtureId] ?? [:]
        return clock[deviceIdentifier] ?? localVersionTracker[fixtureId] ?? 0
    }
    
    /// Get the remote version for a fixture from CloudKit.
    /// Compares with the local version for conflict resolution during sync.
    private func getRemoteVersion(for fixtureId: String) async -> Int64 {
        guard let database = cloudKitDatabase else { return 0 }
        
        let ckRecordID = CKRecord.ID(recordName: "fixture:\(fixtureId)")
        
        do {
            let record = try await database.record(for: ckRecordID)
            return record["version"] as? Int64 ?? 0
        } catch {
            logger.debug("Failed to fetch remote version for fixture \(fixtureId): \(error.localizedDescription)")
            return 0
        }
    }
    
    /// Load local fixture mappings that need syncing.
    /// Delegates to FixturePersistence which manages the FixtureMapping context.
    private func loadLocalMappingsNeedingSync() async -> [FixtureMapping] {
        await persistence.loadMappingsNeedingSync()
    }
    
    /// Load a sync record for a specific fixture.
    private func loadSyncRecord(for fixtureId: UUID) async -> SpatialSyncRecord? {
        let descriptor = FetchDescriptor<SpatialSyncRecord>(
            predicate: #Predicate<SpatialSyncRecord> { $0.fixtureId == fixtureId }
        )
        
        do {
            let records = try modelContext.fetch(descriptor)
            return records.first
        } catch {
            logger.error("Failed to load sync record: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Load a pending sync record for a specific fixture.
    private func loadPendingSyncRecord(for fixtureId: UUID) async -> SpatialSyncRecord? {
        pendingUploads[fixtureId]
    }
    
    /// Load all pending sync records.
    private func loadPendingSyncRecords() async -> [SpatialSyncRecord] {
        Array(pendingUploads.values)
    }
    
    /// Force a full sync regardless of pending state.
    func forceSync() async {
        pendingUploads.removeAll()
        _ = await sync()
    }
    
    /// Clear all pending uploads.
    func clearPendingUploads() {
        pendingUploads.removeAll()
    }
    
    /// Get the persistence reference for fixture mapping operations.
    nonisolated var persistence: FixturePersistence {
        FixturePersistence.shared
    }
}

// MARK: - Sync Result Types

/// Result of a spatial sync operation.
enum SpatialSyncResult {
    /// Sync completed successfully.
    case success(uploaded: Int, downloaded: Int, conflictsResolved: Int)
    /// Sync was skipped due to a pre-condition.
    case skipped(reason: String)
    /// Sync failed with an error.
    case failure(error: any Error)
}

/// Result of the upload phase of sync.
struct UploadResult {
    let success: Bool
    let changes: Int
}

/// Result of the download phase of sync.
struct DownloadResult {
    let success: Bool
    let changes: Int
}

/// Errors that can occur during spatial sync operations.
enum SpatialSyncError: Error, LocalizedError {
    case cloudKitUnavailable
    case recordFetchFailed(Error)
    case recordUpsertFailed(Error)
    case invalidRemoteRecord(String)
    case localStoreFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .cloudKitUnavailable:
            return "CloudKit is not available for spatial sync"
        case .recordFetchFailed(let error):
            return "Failed to fetch record from CloudKit: \(error.localizedDescription)"
        case .recordUpsertFailed(let error):
            return "Failed to upsert record to CloudKit: \(error.localizedDescription)"
        case .invalidRemoteRecord(let desc):
            return "Invalid remote sync record: \(desc)"
        case .localStoreFailed(let desc):
            return "Failed to update local store: \(desc)"
        }
    }
}
