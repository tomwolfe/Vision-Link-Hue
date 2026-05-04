import Foundation

/// User-configurable detection settings that control the behavior of
/// the on-device AI detection pipeline and object anchor persistence.
///
/// These settings allow users to trade off detection accuracy and
/// relocalization quality for battery life and storage usage.
@MainActor
@Observable
final class DetectionSettings: Sendable {
    
    /// Whether Battery Saver mode is enabled.
    /// When enabled, skips computationally expensive Neural Surface Synthesis
    /// material classification and falls back to standard mesh-based classification.
    /// This significantly reduces CPU/GPU usage at the cost of material detection.
    var batterySaverMode: Bool = false
    
    /// Whether Extended Relocalization mode is enabled.
    /// When enabled, registers all fixture types as object anchors (including
    /// generic recessed lights and ceiling lights) for improved relocalization
    /// in feature-sparse environments. This increases storage usage but provides
    /// better tracking persistence.
    var extendedRelocalizationMode: Bool = false
    
    /// Initialize with default settings.
    init() {}
}
