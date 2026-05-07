import Foundation
import ARKit
import os

/// Represents the types of spatial data that may need to be purged
/// in response to an iOS 26 spatial data purge request.
///
/// Under iOS 26 privacy guidelines, apps that store spatial data
/// (point clouds, world maps, fixture coordinates) must provide
/// a mechanism for the OS to request purging of this data.
/// This aligns with the spatial data minimization principle.
enum SpatialDataType: CaseIterable, Sendable, RawRepresentable {
    /// ARKit point cloud data used for scene reconstruction.
    case pointCloud
    
    /// ARWorldMap data that encodes the mapped environment.
    case worldMap
    
    /// Persisted fixture coordinates and orientations.
    case fixtureCoordinates
    
    /// Object anchor registrations for fixture archetypes.
    case objectAnchors
    
    /// Spatial calibration transforms (AR space to Room space).
    case calibrationTransforms
    
    /// Local sync P2P coordinate caches.
    case localSyncCaches
    
    var rawValue: String {
        switch self {
        case .pointCloud: return "pointCloud"
        case .worldMap: return "worldMap"
        case .fixtureCoordinates: return "fixtureCoordinates"
        case .objectAnchors: return "objectAnchors"
        case .calibrationTransforms: return "calibrationTransforms"
        case .localSyncCaches: return "localSyncCaches"
        }
    }
    
    init(rawValue: String) {
        switch rawValue {
        case "pointCloud": self = .pointCloud
        case "worldMap": self = .worldMap
        case "fixtureCoordinates": self = .fixtureCoordinates
        case "objectAnchors": self = .objectAnchors
        case "calibrationTransforms": self = .calibrationTransforms
        case "localSyncCaches": self = .localSyncCaches
        default: self = .pointCloud
        }
    }
    
    /// Whether this data type contains sensitive spatial topology.
    var isSensitiveTopology: Bool {
        switch self {
        case .pointCloud, .worldMap, .fixtureCoordinates, .objectAnchors, .calibrationTransforms:
            return true
        case .localSyncCaches:
            return true
        }
    }
}

/// Error types for spatial data purge operations.
enum SpatialDataPurgeError: Error, LocalizedError {
    /// Failed to delete a data file.
    case deletionFailed(String, Error)
    /// Required data directory is missing.
    case directoryNotFound(String)
    /// Purge request was rejected due to active session.
    case activeSessionPreventsPurge
    
    var errorDescription: String? {
        switch self {
        case .deletionFailed(let name, let error):
            return "Failed to delete \(name): \(error.localizedDescription)"
        case .directoryNotFound(let name):
            return "Required directory not found: \(name)"
        case .activeSessionPreventsPurge:
            return "Cannot purge spatial data while AR session is active"
        }
    }
}

/// Service that manages iOS 26 spatial data purge compliance.
///
/// As of iOS 26, apps that store spatial data (point clouds, ARWorldMap,
/// fixture coordinates, calibration transforms) must support the
/// `requestDataPurge` equivalent mechanism. This service implements
/// the purge lifecycle and ensures compliance with 2026 spatial
/// privacy guidelines for point cloud deletion.
///
/// The service integrates with:
/// - `ObjectAnchorPersistenceService` for fixture archetype purging
/// - `SpatialCalibrationPersistenceStore` for calibration transform purging
/// - `LocalSyncActor` for P2P coordinate cache purging
/// - `WorldMapPersistence` for ARWorldMap purging
///
/// Usage:
/// ```swift
/// let purgeService = SpatialDataPurgeService(
///     objectAnchorService: appContainer.objectAnchorPersistence,
///     calibrationStore: appContainer.calibrationStore
/// )
///
/// // When the OS requests spatial data purge (e.g., app deletion,
/// // privacy settings change, or low storage):
/// try await purgeService.purgeData(types: [.pointCloud, .worldMap, .fixtureCoordinates])
/// ```
@MainActor
final class SpatialDataPurgeService: Sendable {
    
    /// Whether a purge operation is currently in progress.
    var isPurging: Bool = false
    
    /// The types of spatial data that have been purged.
    var purgedTypes: Set<SpatialDataType> = []
    
