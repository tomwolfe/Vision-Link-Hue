import Foundation
import simd
import os

/// Represents a spatial cluster of nearby lighting fixtures.
/// Clusters reduce HUD clutter in dense environments by grouping
/// multiple fixtures within a proximity threshold into a single
/// interactive node.
struct SpatialCluster: Identifiable, Sendable {
    /// Unique identifier for the cluster.
    let id: UUID
    
    /// Center position of the cluster in world space.
    let center: SIMD3<Float>
    
    /// Radius of the cluster in meters.
    let radiusMeters: Float
    
    /// All fixtures contained within this cluster.
    let fixtures: [TrackedFixture]
    
    /// The dominant fixture type within the cluster.
    var dominantType: FixtureType {
        let counts = fixtures.reduce(into: [FixtureType: Int]()) { counts, fixture in
            counts[fixture.type, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key ?? .lamp
    }
    
    /// Average detection confidence across all cluster members.
    var averageConfidence: Double {
        guard !fixtures.isEmpty else { return 0.0 }
        return fixtures.map { $0.confidence }.reduce(0.0, +) / Double(fixtures.count)
    }
    
    /// Total number of lights in the cluster.
    var lightCount: Int { fixtures.count }
    
    /// Whether the cluster is fully on (all lights are on).
    var isFullyOn: Bool {
        fixtures.isEmpty || fixtures.allSatisfy { $0.mappedHueLightId != nil }
    }
    
    /// Human-readable label for the cluster.
    var label: String {
        switch lightCount {
        case 1: return fixtures.first?.type.displayName ?? "Fixture"
        case 2: return "2 Fixtures"
        case 3: return "3 Fixtures"
        default: return "\(lightCount) Fixtures"
        }
    }
}

/// Engine that groups nearby detected fixtures into spatial clusters.
/// Uses a simple distance-based clustering algorithm: fixtures within
/// `clusterRadiusMeters` of each other are merged into a single cluster.
///
/// Clustering reduces HUD clutter in dense lighting environments by
/// presenting a single reticle per cluster instead of one per fixture.
@MainActor
final class SpatialClusterEngine {
    
    /// Current clusters computed from the latest fixture set.
    var clusters: [SpatialCluster] = []
    
    /// Whether clustering is active and reducing the fixture count.
    var isClusteringActive: Bool {
        clusters.count > 0 && clusters.count < trackedFixtures.count
    }
    
    /// The radius in meters within which fixtures are grouped into a cluster.
    private let clusterRadiusMeters: Float
    
    /// Currently tracked fixtures.
    private var trackedFixtures: [TrackedFixture] = []
    
    /// Callback invoked when clusters change.
    var onClustersChange: (([SpatialCluster]) -> Void)?
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "SpatialCluster"
    )
    
    /// Default cluster radius in meters.
    static let defaultClusterRadius: Float = 1.5
    
    /// Initialize with a configurable cluster radius.
    /// - Parameter clusterRadiusMeters: Distance threshold for grouping fixtures.
    init(clusterRadiusMeters: Float = 1.5) {
        self.clusterRadiusMeters = clusterRadiusMeters
    }
    
    /// Configure the engine with tracked fixtures for clustering.
    /// - Parameter fixtures: Array of tracked fixtures to cluster.
    func configure(trackedFixtures: [TrackedFixture]) {
        self.trackedFixtures = trackedFixtures
        computeClusters()
    }
    
    /// Recompute clusters from the currently configured fixtures.
    func computeClusters() {
        guard !trackedFixtures.isEmpty else {
            clusters = []
            onClustersChange?(clusters)
            return
        }
        
        let newClusters = clusterFixtures(trackedFixtures)
        
        if newClusters.count != clusters.count {
            logger.info(
                "Clustered \(self.trackedFixtures.count) fixtures into \(newClusters.count) cluster(s) (radius: \(String(format: "%.1f", self.clusterRadiusMeters))m)"
            )
        }
        
        clusters = newClusters
        onClustersChange?(clusters)
    }
    
    /// Get the cluster that contains a given fixture.
    /// - Parameter fixtureId: The fixture's UUID.
    /// - Returns: The containing cluster, or nil if the fixture is unclustered.
    func clusterForFixture(_ fixtureId: UUID) -> SpatialCluster? {
        clusters.first { cluster in
            cluster.fixtures.contains { $0.id == fixtureId }
        }
    }
    
    /// Get all fixtures within a cluster, or the single fixture if not clustered.
    /// - Parameter fixtureId: The fixture's UUID.
    /// - Returns: Array of fixtures to control (single or cluster).
    func fixturesToControl(for fixtureId: UUID) -> [TrackedFixture] {
        if let cluster = clusterForFixture(fixtureId) {
            return cluster.fixtures
        }
        return trackedFixtures.filter { $0.id == fixtureId }
    }
    
    /// Get the effective center position for controlling a fixture.
    /// Returns the cluster center if clustered, otherwise the fixture position.
    /// - Parameter fixtureId: The fixture's UUID.
    /// - Returns: The world space position to use for control.
    func effectivePosition(for fixtureId: UUID) -> SIMD3<Float> {
        if let cluster = clusterForFixture(fixtureId) {
            return cluster.center
        }
        return trackedFixtures.first { $0.id == fixtureId }?.position ?? .zero
    }
    
    // MARK: - Private Clustering Logic
    
    /// Group fixtures into clusters using distance-based merging.
    private func clusterFixtures(_ fixtures: [TrackedFixture]) -> [SpatialCluster] {
        guard !fixtures.isEmpty else { return [] }
        
        var assigned = Set<UUID>()
        var result: [SpatialCluster] = []
        
        for fixture in fixtures {
            guard !assigned.contains(fixture.id) else { continue }
            
            var clusterMembers: [TrackedFixture] = [fixture]
            assigned.insert(fixture.id)
            
            // Find all unassigned fixtures within cluster radius
            var changed = true
            while changed {
                changed = false
                for other in fixtures {
                    guard !assigned.contains(other.id) else { continue }
                    
                    let distance = simd_distance(fixture.position, other.position)
                    if distance <= clusterRadiusMeters {
                        clusterMembers.append(other)
                        assigned.insert(other.id)
                        changed = true
                    }
                }
            }
            
            // Compute cluster center (mean position)
            var center = SIMD3<Float>(0, 0, 0)
            for member in clusterMembers {
                center += member.position
            }
            center /= Float(clusterMembers.count)
            
            // Compute cluster radius (max distance from center)
            var maxRadius: Float = 0
            for member in clusterMembers {
                let dist = simd_distance(center, member.position)
                if dist > maxRadius {
                    maxRadius = dist
                }
            }
            
            result.append(SpatialCluster(
                id: UUID(),
                center: center,
                radiusMeters: maxRadius,
                fixtures: clusterMembers
            ))
        }
        
        return result
    }
}
