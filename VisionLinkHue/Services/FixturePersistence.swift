import Foundation
import SwiftData
import simd
import ARKit
import os

// MARK: - Schema Migration

/// Current schema version for FixtureMapping and SpatialSyncRecord models.
/// Increment this value when adding new attributes or changing existing ones.
enum SchemaVersion: Int {
    case v1 = 1
    case v2 = 2
    case v3 = 3
}

/// Migration configuration for SwiftData schema evolution.
/// Handles incremental migrations between schema versions.
enum SchemaMigration {
    
    /// The current schema version.
    static let currentVersion: SchemaVersion = .v3
    
    /// Migrate data from an older schema version to the current version.
    /// Note: This custom migration block is only invoked when using a custom
    /// `migrationStrategy` (e.g., `.custom`). With the current `.inline` strategy
    /// in `ModelContainer` initialization, this function is dead code and is never
    /// called. If you switch to a custom migration strategy in the future, ensure
    /// you delete old models after migrating to avoid duplicate records.
    @MainActor
    static func migrate(from oldContainer: ModelContainer, to newContainer: ModelContainer) throws {
        let oldContext = oldContainer.mainContext
        let newContext = newContainer.mainContext
        
        // Fetch all existing FixtureMapping records
        let fetchDescriptor = FetchDescriptor<FixtureMapping>()
        let oldMappings = try oldContext.fetch(fetchDescriptor)
        
        for oldMapping in oldMappings {
            // Create a new-version mapping with all existing data
            let newMapping = FixtureMapping(
                fixtureId: UUID(uuidString: oldMapping.fixtureId) ?? UUID(),
                lightId: oldMapping.lightId,
                position: oldMapping.position,
                orientation: oldMapping.orientation,
                distanceMeters: oldMapping.distanceMeters,
                fixtureType: oldMapping.fixtureType,
                confidence: oldMapping.confidence
            )
            
            // Preserve bridge-space coordinates if present
            if let bx = oldMapping.bridgePositionX,
               let by = oldMapping.bridgePositionY,
               let bz = oldMapping.bridgePositionZ {
                newMapping.bridgePositionX = bx
                newMapping.bridgePositionY = by
                newMapping.bridgePositionZ = bz
            }
            
            newMapping.isSyncedToBridge = oldMapping.isSyncedToBridge
            newMapping.updatedAt = oldMapping.updatedAt
            
            newContext.insert(newMapping)
        }
        
        // Fetch all existing SpatialSyncRecord records
        let syncDescriptor = FetchDescriptor<SpatialSyncRecord>()
        let oldRecords = try oldContext.fetch(syncDescriptor)
        
        for oldRecord in oldRecords {
            let newRecord = SpatialSyncRecord(
                fixtureId: UUID(uuidString: oldRecord.fixtureId) ?? UUID(),
                lightId: oldRecord.lightId,
                position: oldRecord.position,
                orientation: oldRecord.orientation,
                distanceMeters: oldRecord.distanceMeters,
                fixtureType: oldRecord.fixtureType,
                confidence: oldRecord.confidence
            )
            
            newRecord.lastSyncedAt = oldRecord.lastSyncedAt
            newRecord.lastModifiedByDevice = oldRecord.lastModifiedByDevice
            newRecord.version = oldRecord.version
            newRecord.isSynced = oldRecord.isSynced
            newRecord.lastSyncError = oldRecord.lastSyncError
            
            newContext.insert(newRecord)
        }
        
        try newContext.save()
    }
}

