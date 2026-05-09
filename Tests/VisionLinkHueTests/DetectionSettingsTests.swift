import XCTest
@testable import VisionLinkHue

/// Unit tests for DetectionSettings, validating battery saver and
/// extended relocalization mode toggles.
final class DetectionSettingsTests: XCTestCase {
    
    func testDefaultBatterySaverModeIsDisabled() async {
        let settings = await DetectionSettings()
        let batterySaverMode = await settings.batterySaverMode
        XCTAssertFalse(batterySaverMode)
    }
    
    func testDefaultExtendedRelocalizationModeIsDisabled() async {
        let settings = await DetectionSettings()
        let extendedRelocalizationMode = await settings.extendedRelocalizationMode
        XCTAssertFalse(extendedRelocalizationMode)
    }
    
    func testToggleBatterySaverMode() async {
        let settings = await DetectionSettings()
        await MainActor.run {
            settings.batterySaverMode = true
        }
        let batterySaverMode = await settings.batterySaverMode
        XCTAssertTrue(batterySaverMode)
        
        await MainActor.run {
            settings.batterySaverMode = false
        }
        let batterySaverMode2 = await settings.batterySaverMode
        XCTAssertFalse(batterySaverMode2)
    }
    
    func testToggleExtendedRelocalizationMode() async {
        let settings = await DetectionSettings()
        await MainActor.run {
            settings.extendedRelocalizationMode = true
        }
        let extendedRelocalizationMode = await settings.extendedRelocalizationMode
        XCTAssertTrue(extendedRelocalizationMode)
        
        await MainActor.run {
            settings.extendedRelocalizationMode = false
        }
        let extendedRelocalizationMode2 = await settings.extendedRelocalizationMode
        XCTAssertFalse(extendedRelocalizationMode2)
    }
    
    func testBothModesCanBeEnabledSimultaneously() async {
        let settings = await DetectionSettings()
        await MainActor.run {
            settings.batterySaverMode = true
            settings.extendedRelocalizationMode = true
        }
        
        let batterySaverMode = await settings.batterySaverMode
        XCTAssertTrue(batterySaverMode)
        let extendedRelocalizationMode = await settings.extendedRelocalizationMode
        XCTAssertTrue(extendedRelocalizationMode)
    }
}
