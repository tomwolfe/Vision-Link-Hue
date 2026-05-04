import Foundation
import SwiftData
import simd
import os

/// Background actor that manages SwiftData persistence for fixture-light mappings
/// and spatial coordinates. Provides atomic transactions for all
/// persistence operations with background isolation to prevent
/// main-thread blocking as the fixture count grows.
@ModelActor
actor FixturePersistence {
    
    let modelContainer: ModelContainer
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "FixturePersistence"
    )
    
    /// Whether the persistence layer is using in-memory storage instead of
    /// persistent disk storage. When `true`, all fixture mappings will be
    /// lost when the app terminates.
    var isUsingInMemoryStorage: Bool = false
    
    /// Shared singleton instance for app-wide persistence.
    static let shared = FixturePersistence()
    
    /// Create a new ModelContainer with the FixtureMapping schema.
    /// Falls back to an in-memory container if persistent storage fails.
    private init() {
        let schema = Schema([FixtureMapping.self])
        
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [ModelConfiguration()])
            logger.info("FixturePersistence initialized with SwiftData")
        } catch {
            logger.warning("Failed to create persistent SwiftData container, falling back to in-memory: \(error.localizedDescription)")
            isUsingInMemoryStorage = true
            do {
                modelContainer = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
                logger.info("Fallback to in-memory SwiftData succeeded")
            } catch {
                logger.error("In-memory fallback also failed: \(error.localizedDescription)")
                modelContainer = try! ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
            }
        }
    }
    
    /// Initialize with a custom ModelContainer (for testing).
    init(container: ModelContainer) {
        self.modelContainer = container
    }
    
    /// Load all persisted fixture mappings from SwiftData.
    func loadMappings() async -> [(uuid: UUID, lightId: String?)] {
        let descriptor = FetchDescriptor<FixtureMapping>()
        
        do {
            let mappings = try modelContext.fetch(descriptor)
            return mappings
                .map { ($0.uuid, $0.lightId) }
                .sorted { $0.1 ?? "" < $1.1 ?? "" }
        } catch {
            logger.error("Failed to load fixture mappings: \(error.localizedDescription)")
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
                predicate: #Predicate<FixtureMapping> { $0.fixtureId == fixtureId.uuidString }
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
                predicate: #Predicate<FixtureMapping> { $0.fixtureId == fixtureId.uuidString }
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
                predicate: #Predicate<FixtureMapping> { $0.fixtureId == fixtureId.uuidString }
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
                predicate: #Predicate<FixtureMapping> { $0.fixtureId == fixtureId.uuidString }
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
                predicate: #Predicate<FixtureMapping> { $0.fixtureId == fixtureId.uuidString }
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
    var container: ModelContainer {
        modelContainer
    }
}