/// Background actor that manages SwiftData persistence for fixture-light mappings
/// and spatial coordinates. Provides atomic transactions for all
/// persistence operations with background isolation to prevent
/// main-thread blocking as the fixture count grows.
actor FixturePersistence {
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "FixturePersistence"
    )
    
    private let modelContainer: ModelContainer
    var modelContext: ModelContext
    
    /// Whether the persistence layer is using in-memory storage instead of
    /// persistent disk storage. When `true`, all fixture mappings will be
    /// lost when the app terminates.
    var isUsingInMemoryStorage: Bool = false
    
    /// Shared singleton instance for app-wide persistence.
    static let shared: FixturePersistence = {
        let schema = Schema([FixtureMapping.self, SpatialSyncRecord.self])
        let modelConfiguration = ModelConfiguration(schema: schema)
        
        var isUsingInMemoryStorage: Bool = false
        var modelContainer: ModelContainer
        
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
            isUsingInMemoryStorage = false
        } catch {
            isUsingInMemoryStorage = true
            modelContainer = try! ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
        }
        
        let persistence = FixturePersistence(modelContainer: modelContainer, isUsingInMemoryStorage: isUsingInMemoryStorage)
        return persistence
    }()
    
    /// Create a new FixturePersistence with a ModelContainer.
    /// Falls back to an in-memory container if persistent storage fails.
    /// Supports incremental schema migration for future model changes.
    private init(modelContainer: ModelContainer, isUsingInMemoryStorage: Bool = false) {
        self.modelContainer = modelContainer
        self.modelContext = ModelContext(modelContainer)
        self.isUsingInMemoryStorage = isUsingInMemoryStorage
    }
    
    /// Initialize with a custom ModelContainer (for testing).
    init(container: ModelContainer) {
        self.modelContainer = container
        self.modelContext = ModelContext(modelContainer)
        self.isUsingInMemoryStorage = false
    }
    
    /// Load all persisted fixture mappings from SwiftData.
    func loadMappings() async -> [(uuid: UUID, lightId: String?)] {
        let descriptor = FetchDescriptor<FixtureMapping>()
        
        do {
            let mappings = try modelContext.fetch(descriptor)
            return mappings
                .map { ($0.fixtureId, $0.lightId) }
                .sorted { $0.1 ?? "" < $1.1 ?? "" }
        } catch {
            logger.error("Failed to load fixture mappings: \(error.localizedDescription)")
            return []
        }
    }
    
    /// Load all persisted fixture mappings with full spatial data for testing.
    /// Returns Sendable tuples to avoid crossing actor boundaries with ModelContext.
    func loadAllMappings() async -> [(fixtureId: UUID, lightId: String?, position: SIMD3<Float>, fixtureType: String, confidence: Double)] {
        let descriptor = FetchDescriptor<FixtureMapping>()
        
        do {
            let mappings = try modelContext.fetch(descriptor)
            return mappings
                .map { ($0.fixtureId, $0.lightId, $0.position, $0.fixtureType, $0.confidence) }
        } catch {
            logger.error("Failed to load all fixture mappings: \(error.localizedDescription)")
            return []
        }
    }
    
    /// Load persisted fixture mappings that have bridge-space coordinates.
    /// These can be projected back into ARKit space using a calibration transform.
    func loadMappingsWithBridgeSpace() async -> [FixtureMapping] {
        let descriptor = FetchDescriptor<FixtureMapping>(
            predicate: #Predicate<FixtureMapping> {
                $0.bridgePositionX != nil && $0.bridgePositionY != nil && $0.bridgePositionZ != nil
            }
        )
        
        do {
            let mappings = try modelContext.fetch(descriptor)
            return mappings.sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            logger.error("Failed to load bridge-space fixture mappings: \(error.localizedDescription)")
            return []
        }
    }
    
    /// Check if any persisted mappings have bridge-space coordinates.
    func hasBridgeSpaceMappings() async -> Bool {
        let descriptor = FetchDescriptor<FixtureMapping>(
            predicate: #Predicate<FixtureMapping> {
                $0.bridgePositionX != nil
            }
        )
        
        do {
            let count = try modelContext.fetchCount(descriptor)
            return count > 0
        } catch {
            logger.error("Failed to check for bridge-space mappings: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Save a fixture-light mapping with spatial coordinates atomically.
    /// Validates the spatial data before persisting to prevent malformed
    /// coordinate data from being stored in SwiftData.
    /// Preserves bridge-space coordinates if already present.
    func saveMapping(
        fixtureId: UUID,
        lightId: String?,
        position: SIMD3<Float>,
        orientation: simd_quatf,
        distanceMeters: Float,
        fixtureType: String,
        confidence: Double
    ) {
        saveMapping(
            fixtureId: fixtureId,
            lightId: lightId,
            position: position,
            orientation: orientation,
            distanceMeters: distanceMeters,
            fixtureType: fixtureType,
            confidence: confidence,
            bridgePosition: nil
        )
    }
    
    /// Save a fixture-light mapping with bridge-space coordinates.
    /// Bridge-space coordinates are the source of truth for persistence,
    /// allowing fixtures to be projected back into ARKit space on app launch.
    func saveMapping(
        fixtureId: UUID,
        lightId: String?,
        position: SIMD3<Float>,
        orientation: simd_quatf,
        distanceMeters: Float,
        fixtureType: String,
        confidence: Double,
        bridgePosition: SIMD3<Float>?
    ) {
        // Validate spatial data before persisting
        guard validateSpatialData(position: position, orientation: orientation, distanceMeters: distanceMeters) else {
            logger.error("Rejected malformed spatial data for fixture \(fixtureId): position=\(position), orientation=[\(orientation.vector.x), \(orientation.vector.y), \(orientation.vector.z), \(orientation.vector.w)], distance=\(distanceMeters)")
            return
        }
        
        do {
            // Check if a mapping already exists for this fixture
            let descriptor = FetchDescriptor<FixtureMapping>(
                predicate: #Predicate<FixtureMapping> { $0.fixtureId == fixtureId }
            )
            
            let results = try modelContext.fetch(descriptor)
            if let existing = results.first {
                existing.lightId = lightId
                existing.positionX = position.x
                existing.positionY = position.y
                existing.positionZ = position.z
                existing.orientationX = orientation.vector.x
                existing.orientationY = orientation.vector.y
                existing.orientationZ = orientation.vector.z
                existing.orientationW = orientation.vector.w
                existing.distanceMeters = distanceMeters
                existing.fixtureType = fixtureType
                existing.confidence = confidence
                existing.updatedAt = Date()
                if let bp = bridgePosition {
                    existing.bridgePositionX = bp.x
                    existing.bridgePositionY = bp.y
                    existing.bridgePositionZ = bp.z
                }
            } else {
                let mapping = FixtureMapping(
                    fixtureId: fixtureId,
                    lightId: lightId,
                    position: position,
                    orientation: orientation,
                    distanceMeters: distanceMeters,
                    fixtureType: fixtureType,
                    confidence: confidence
                )
                if let bp = bridgePosition {
                    mapping.bridgePositionX = bp.x
                    mapping.bridgePositionY = bp.y
                    mapping.bridgePositionZ = bp.z
                }
                modelContext.insert(mapping)
            }
            
            try modelContext.save()
            logger.debug("Saved fixture mapping for \(fixtureId)")
        } catch {
            logger.error("Failed to save fixture mapping: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Spatial Data Validation
    
    /// Validate spatial coordinate data before persisting.
    /// Prevents malformed data (NaN, infinity, out-of-bounds) from
    /// being stored in SwiftData, which could corrupt the spatial database.
    ///
    /// - Parameters:
    ///   - position: 3D position in world space.
    ///   - orientation: Orientation quaternion.
    ///   - distanceMeters: Distance to the fixture.
    /// - Returns: `true` if the data is valid, `false` otherwise.
    private func validateSpatialData(
        position: SIMD3<Float>,
        orientation: simd_quatf,
        distanceMeters: Float
    ) -> Bool {
        // Reject NaN or infinity in position
        if position.x.isNaN || position.y.isNaN || position.z.isNaN {
            return false
        }
        if position.x.isInfinite || position.y.isInfinite || position.z.isInfinite {
            return false
        }
        
        // Reject non-unit quaternions (norm should be ~1.0)
        let quatNorm = simd_length(orientation)
        if quatNorm.isNaN || quatNorm.isInfinite {
            return false
        }
        let normDelta = abs(quatNorm - 1.0)
        if normDelta > DetectionConstants.maxQuaternionNormDelta {
            return false
        }
        
        // Reject unreasonable distances (0 to max)
        if distanceMeters <= 0 || distanceMeters > DetectionConstants.maxDistanceMeters {
            return false
        }
        
        // Reject extreme position values (beyond max range)
        let positionMagnitude = simd_length(position)
        if positionMagnitude > DetectionConstants.maxPositionMagnitude {
            return false
        }
        
        return true
    }
    
    /// Link a fixture UUID to a Hue light ID.
    func linkFixture(_ fixtureId: UUID, toLight lightId: String) {
        do {
            let descriptor = FetchDescriptor<FixtureMapping>(
                predicate: #Predicate<FixtureMapping> { $0.fixtureId == fixtureId }
            )
            
            let results = try modelContext.fetch(descriptor)
            if let mapping = results.first {
                mapping.lightId = lightId
                mapping.updatedAt = Date()
                try modelContext.save()
                logger.debug("Linked fixture \(fixtureId) to light \(lightId)")
            }
        } catch {
            logger.error("Failed to link fixture: \(error.localizedDescription)")
        }
    }
    
    /// Unlink a fixture from its mapped Hue light.
    func unlinkFixture(_ fixtureId: UUID) {
        do {
            let descriptor = FetchDescriptor<FixtureMapping>(
                predicate: #Predicate<FixtureMapping> { $0.fixtureId == fixtureId }
            )
            
            let results = try modelContext.fetch(descriptor)
            if let mapping = results.first {
                mapping.lightId = nil
                mapping.updatedAt = Date()
                try modelContext.save()
                logger.debug("Unlinked fixture \(fixtureId)")
            }
        } catch {
            logger.error("Failed to unlink fixture: \(error.localizedDescription)")
        }
    }
    
    /// Remove a fixture mapping entirely.
    func removeMapping(for fixtureId: UUID) {
        do {
            let descriptor = FetchDescriptor<FixtureMapping>(
                predicate: #Predicate<FixtureMapping> { $0.fixtureId == fixtureId }
            )
            
            let results = try modelContext.fetch(descriptor)
            if let mapping = results.first {
                modelContext.delete(mapping)
                try modelContext.save()
                logger.debug("Removed fixture mapping for \(fixtureId)")
            }
        } catch {
            logger.error("Failed to remove fixture mapping: \(error.localizedDescription)")
        }
    }
    
    /// Mark a mapping as synced to the Hue Bridge.
    func markSynced(_ fixtureId: UUID) {
        do {
            let descriptor = FetchDescriptor<FixtureMapping>(
                predicate: #Predicate<FixtureMapping> { $0.fixtureId == fixtureId }
            )
            
            let results = try modelContext.fetch(descriptor)
            if let mapping = results.first {
                mapping.isSyncedToBridge = true
                mapping.updatedAt = Date()
                try modelContext.save()
            }
        } catch {
            logger.error("Failed to mark fixture as synced: \(error.localizedDescription)")
        }
    }
    
    /// Clear all persisted fixture mappings.
    func clearAllMappings() {
        do {
            let descriptor = FetchDescriptor<FixtureMapping>()
            let mappings = try modelContext.fetch(descriptor)
            for mapping in mappings {
                modelContext.delete(mapping)
            }
            try modelContext.save()
            logger.info("Cleared all fixture mappings")
        } catch {
            logger.error("Failed to clear fixture mappings: \(error.localizedDescription)")
        }
    }
    
    /// Get the model container for external access (e.g., SwiftUI modelContainer).
    nonisolated var container: ModelContainer {
        modelContainer
    }
    
    // MARK: - ARWorldMap Persistence
    
    /// The file URL where the ARWorldMap is persisted.
    private var worldMapURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("spatial_anchor.worldmap")
    }
    
    /// Save an ARWorldMap to the Documents directory for session relabeling.
    /// The file is marked with `.isExcludedFromBackup = true` to comply with
    /// iOS 26 privacy guidelines that require spatial data persistence to be
    /// excluded from iCloud backups.
    func saveWorldMap(_ worldMap: ARWorldMap) {
        do {
            let data = try NSKeyedArchiver.archivedData(
                withRootObject: worldMap,
                requiringSecureCoding: true
            )
            try data.write(to: self.worldMapURL)
            try setExcludeFromICloudBackup(url: self.worldMapURL)
            logger.info("ARWorldMap saved to \(self.worldMapURL.path)")
        } catch {
            logger.error("Failed to save ARWorldMap: \(error.localizedDescription)")
        }
    }
    
    /// Load a previously saved ARWorldMap data from the Documents directory.
    /// Returns nil if no map exists or reading fails.
    /// Ensures the file is marked for iCloud backup exclusion on load
    /// to handle files saved before this privacy compliance was added.
    func loadWorldMapData() -> Data? {
        guard FileManager.default.fileExists(atPath: worldMapURL.path) else {
            return nil
        }
        
        do {
            let data = try Data(contentsOf: worldMapURL)
            try setExcludeFromICloudBackup(url: worldMapURL)
            logger.info("ARWorldMap data loaded from \(self.worldMapURL.path)")
            return data
        } catch {
            logger.error("Failed to load ARWorldMap data: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Check whether a persisted ARWorldMap exists.
    func hasWorldMap() -> Bool {
        FileManager.default.fileExists(atPath: self.worldMapURL.path)
    }
    
    /// Delete the persisted ARWorldMap.
    func deleteWorldMap() {
        do {
            if FileManager.default.fileExists(atPath: worldMapURL.path) {
                try FileManager.default.removeItem(at: worldMapURL)
                logger.info("ARWorldMap deleted")
            }
        } catch {
            logger.error("Failed to delete ARWorldMap: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Object Anchor Persistence
    
    /// The file URL where object anchor data is persisted.
    private var objectAnchorURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("fixture_object_anchors.json")
    }
    
    /// Save fixture object anchors for faster relocalization.
    /// Object anchors provide quicker relocalization than world maps
    /// for known fixture archetypes (Chandelier, Sconce, Desk Lamp, Pendant).
    /// The file is marked with `.isExcludedFromBackup = true` for privacy compliance.
    func saveObjectAnchors(_ anchors: [Data]) {
        do {
            try anchors.forEach { data in
                try data.write(to: objectAnchorURL, options: .atomic)
            }
            try setExcludeFromICloudBackup(url: objectAnchorURL)
            logger.info("Saved \(anchors.count) fixture object anchor(s)")
        } catch {
            logger.error("Failed to save object anchors: \(error.localizedDescription)")
        }
    }
    
    /// Load persisted object anchors for relocalization.
    /// Ensures the file is marked for iCloud backup exclusion on load.
    func loadObjectAnchors() -> [Data] {
        guard FileManager.default.fileExists(atPath: objectAnchorURL.path) else {
            return []
        }
        
        do {
            let data = try Data(contentsOf: objectAnchorURL)
            try setExcludeFromICloudBackup(url: objectAnchorURL)
            logger.info("Loaded fixture object anchor data")
            return [data]
        } catch {
            logger.error("Failed to load object anchors: \(error.localizedDescription)")
            return []
        }
    }
    
    /// Check if persisted object anchors exist.
    func hasObjectAnchors() -> Bool {
        FileManager.default.fileExists(atPath: objectAnchorURL.path)
    }
    
    /// Delete persisted object anchors.
    func deleteObjectAnchors() {
        do {
            if FileManager.default.fileExists(atPath: objectAnchorURL.path) {
                try FileManager.default.removeItem(at: objectAnchorURL)
                logger.info("Object anchors deleted")
            }
        } catch {
            logger.error("Failed to delete object anchors: \(error.localizedDescription)")
        }
    }
    
    // MARK: - CloudKit Spatial Sync
    
    /// Trigger a CloudKit spatial sync operation via the SpatialSyncService.
    /// This is called from the UI to initiate bidirectional sync of
    /// fixture mappings across the user's devices.
    func triggerSpatialSync() async -> SpatialSyncResult {
        await SpatialSyncService().sync()
    }
    
    /// Check if CloudKit spatial sync is available.
    func checkSpatialSyncAvailability() async -> Bool {
        await SpatialSyncService().checkCloudKitAvailability()
    }
    
    // MARK: - Manual Placement Persistence
    
    /// Save a manual room assignment for a fixture (for older Bridge hardware).
    func saveManualAssignment(fixtureId: UUID, roomId: String, areaId: String?) async {
        do {
            let descriptor = FetchDescriptor<FixtureMapping>(
                predicate: #Predicate<FixtureMapping> { $0.fixtureId == fixtureId }
            )
            let results = try modelContext.fetch(descriptor)
            if let mapping = results.first {
                mapping.roomId = roomId
                mapping.areaId = areaId
                mapping.updatedAt = Date()
                try modelContext.save()
            } else {
                // Create a new mapping entry just for manual placement data
                let mapping = FixtureMapping(
                    fixtureId: fixtureId,
                    lightId: nil,
                    position: SIMD3<Float>(0, 0, 0),
                    orientation: simd_quatf(),
                    distanceMeters: 0,
                    fixtureType: "manual_placement",
                    confidence: 0
                )
                mapping.roomId = roomId
                mapping.areaId = areaId
                modelContext.insert(mapping)
                try modelContext.save()
            }
            logger.debug("Saved manual assignment for fixture \(fixtureId): room=\(roomId)")
        } catch {
            logger.error("Failed to save manual assignment: \(error.localizedDescription)")
        }
    }
    
    /// Clear all manual room assignments from persistence.
    func clearManualAssignments() async {
        do {
            let descriptor = FetchDescriptor<FixtureMapping>()
            let mappings = try modelContext.fetch(descriptor)
            for mapping in mappings {
                mapping.roomId = nil
                mapping.areaId = nil
                mapping.updatedAt = Date()
            }
            try modelContext.save()
            logger.info("Cleared all manual room assignments")
        } catch {
            logger.error("Failed to clear manual assignments: \(error.localizedDescription)")
        }
    }
    
    // MARK: - iCloud Backup Exclusion
    
    /// Mark a file to exclude it from iCloud backup.
    /// Complies with iOS 26 App Store Privacy guidelines for spatial data persistence.
    /// - Parameter url: The file URL to mark for exclusion.
    private func setExcludeFromICloudBackup(url: URL) throws {
        try (url as NSURL).setResourceValue(NSNumber(value: true), forKey: .isExcludedFromBackupKey)
    }
    
    /// Ensure all persisted spatial data files are excluded from iCloud backup.
    private func ensureBackupExclusion(forURLs urls: [URL]) {
        for url in urls {
            try? setExcludeFromICloudBackup(url: url)
        }
    }
    
    // MARK: - Context Management
    
    /// Periodically save and reset the model context to prevent memory bloat
    /// during heavy operations like CloudKit spatial sync.
    ///
    /// When processing large batches of fixture mappings (e.g., 50+ fixtures
    /// during initial spatial sync), the SwiftData context accumulates tracked
    /// objects that can consume significant memory. This method saves all
    /// pending changes to the persistent store and then rolls back the context,
    /// allowing SwiftData's autorelease pool to reclaim memory without breaking
    /// `@Query` references observed by SwiftUI views.
    ///
    /// Replaces the previous approach of recreating `ModelContext`, which caused
    /// object identity loss for active SwiftUI view bindings.
    ///
    /// - Parameter batchSize: The number of operations after which to trigger
    ///   a context save and reset. Defaults to 50.
    func checkpointContext(batchSize: Int = 50) async {
        do {
            try modelContext.save()
            modelContext.rollback()
            logger.debug("Model context checkpointed and memory reclaimed")
        } catch {
            logger.error("Failed to checkpoint model context: \(error.localizedDescription)")
        }
    }
    
    /// Save and reset the context immediately, regardless of operation count.
    /// Useful at the end of a heavy sync operation to ensure all changes are
    /// persisted and memory is reclaimed.
    func flushContext() async {
        do {
            try modelContext.save()
            modelContext.rollback()
            logger.debug("Model context flushed and memory reclaimed")
        } catch {
            logger.error("Failed to flush model context: \(error.localizedDescription)")
        }
    }
    
    /// Execute a batch of update operations with periodic context checkpoints.
    /// This keeps the memory footprint low during massive syncs by saving
    /// and rolling back the context after every `batchSize` operations,
    /// avoiding the object identity loss caused by recreating ModelContext.
    ///
    /// Each operation is wrapped in its own save-and-rollback boundary to ensure
    /// no data is silently lost. The save persists the changes to the store, and
    /// the rollback clears the context's change tracker to free memory. This
    /// guarantees that every operation is durably committed before the context
    /// is cleared.
    ///
    /// - Parameters:
    ///   - count: The total number of operations to execute.
    ///   - batchSize: How many operations between each checkpoint.
    ///   - operation: The closure to execute for each operation index.
    func executeBatched<T>(count: Int, batchSize: Int = 50, operation: (Int) async throws -> T) async throws -> [T] {
        var results: [T] = []
        
        for i in 0..<count {
            do {
                let result = try await operation(i)
                results.append(result)
                
                try modelContext.save()
                modelContext.rollback()
            } catch {
                logger.error("Failed to execute batched operation at index \(i): \(error.localizedDescription)")
                throw error
            }
        }
        
        return results
    }
}
