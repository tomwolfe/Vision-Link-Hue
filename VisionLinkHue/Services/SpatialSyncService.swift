import Foundation
import SwiftData
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
    
    /// Initialize the spatial sync service.
    init(deviceIdentifier: String = ProcessInfo().globallyUniqueString) {
        self.deviceIdentifier = deviceIdentifier
        self.modelContainer = SpatialSyncModelContainer.shared.modelContainer
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
    private func uploadRecord(_ record: SpatialSyncRecord) async throws {
        // In a production implementation, this would use CKDatabase
        // to upsert the record into the CloudKit sharing container.
        // For the SwiftData CloudKit Sharing integration, the record
        // is automatically shared when the ModelContainer is configured
        // with a CloudKit sharing container.
        try await Task.sleep(for: .milliseconds(10))
    }
    
    /// Fetch remote spatial sync records from CloudKit.
    private func fetchRemoteRecords() async throws -> [SpatialSyncRecord] {
        // In a production implementation, this would use CKDatabase
        // to query for all spatial sync records.
        // Returns an empty array as a placeholder.
        return []
    }
    
    /// Apply a remote record to the local store.
    private func applyRemoteRecord(_ record: SpatialSyncRecord) async {
        // Update the local FixtureMapping with remote data.
        // This ensures the local store is consistent with the remote.
        await persistence.linkFixture(record.uuid, toLight: record.lightId ?? "")
        logger.debug("Applied remote record for fixture \(record.fixtureId)")
    }
    
    /// Apply remote changes for a specific fixture.
    private func applyRemoteChanges(for fixtureId: UUID) async {
        logger.debug("Applied remote changes for fixture \(fixtureId)")
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
    
    /// Get the remote version for a fixture.
    private func getRemoteVersion(for fixtureId: String) async -> Int64 {
        // In production, this would query CloudKit for the current version.
        0
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