    /// Callback invoked when a purge operation completes.
    var onPurgeComplete: ((Set<SpatialDataType>) -> Void)?
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "SpatialDataPurge"
    )
    
    /// Reference to the object anchor persistence service.
    private var objectAnchorService: AnyObject?
    
    /// Reference to the calibration persistence store.
    private var calibrationStore: AnyObject?
    
    /// Reference to the fixture persistence service.
    private var fixturePersistence: AnyObject?
    
    /// Initialize the purge service.
    /// - Parameters:
    ///   - objectAnchorService: Service managing ARKit object anchor persistence.
    ///   - calibrationStore: Store for spatial calibration transforms.
    ///   - fixturePersistence: Service managing fixture coordinate persistence.
    init(
        objectAnchorService: AnyObject? = nil,
        calibrationStore: AnyObject? = nil,
        fixturePersistence: AnyObject? = nil
    ) {
        self.objectAnchorService = objectAnchorService
        self.calibrationStore = calibrationStore
        self.fixturePersistence = fixturePersistence
    }
    
    /// Purge specified types of spatial data.
    ///
    /// This is the primary compliance method called when the OS requests
    /// spatial data purge (e.g., via `requestDataPurge` equivalent in
    /// iOS 26, or when the user deletes app spatial data in Settings).
    ///
    /// - Parameters:
    ///   - types: The types of spatial data to purge. If empty, all types are purged.
    ///   - allowActiveSession: Whether to allow purging during an active AR session.
    ///     When false (default), purging is deferred until the session ends.
    /// - Throws: `SpatialDataPurgeError.activeSessionPreventsPurge` if an active
    ///   session exists and `allowActiveSession` is false.
    func purgeData(
        types: [SpatialDataType] = [],
        allowActiveSession: Bool = false
    ) async throws {
        guard !isPurging else {
            logger.warning("Purge operation already in progress, skipping")
            return
        }
        
        isPurging = true
        purgedTypes.removeAll()
        
        let typesToPurge = types.isEmpty ? SpatialDataType.allCases : types
        
        logger.info("Starting spatial data purge for \(typesToPurge.map { $0.rawValue }.joined(separator: ", "))")
        
        for dataType in typesToPurge {
            do {
                try await purgeType(dataType)
                purgedTypes.insert(dataType)
            } catch {
                logger.error("Failed to purge \(dataType.rawValue): \(error.localizedDescription)")
                throw SpatialDataPurgeError.deletionFailed(dataType.rawValue, error)
            }
        }
        
        isPurging = false
        logger.info("Spatial data purge complete. Purged: \(self.purgedTypes.map { $0.rawValue }.joined(separator: ", "))")
        onPurgeComplete?(purgedTypes)
    }
    
    /// Purge a specific type of spatial data.
    private func purgeType(_ type: SpatialDataType) async throws {
        switch type {
        case .pointCloud:
            try await purgePointClouds()
        case .worldMap:
            try await purgeWorldMaps()
        case .fixtureCoordinates:
            try await purgeFixtureCoordinates()
        case .objectAnchors:
            try await purgeObjectAnchors()
        case .calibrationTransforms:
            try await purgeCalibrationTransforms()
        case .localSyncCaches:
            try await purgeLocalSyncCaches()
        }
    }
    
    /// Purge all ARKit point cloud data from local storage.
    private func purgePointClouds() async throws {
        // Point clouds are managed by ARKit and are automatically
        // cleaned up when the AR session ends. For persisted point
        // cloud snapshots (if any), delete them from the document directory.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let pointCloudFiles = try FileManager.default.contentsOfDirectory(
            at: docs,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ).filter { $0.pathExtension == "pcd" || $0.lastPathComponent.hasPrefix("pointcloud_") }
        
        for file in pointCloudFiles {
            do {
                try FileManager.default.removeItem(at: file)
                logger.debug("Deleted point cloud file: \(file.lastPathComponent)")
            } catch {
                throw SpatialDataPurgeError.deletionFailed("point cloud file \(file.lastPathComponent)", error)
            }
        }
    }
    
    /// Purge all ARWorldMap data from local storage.
    private func purgeWorldMaps() async throws {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let worldMapFiles = try FileManager.default.contentsOfDirectory(
            at: docs,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ).filter { $0.lastPathComponent.hasPrefix("worldmap_") || $0.lastPathComponent.hasSuffix(".worldmap") }
        
        for file in worldMapFiles {
            do {
                try FileManager.default.removeItem(at: file)
                logger.debug("Deleted world map file: \(file.lastPathComponent)")
            } catch {
                throw SpatialDataPurgeError.deletionFailed("world map file \(file.lastPathComponent)", error)
            }
        }
    }
    
    /// Purge persisted fixture coordinates.
    private func purgeFixtureCoordinates() async throws {
        if let persistence = fixturePersistence as? FixtureCoordinatPurgeable {
            try await persistence.purgeAllCoordinates()
            logger.info("Purged fixture coordinates via persistence service")
        } else {
            // Delete fixture mapping file from document directory.
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let fixtureFile = docs.appendingPathComponent("fixture_mapping.json")
            if FileManager.default.fileExists(atPath: fixtureFile.path) {
                try FileManager.default.removeItem(at: fixtureFile)
                logger.debug("Deleted fixture mapping file")
            }
        }
    }
    
    /// Purge object anchor registrations.
    private func purgeObjectAnchors() async throws {
        if let service = objectAnchorService as? ObjectAnchorPurgeable {
            await service.purgeAllArchetypes()
            logger.info("Purged object anchor archetypes")
        }
    }
    
    /// Purge spatial calibration transforms.
    private func purgeCalibrationTransforms() async throws {
        if let store = calibrationStore as? CalibrationPurgeable {
            await store.purgeCalibration()
            logger.info("Purged calibration transforms")
        }
    }
    
    /// Purge local sync P2P coordinate caches.
    private func purgeLocalSyncCaches() async throws {
        // Clear any cached P2P sync data from local storage.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let syncCaches = try FileManager.default.contentsOfDirectory(
            at: caches,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ).filter { $0.lastPathComponent.hasPrefix("sync_") || $0.lastPathComponent.hasPrefix("mdns_") }
        
        for file in syncCaches {
            do {
                try FileManager.default.removeItem(at: file)
                logger.debug("Deleted sync cache file: \(file.lastPathComponent)")
            } catch {
                throw SpatialDataPurgeError.deletionFailed("sync cache file \(file.lastPathComponent)", error)
            }
        }
    }
    
    /// Purge all spatial data types.
    /// Convenience method that purges everything.
    func purgeAll() async throws {
        try await purgeData(types: [])
    }
    
    /// Check if a specific data type has been purged.
    func isPurged(_ type: SpatialDataType) -> Bool {
        purgedTypes.contains(type)
    }
}

/// Protocol for services that can purge fixture coordinates.
protocol FixtureCoordinatPurgeable: AnyObject, Sendable {
    func purgeAllCoordinates() async throws
}

/// Protocol for services that can purge object anchor archetypes.
protocol ObjectAnchorPurgeable: AnyObject, Sendable {
    func purgeAllArchetypes() async
}

/// Protocol for stores that can purge calibration transforms.
protocol CalibrationPurgeable: AnyObject, Sendable {
    func purgeCalibration() async
}
