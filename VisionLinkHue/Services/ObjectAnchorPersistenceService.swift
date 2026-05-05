import Foundation
import ARKit
import RealityKit
import os

/// Represents an archetypal fixture that ARKit can recognize and anchor
/// using Object Anchor tracking. Each archetype corresponds to a known
/// fixture type with characteristic geometric properties.
struct FixtureArchetype: Identifiable, Sendable, Codable {
    /// Unique identifier for this archetype instance.
    let id: UUID
    
    /// The fixture type this archetype represents.
    let fixtureType: FixtureType
    
    /// The object anchor's name as registered with ARKit.
    let objectAnchorName: String
    
    /// 3D position of the fixture in world space.
    let position: SIMD3<Float>
    
    /// Orientation quaternion of the fixture.
    let orientation: simd_quatf
    
    /// Detection confidence when the anchor was created.
    let confidence: Float
    
    /// Timestamp when this archetype was persisted.
    let createdAt: Date
    
    /// Whether this archetype has been successfully matched during relocalization.
    var isMatched: Bool = false
    
    /// The matched object anchor ID after relocalization.
    var matchedAnchorID: String?
    
    /// Create a new fixture archetype from detection data.
    init(
        fixtureType: FixtureType,
        objectAnchorName: String,
        position: SIMD3<Float>,
        orientation: simd_quatf,
        confidence: Float
    ) {
        self.id = UUID()
        self.fixtureType = fixtureType
        self.objectAnchorName = objectAnchorName
        self.position = position
        self.orientation = orientation
        self.confidence = confidence
        self.createdAt = Date()
    }
    
    private enum CodingKeys: String, CodingKey {
        case id, fixtureType, objectAnchorName
        case positionX, positionY, positionZ
        case orientationX, orientationY, orientationZ, orientationW
        case confidence, createdAt
        case isMatched, matchedAnchorID
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(fixtureType, forKey: .fixtureType)
        try container.encode(objectAnchorName, forKey: .objectAnchorName)
        try container.encode(position.x, forKey: .positionX)
        try container.encode(position.y, forKey: .positionY)
        try container.encode(position.z, forKey: .positionZ)
        try container.encode(orientation.vector.x, forKey: .orientationX)
        try container.encode(orientation.vector.y, forKey: .orientationY)
        try container.encode(orientation.vector.z, forKey: .orientationZ)
        try container.encode(orientation.real, forKey: .orientationW)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(isMatched, forKey: .isMatched)
        try container.encode(matchedAnchorID, forKey: .matchedAnchorID)
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        fixtureType = try container.decode(FixtureType.self, forKey: .fixtureType)
        objectAnchorName = try container.decode(String.self, forKey: .objectAnchorName)
        position = SIMD3<Float>(
            try container.decode(Float.self, forKey: .positionX),
            try container.decode(Float.self, forKey: .positionY),
            try container.decode(Float.self, forKey: .positionZ)
        )
        let oX = try container.decode(Float.self, forKey: .orientationX)
        let oY = try container.decode(Float.self, forKey: .orientationY)
        let oZ = try container.decode(Float.self, forKey: .orientationZ)
        let oW = try container.decode(Float.self, forKey: .orientationW)
        orientation = simd_quatf(real: oW, imag: SIMD3<Float>(oX, oY, oZ))
        confidence = try container.decode(Float.self, forKey: .confidence)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isMatched = try container.decode(Bool.self, forKey: .isMatched)
        matchedAnchorID = try container.decodeIfPresent(String.self, forKey: .matchedAnchorID)
    }
}

/// Service that manages ARKit Object Anchor persistence for fixture
/// archetypes. Provides faster relocalization than generic world-mapping
/// by recognizing specific fixture types (Chandelier, Sconce, Desk Lamp, etc.)
/// using ARKit's Object Anchor Provider.
///
/// As of iOS 26, ARKit can recognize and track common object categories
/// using Neural Surface Synthesis features. This service persists recognized
/// fixture archetypes and attempts to re-anchor them on subsequent sessions.
///
/// Extended Relocalization mode (configurable via `DetectionSettings`) enables
/// object anchor registration for all fixture types, including generic recessed
/// lights and ceiling lights, for improved tracking in feature-sparse environments.
@MainActor
@Observable
final class ObjectAnchorPersistenceService {
    
    /// Persisted fixture archetypes available for relocalization.
    var archetypes: [FixtureArchetype] = []
    
    /// Whether any object anchors are currently active in the scene.
    var hasActiveAnchors: Bool {
        !archetypes.isEmpty
    }
    
    /// Whether object anchor relocalization has succeeded.
    var isRelocalized: Bool = false
    
