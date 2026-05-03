import Foundation
import SwiftData
import os

/// Service that manages SwiftData persistence for fixture-light mappings
/// and spatial coordinates. Provides atomic transactions for all
/// persistence operations.
@MainActor
final class FixturePersistence {
    
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "FixturePersistence"
    )
    
    /// Shared singleton instance for app-wide persistence.
    static let shared = FixturePersistence()
    
    /// Create a new ModelContainer with the FixtureMapping schema.
    private init() {
        let schema = Schema([FixtureMapping.self])
        
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [ModelConfiguration()])
            modelContext = ModelContainer.shared.mainContext
            logger.info("FixturePersistence initialized with SwiftData")
        } catch {
            fatalError("Failed to create FixturePersistence container: \(error.localizedDescription)")
        }
    }
    
    /// Load all persisted fixture mappings from SwiftData.
    func loadMappings() -> [FixtureMapping] {
        let descriptor = FetchDescriptor<FixtureMapping>()
        
        do {
            let mappings = try modelContext.fetch(descriptor)
            return mappings.sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            logger.error("Failed to load fixture mappings: \(error.localizedDescription)")
            return []
        }
    }
    
    /// Save a fixture-light mapping with spatial coordinates atomically.
    func saveMapping(
        fixtureId: UUID,
        lightId: String?,
        position: SIMD3<Float>,
        orientation: simd_quatf,
        distanceMeters: Float,
        fixtureType: String,
        confidence: Double
    ) {
        do {
            // Check if a mapping already exists for this fixture
            let descriptor = FetchDescriptor<FixtureMapping>(
                predicate: Predicate<FixtureMapping> { $0.fixtureId == fixtureId.uuidString }
            )
            
            if let existing = try modelContext.fetchFirst(descriptor) {
                existing.lightId = lightId
                existing.positionX = position.x
                existing.positionY = position.y
                existing.positionZ = position.z
                existing.orientationX = orientation.x
                existing.orientationY = orientation.y
                existing.orientationZ = orientation.z
                existing.orientationW = orientation.w
                existing.distanceMeters = distanceMeters
                existing.fixtureType = fixtureType
                existing.confidence = confidence
                existing.updatedAt = Date()
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
                modelContext.insert(mapping)
            }
            
            try modelContext.save()
            logger.debug("Saved fixture mapping for \(fixtureId)")
        } catch {
            logger.error("Failed to save fixture mapping: \(error.localizedDescription)")
        }
    }
    
    /// Link a fixture UUID to a Hue light ID.
    func linkFixture(_ fixtureId: UUID, toLight lightId: String) {
        do {
            let descriptor = FetchDescriptor<FixtureMapping>(
                predicate: Predicate<FixtureMapping> { $0.fixtureId == fixtureId.uuidString }
            )
            
            if let mapping = try modelContext.fetchFirst(descriptor) {
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
                predicate: Predicate<FixtureMapping> { $0.fixtureId == fixtureId.uuidString }
            )
            
            if let mapping = try modelContext.fetchFirst(descriptor) {
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
                predicate: Predicate<FixtureMapping> { $0.fixtureId == fixtureId.uuidString }
            )
            
            if let mapping = try modelContext.fetchFirst(descriptor) {
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
                predicate: Predicate<FixtureMapping> { $0.fixtureId == fixtureId.uuidString }
            )
            
            if let mapping = try modelContext.fetchFirst(descriptor) {
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
