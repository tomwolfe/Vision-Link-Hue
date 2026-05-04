import Foundation
import ARKit
import RealityKit
import os

/// Represents an archetypal fixture that ARKit can recognize and anchor
/// using Object Anchor tracking. Each archetype corresponds to a known
/// fixture type with characteristic geometric properties.
struct FixtureArchetype: Identifiable, Codable, Sendable {
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
}

/// Service that manages ARKit Object Anchor persistence for fixture
/// archetypes. Provides faster relocalization than generic world-mapping
/// by recognizing specific fixture types (Chandelier, Sconce, Desk Lamp, etc.)
/// using ARKit's Object Anchor Provider.
///
/// As of iOS 26, ARKit can recognize and track common object categories
/// using Neural Surface Synthesis features. This service persists recognized
/// fixture archetypes and attempts to re-anchor them on subsequent sessions.
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
    
    /// The file URL where object anchors are persisted.
    private var archetypesURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("fixture_archetypes.json")
    }
    
    /// Initialize the service by loading any persisted archetypes.
    init() {
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
        
        for archetype in archetypes {
            // Skip already matched archetypes.
            guard !archetype.isMatched else { continue }
            
            // Check if ARKit found an anchor with this name.
            if objectAnchorIDs.contains(archetype.objectAnchorName) {
                archetype.isMatched = true
                matchedArchetype = archetype
                isRelocalized = true
                logger.info("Matched archetype: \(archetype.fixtureType.rawValue) via object anchor")
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
    private func isArchetypal(_ type: FixtureType) -> Bool {
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
            logger.info("Loaded \(archetypes.count) persisted fixture archetype(s)")
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
            logger.debug("Saved \(archetypes.count) fixture archetype(s)")
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
