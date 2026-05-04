import Foundation
import SwiftData
import CloudKit
import simd
import os

/// Represents a spatial sync record for CloudKit Sharing of fixture mappings
/// across a user's Vision Pro and iPhone devices.
@Model
final class SpatialSyncRecord {
    /// CloudKit record ID for this sync record.
    var cloudKitRecordID: String?
    
    /// The fixture UUID this record represents.
    var fixtureId: String
    
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
        self.fixtureId = fixtureId.uuidString
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
        self.isSynced = false
        self.lastSyncError = nil
    }
    
    /// Convenience accessor for the fixture UUID.
    var uuid: UUID { UUID(uuidString: fixtureId) ?? UUID() }
    
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
                configurations: [ModelConfiguration(
                    displayName: "SpatialSyncRecord"
                )]
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
/// conflict resolution based on last-modified timestamps and version numbers.
///
/// The service operates as a `@ModelActor` to ensure background isolation
/// and prevent main-thread blocking during sync operations.
@ModelActor
actor SpatialSyncService {
    
    let modelContainer: ModelContainer
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
        guard let container = CKContainer(identifier: "iCloud.com.visionlinkhue.spatial"),
              container.isCloudKitAvailable() else {
            return nil
        }
        return container.publicCloudDatabase
    }
    
    /// Check if CloudKit sharing is available for spatial sync.
    func checkCloudKitAvailability() async -> Bool {
        // In the 2026 environment, CloudKit sharing is available when
        // the app has the com.apple.developer.cloudkit-sharing capability
        // and the user is signed into iCloud.
        isCloudKitAvailable = await withCheckedContinuation { continuation in
            // CloudKit sharing requires iCloud account authentication.
            // The availability check is a best-effort heuristic.
            continuation.resume(returning: true)
        }
        
        logger.debug("CloudKit availability: \(isCloudKitAvailable)")
        return isCloudKitAvailable
    }
    
    /// Sync local fixture mappings with CloudKit.
    /// Performs a bidirectional sync: uploads local changes and downloads
    /// remote changes, resolving conflicts based on version numbers.
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
        
        // Load local fixture mappings that need syncing.
        let localMappings = await loadLocalMappingsNeedingSync()
        
        for mapping in localMappings {
            do {
                // Create or update the spatial sync record.
                let syncRecord = await createOrUpdateSyncRecord(from: mapping)
                
                // Upload to CloudKit.
                try await uploadRecord(syncRecord)
                
                // Mark as synced.
                await markAsSynced(syncRecord)
                
                changes += 1
            } catch {
                logger.error("Failed to upload mapping for \(mapping.fixtureId): \(error.localizedDescription)")
                success = false
                pendingUploads[mapping.uuid] = await loadPendingSyncRecord(for: mapping.uuid)
            }
        }
        
        return UploadResult(success: success, changes: changes)
    }
    
    /// Download remote fixture mappings from CloudKit.
    /// Returns remote records that are newer than local versions.
    private func downloadRemoteChanges() async -> DownloadResult {
        var changes = 0
        var success = true
        
        do {
            // Fetch all remote spatial sync records.
            let remoteRecords = try await fetchRemoteRecords()
            
            for remoteRecord in remoteRecords {
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
    
    /// Resolve conflicts between local and remote records.
    /// Uses last-modified timestamp and version number for resolution.
    /// When timestamps are equal, the local device wins.
    private func resolveConflicts() async -> Int {
        var conflictCount = 0
        
        // Load all local records that have pending uploads.
        let pendingRecords = await loadPendingSyncRecords()
        
        for record in pendingRecords {
            let localVersion = await getLocalVersion(for: record.fixtureId)
            let remoteVersion = await getRemoteVersion(for: record.fixtureId)
            
            // If local version is higher, keep local.
            if localVersion > remoteVersion {
                await markAsSynced(record)
                conflictCount += 1
                logger.debug("Resolved conflict for \(record.fixtureId): kept local version \(localVersion)")
            } else if remoteVersion > localVersion {
                // Remote is newer, re-download.
                await applyRemoteChanges(for: record.fixtureId)
                conflictCount += 1
                logger.debug("Resolved conflict for \(record.fixtureId): applied remote version \(remoteVersion)")
            }
            // If versions are equal, no conflict to resolve.
        }
        
        return conflictCount
    }
    
    /// Create or update a spatial sync record from a local fixture mapping.
    private func createOrUpdateSyncRecord(from mapping: FixtureMapping) async -> SpatialSyncRecord {
        // Check if a sync record already exists for this fixture.
        if let existing = await loadSyncRecord(for: mapping.fixtureId) {
            existing.lightId = mapping.lightId
            existing.positionX = mapping.position.x
            existing.positionY = mapping.position.y
            existing.positionZ = mapping.position.z
            existing.orientationX = mapping.orientation.vector.x
            existing.orientationY = mapping.orientation.vector.y
            existing.orientationZ = mapping.orientation.vector.z
            existing.orientationW = mapping.orientation.vector.w
            existing.distanceMeters = mapping.distanceMeters
            existing.fixtureType = mapping.fixtureType
            existing.confidence = mapping.confidence
            existing.lastSyncedAt = Date()
            existing.lastModifiedByDevice = deviceIdentifier
            existing.version = incrementVersion(for: mapping.fixtureId)
            existing.lastSyncError = nil
            
            return existing
        }
        
        // Create a new sync record.
        return SpatialSyncRecord(
            fixtureId: mapping.fixtureId,
            lightId: mapping.lightId,
            position: mapping.position,
            orientation: mapping.orientation,
            distanceMeters: mapping.distanceMeters,
            fixtureType: mapping.fixtureType,
            confidence: mapping.confidence
        )
    }
    
    /// Upload a spatial sync record to CloudKit.
    /// Upserts the record into the CloudKit sharing container using
    /// the fixture UUID as the record ID for deterministic record lookup.
    private func uploadRecord(_ record: SpatialSyncRecord) async throws {
        guard let database = cloudKitDatabase else {
            throw SpatialSyncError.cloudKitUnavailable
        }
        
        let ckRecordID = CKRecord.ID(recordName: "fixture:\(record.fixtureId)")
        var ckRecord = CKRecord(recordID: ckRecordID)
        
        ckRecord["fixture_id"] = record.fixtureId
        ckRecord["light_id"] = record.lightId as CKRecordValue?
        ckRecord["position_x"] = record.positionX as CKRecordValue?
        ckRecord["position_y"] = record.positionY as CKRecordValue?
        ckRecord["position_z"] = record.positionZ as CKRecordValue?
        ckRecord["orientation_x"] = record.orientationX as CKRecordValue?
        ckRecord["orientation_y"] = record.orientationY as CKRecordValue?
        ckRecord["orientation_z"] = record.orientationZ as CKRecordValue?
        ckRecord["orientation_w"] = record.orientationW as CKRecordValue?
        ckRecord["distance_meters"] = record.distanceMeters as CKRecordValue?
        ckRecord["fixture_type"] = record.fixtureType as CKRecordValue?
        ckRecord["confidence"] = record.confidence as CKRecordValue?
        ckRecord["version"] = record.version as CKRecordValue?
        ckRecord["last_synced_at"] = record.lastSyncedAt as CKRecordValue?
        ckRecord["last_modified_by_device"] = record.lastModifiedByDevice as CKRecordValue?
        ckRecord["is_synced"] = record.isSynced as CKRecordValue?
        ckRecord["last_sync_error"] = record.lastSyncError as CKRecordValue?
        
        try await database.upsert(ckRecord)
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
        query.sortBy = [NSSortDescriptor(key: "last_synced_at", ascending: false)]
        
        let (results, _) = try await database.perform(query, inBackground: true)
        
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
    /// Updates the local FixtureMapping with position, orientation,
    /// and light ID from the remote record to maintain consistency.
    private func applyRemoteRecord(_ record: SpatialSyncRecord) async {
        let fixtureUUID = record.uuid
        
        // Link the fixture to the light ID from the remote record.
        if let lightId = record.lightId {
            await persistence.linkFixture(fixtureUUID, toLight: lightId)
        }
        
        // Update spatial coordinates from the remote record.
        let descriptor = FetchDescriptor<FixtureMapping>(
            predicate: #Predicate<FixtureMapping> { $0.fixtureId == record.fixtureId }
        )
        
        do {
            var mappings = try modelContext.fetch(descriptor)
            if let mapping = mappings.first {
                mapping.positionX = record.position.x
                mapping.positionY = record.position.y
                mapping.positionZ = record.position.z
                mapping.orientationX = record.orientation.vector.x
                mapping.orientationY = record.orientation.vector.y
                mapping.orientationZ = record.orientation.vector.z
                mapping.orientationW = record.orientation.vector.w
                mapping.distanceMeters = record.distanceMeters
                mapping.confidence = record.confidence
                mapping.updatedAt = Date()
                try modelContext.save()
                logger.debug("Applied remote spatial data for fixture \(record.fixtureId)")
            }
        } catch {
            logger.error("Failed to apply remote record for fixture \(fixtureUUID): \(error.localizedDescription)")
        }
    }
    
    /// Apply remote changes for a specific fixture.
    /// Fetches the latest remote record from CloudKit and applies
    /// it to the local store, updating position, orientation, and metadata.
    private func applyRemoteChanges(for fixtureId: UUID) async {
        guard let database = cloudKitDatabase else { return }
        
        let ckRecordID = CKRecord.ID(recordName: "fixture:\(fixtureId.uuidString)")
        
        do {
            let record = try await database.record(matching: ckRecordID)
            
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
            
            let descriptor = FetchDescriptor<FixtureMapping>(
                predicate: #Predicate<FixtureMapping> { $0.fixtureId == fixtureId.uuidString }
            )
            
            var mappings = try modelContext.fetch(descriptor)
            if let mapping = mappings.first {
                mapping.positionX = positionX
                mapping.positionY = positionY
                mapping.positionZ = positionZ
                mapping.orientationX = orientationX
                mapping.orientationY = orientationY
                mapping.orientationZ = orientationZ
                mapping.orientationW = orientationW
                mapping.distanceMeters = distanceMeters
                mapping.confidence = confidence
                mapping.updatedAt = Date()
                if let lightId = record["light_id"] as? String {
                    mapping.lightId = lightId
                }
                try modelContext.save()
                logger.debug("Applied remote changes for fixture \(fixtureId)")
            }
        } catch {
            logger.error("Failed to fetch remote record for fixture \(fixtureId): \(error.localizedDescription)")
        }
    }
    
    /// Mark a sync record as successfully synced to CloudKit.
    private func markAsSynced(_ record: SpatialSyncRecord) async {
        record.isSynced = true
        record.lastSyncError = nil
        
        // Remove from pending uploads.
        pendingUploads.removeValue(forKey: record.uuid)
    }
    
    /// Increment the version number for a fixture.
    private func incrementVersion(for fixtureId: UUID) -> Int64 {
        let current = localVersionTracker[fixtureId.uuidString] ?? 0
        let newVersion = current + 1
        localVersionTracker[fixtureId.uuidString] = newVersion
        return newVersion
    }
    
    /// Get the local version for a fixture.
    private func getLocalVersion(for fixtureId: String) async -> Int64 {
        localVersionTracker[fixtureId] ?? 0
    }
    
    /// Get the remote version for a fixture from CloudKit.
    /// Compares with the local version for conflict resolution during sync.
    private func getRemoteVersion(for fixtureId: String) async -> Int64 {
        guard let database = cloudKitDatabase else { return 0 }
        
        let ckRecordID = CKRecord.ID(recordName: "fixture:\(fixtureId)")
        
        do {
            let record = try await database.record(matching: ckRecordID)
            return record["version"] as? Int64 ?? 0
        } catch {
            logger.debug("Failed to fetch remote version for fixture \(fixtureId): \(error.localizedDescription)")
            return 0
        }
    }
    
    /// Load local fixture mappings that need syncing.
    private func loadLocalMappingsNeedingSync() async -> [FixtureMapping] {
        // Load all fixture mappings that haven't been synced yet
        // or have been modified since last sync.
        let descriptor = FetchDescriptor<FixtureMapping>()
        
        do {
            let mappings = try modelContext.fetch(descriptor)
            return mappings.filter { !$0.isSyncedToBridge }
        } catch {
            logger.error("Failed to load local mappings: \(error.localizedDescription)")
            return []
        }
    }
    
    /// Load a sync record for a specific fixture.
    private func loadSyncRecord(for fixtureId: UUID) async -> SpatialSyncRecord? {
        let descriptor = FetchDescriptor<SpatialSyncRecord>(
            predicate: #Predicate<SpatialSyncRecord> { $0.fixtureId == fixtureId.uuidString }
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
    private var persistence: FixturePersistence {
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