    /// The matched archetype after successful relocalization.
    var matchedArchetype: FixtureArchetype?
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "ObjectAnchorPersistence"
    )
    
    /// User-configurable detection settings controlling battery/performance trade-offs.
    private let detectionSettings: DetectionSettings
    
    /// The file URL where object anchors are persisted.
    private var archetypesURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("fixture_archetypes.json")
    }
    
    /// Initialize the service by loading any persisted archetypes.
    /// - Parameter detectionSettings: User-configurable detection settings for battery/performance trade-offs.
    init(detectionSettings: DetectionSettings = DetectionSettings()) {
        self.detectionSettings = detectionSettings
        loadPersistedArchetypes()
    }
    
    // MARK: - Archetype Management
    
    /// Register a detected fixture as a persistable object archetype.
    /// Only archetypal fixture types (Chandelier, Sconce, Desk Lamp) are
    /// registered with ARKit's Object Anchor system for faster relocalization.
    ///
    /// - Parameters:
    ///   - fixtureType: The type of fixture detected.
    ///   - objectAnchorName: The ARKit object anchor name.
    ///   - position: 3D position in world space.
    ///   - orientation: Orientation quaternion.
    ///   - confidence: Detection confidence score.
    func registerArchetype(
        fixtureType: FixtureType,
        objectAnchorName: String,
        position: SIMD3<Float>,
        orientation: simd_quatf,
        confidence: Float
    ) {
        // Only register archetypal fixtures that benefit from object tracking.
        guard isArchetypal(fixtureType) else {
            logger.debug("Skipping non-archetypal fixture type: \(fixtureType.rawValue)")
            return
        }
        
        let archetype = FixtureArchetype(
            fixtureType: fixtureType,
            objectAnchorName: objectAnchorName,
            position: position,
            orientation: orientation,
            confidence: confidence
        )
        
        archetypes.append(archetype)
        savePersistedArchetypes()
        logger.info("Registered archetype: \(fixtureType.rawValue) at \(String(format: "%.2f,%.2f,%.2f", position.x, position.y, position.z))")
    }
    
    /// Register multiple archetypes from detected fixtures.
    func registerArchetypes(from detections: [(type: FixtureType, name: String, position: SIMD3<Float>, orientation: simd_quatf, confidence: Float)]) {
        for detection in detections {
            registerArchetype(
                fixtureType: detection.type,
                objectAnchorName: detection.name,
                position: detection.position,
                orientation: detection.orientation,
                confidence: Float(detection.confidence)
            )
        }
    }
    
    /// Remove an archetype by its ID.
    func removeArchetype(for id: UUID) {
        archetypes.removeAll { $0.id == id }
        savePersistedArchetypes()
        logger.debug("Removed archetype \(id)")
    }
    
    /// Clear all persisted archetypes.
    func clearAllArchetypes() {
        archetypes.removeAll()
        isRelocalized = false
        matchedArchetype = nil
        savePersistedArchetypes()
        logger.info("Cleared all fixture archetypes")
    }
    
    // MARK: - Relocalization
    
    /// Attempt to match persisted archetypes against ARKit's object tracking.
    /// This is called when ARKit reports new object anchors during session run.
    ///
    /// - Parameter objectAnchorIDs: The IDs of anchors reported by ARKit.
    func matchObjectAnchors(to objectAnchorIDs: [String]) {
        #if targetEnvironment(simulator)
        return
        #endif
        
        for i in self.archetypes.indices {
            // Skip already matched archetypes.
            guard !self.archetypes[i].isMatched else { continue }
            
            // Check if ARKit found an anchor with this name.
            if objectAnchorIDs.contains(self.archetypes[i].objectAnchorName) {
                self.archetypes[i].isMatched = true
                matchedArchetype = self.archetypes[i]
                isRelocalized = true
                logger.info("Matched archetype: \(self.archetypes[i].fixtureType.rawValue) via object anchor")
                return
            }
        }
    }
    
    /// Update a matched archetype's anchor ID from ARKit.
    func updateMatchedAnchorID(for archetypeID: UUID, anchorID: String) {
        for i in archetypes.indices {
            if archetypes[i].id == archetypeID {
                archetypes[i].matchedAnchorID = anchorID
                break
            }
        }
    }
    
    /// Check if a specific archetype type is archetypal (benefits from object tracking).
    /// Archetypal fixtures have characteristic geometric signatures that ARKit
    /// can recognize consistently across sessions.
    ///
    /// When Extended Relocalization mode is enabled, all fixture types including
    /// generic recessed lights and ceiling lights are registered as object anchors
    /// to provide better tracking in feature-sparse environments.
    private func isArchetypal(_ type: FixtureType) -> Bool {
        if detectionSettings.extendedRelocalizationMode {
            switch type {
            case .chandelier, .sconce, .deskLamp, .pendant, .recessed, .ceiling, .strip:
                return true
            case .lamp:
                return false
            }
        }
        
        switch type {
        case .chandelier, .sconce, .deskLamp, .pendant:
            return true
        case .lamp, .recessed, .ceiling, .strip:
            return false
        }
    }
    
    // MARK: - Persistence
    
    /// Load persisted archetypes from disk.
    private func loadPersistedArchetypes() {
        guard FileManager.default.fileExists(atPath: archetypesURL.path) else {
            return
        }
        
        do {
            let data = try Data(contentsOf: archetypesURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            archetypes = try decoder.decode([FixtureArchetype].self, from: data)
            logger.info("Loaded \(self.archetypes.count) persisted fixture archetype(s)")
        } catch {
            logger.error("Failed to load fixture archetypes: \(error.localizedDescription)")
        }
    }
    
    /// Save all archetypes to disk as JSON.
    private func savePersistedArchetypes() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(archetypes)
            try data.write(to: archetypesURL)
            logger.debug("Saved \(self.archetypes.count) fixture archetype(s)")
        } catch {
            logger.error("Failed to save fixture archetypes: \(error.localizedDescription)")
        }
    }
    
    /// Get archetypes grouped by fixture type for display in the UI.
    func archetypesByType() -> [FixtureType: [FixtureArchetype]] {
        var grouped: [FixtureType: [FixtureArchetype]] = [:]
        for archetype in archetypes {
            grouped[archetype.fixtureType, default: []].append(archetype)
        }
        return grouped
    }
    
    /// Get the number of unmatched archetypes available for relocalization.
    var unmatchedCount: Int {
        archetypes.filter { !$0.isMatched }.count
    }
}
