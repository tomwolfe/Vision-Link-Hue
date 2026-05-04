import XCTest
import @testable VisionLinkHue

/// Unit tests for DetectionSettings, validating battery saver and
/// extended relocalization mode toggles.
final class DetectionSettingsTests: XCTestCase {
    
    func testDefaultBatterySaverModeIsDisabled() {
        let settings = DetectionSettings()
        XCTAssertFalse(settings.batterySaverMode)
    }
    
    func testDefaultExtendedRelocalizationModeIsDisabled() {
        let settings = DetectionSettings()
        XCTAssertFalse(settings.extendedRelocalizationMode)
    }
    
    func testToggleBatterySaverMode() {
        let settings = DetectionSettings()
        settings.batterySaverMode = true
        XCTAssertTrue(settings.batterySaverMode)
        
        settings.batterySaverMode = false
        XCTAssertFalse(settings.batterySaverMode)
    }
    
    func testToggleExtendedRelocalizationMode() {
        let settings = DetectionSettings()
        settings.extendedRelocalizationMode = true
        XCTAssertTrue(settings.extendedRelocalizationMode)
        
        settings.extendedRelocalizationMode = false
        XCTAssertFalse(settings.extendedRelocalizationMode)
    }
    
    func testBothModesCanBeEnabledSimultaneously() {
        let settings = DetectionSettings()
        settings.batterySaverMode = true
        settings.extendedRelocalizationMode = true
        
        XCTAssertTrue(settings.batterySaverMode)
        XCTAssertTrue(settings.extendedRelocalizationMode)
    }
}
