import RealityKit
import Foundation

/// Manual view attachment component for SwiftUI integration.
/// Deprecated: Use RealityKit 26's native ViewAttachmentComponent instead.
/// The manual component is retained only for backward compatibility during
/// the migration period. All new code should use the unified ViewAttachmentComponent
/// API introduced in RealityKit 2026.
///
/// Migration: Replace manual ViewAttachmentComponent usage with the native
/// `ViewAttachmentComponent` from RealityKit, which provides automatic
/// lifecycle management and @Observable-driven SwiftUI updates.
@available(*, deprecated, renamed: "RealityKit.ViewAttachmentComponent", message: "Use RealityKit 26's native ViewAttachmentComponent for automatic SwiftUI view lifecycle management and @Observable-driven entity updates.")
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

/// RealityKit 2026 native ViewAttachmentComponent wrapper.
/// Bridges RealityViewContent to RealityKit entities for automatic
/// SwiftUI view lifecycle management driven by @Observable properties.
struct RealityViewAttachmentComponent: Component, Sendable {
    /// The RealityView content used to render the attached SwiftUI view.
    let content: RealityViewContent
    
    /// The parent anchor entity this view is attached to.
    let parent: Entity
    
    /// Position offset from the parent anchor.
    let offset: SIMD3<Float>
    
    /// Initialize with RealityView content and attachment parameters.
    init(content: RealityViewContent, parent: Entity, offset: SIMD3<Float>) {
        self.content = content
        self.parent = parent
        self.offset = offset
    }
}
