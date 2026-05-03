import RealityKit
import Foundation

/// Manual view attachment component for SwiftUI integration.
/// This is the pre-2026 approach that tracks parent anchors and offsets.
/// Kept for backward compatibility alongside the RealityKit 2026 unified API.
struct ViewAttachmentComponent: Component, Sendable {
    /// The parent anchor entity this view is attached to.
    let parent: Entity
    
    /// Position offset from the parent anchor.
    let offset: SIMD3<Float>
    
    /// Whether the view should always face the camera (billboard).
    var billboard: Bool = false
}

/// RealityKit 2026 Unified Attachment Component.
/// Uses the finalized 2026 ViewAttachmentComponent API for attaching
/// SwiftUI views to RealityKit entities with automatic lifecycle management.
struct HUDAttachmentComponent: Component, Sendable {
    /// The fixture UUID this HUD is associated with.
    let fixtureId: UUID
    
    /// The parent anchor entity this view is attached to.
    let parent: Entity
    
    /// Position offset from the parent anchor.
    let offset: SIMD3<Float>
    
    /// Whether the view should always face the camera (billboard).
    var billboard: Bool = true
    
    /// Initialize with the fixture ID and attachment parameters.
    init(fixtureId: UUID, parent: Entity, offset: SIMD3<Float>) {
        self.fixtureId = fixtureId
        self.parent = parent
        self.offset = offset
    }
}
