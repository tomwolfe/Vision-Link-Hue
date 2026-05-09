import XCTest
@testable import VisionLinkHue

/// Unit tests for ECDSASignatureValidator, focusing on schema version
/// validation and version rollback attack prevention.
final class ECDSASignatureValidatorTests: XCTestCase {
    
    // MARK: - Schema Version Extraction Tests
    
    func testExtractSchemaVersionFromValidPayload() {
        let payload = """
        {
            "version": "1.2.0",
            "description": "test config"
        }
        """.data(using: .utf8)!
        
        let version = ECDSASignatureValidator.extractSchemaVersion(from: payload)
        XCTAssertEqual(version, "1.2.0")
    }
    
    func testExtractSchemaVersionFromMissingVersion() {
        let payload = """
        {
            "description": "test config without version"
        }
        """.data(using: .utf8)!
        
        let version = ECDSASignatureValidator.extractSchemaVersion(from: payload)
        XCTAssertNil(version)
    }
    
    func testExtractSchemaVersionFromInvalidJSON() {
        let payload = "not valid json".data(using: .utf8)!
        
        let version = ECDSASignatureValidator.extractSchemaVersion(from: payload)
        XCTAssertNil(version)
    }
    
    // MARK: - Schema Version Parsing Tests
    
    func testParseValidVersion() {
        let result = ECDSASignatureValidator.parseVersion("1.2.3")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.major, 1)
        XCTAssertEqual(result?.minor, 2)
        XCTAssertEqual(result?.patch, 3)
    }
    
    func testParseVersionWithTwoComponents() {
        let result = ECDSASignatureValidator.parseVersion("1.2")
        XCTAssertNil(result)
    }
    
    func testParseVersionWithNonNumericComponents() {
        let result = ECDSASignatureValidator.parseVersion("1.x.3")
        XCTAssertNil(result)
    }
    
    func testParseVersionWithEmptyString() {
        let result = ECDSASignatureValidator.parseVersion("")
        XCTAssertNil(result)
    }
    
    // MARK: - Schema Version Verification Tests
    
    func testSchemaVersionMeetsMinimum() throws {
        let payload = """
        {
            "version": "1.2.0",
            "description": "test config"
        }
        """.data(using: .utf8)!
        
        XCTAssertNoThrow(try ECDSASignatureValidator.verifySchemaVersion(payload: payload))
    }
    
    func testSchemaVersionBelowMinimumThrows() throws {
        let payload = """
        {
            "version": "1.0.0",
            "description": "old config"
        }
        """.data(using: .utf8)!
        
        do {
            _ = try ECDSASignatureValidator.verifySchemaVersion(payload: payload)
            XCTFail("Should have thrown an error")
        } catch {
            // Verify it's the expected error type
            let signatureError = error as? ECDSASignatureValidator.SignatureError
            switch signatureError {
            case .schemaVersionTooLow(let current, let minimum)?:
                XCTAssertEqual(current, "1.0.0")
                XCTAssertEqual(minimum, "1.2.0")
            default:
                XCTFail("Expected schemaVersionTooLow error")
            }
        }
    }
    
    func testMissingSchemaVersionThrows() throws {
        let payload = """
        {
            "description": "config without version"
        }
        """.data(using: .utf8)!
        
        do {
            _ = try ECDSASignatureValidator.verifySchemaVersion(payload: payload)
            XCTFail("Should have thrown an error")
        } catch {
            let signatureError = error as? ECDSASignatureValidator.SignatureError
            switch signatureError {
            case .schemaVersionMissing?:
                break
            default:
                XCTFail("Expected schemaVersionMissing error")
            }
        }
    }
    
    func testExactMinimumVersionPasses() throws {
        let payload = """
        {
            "version": "1.2.0",
            "description": "exact minimum"
        }
        """.data(using: .utf8)!
        
        XCTAssertNoThrow(try ECDSASignatureValidator.verifySchemaVersion(payload: payload))
    }
    
    func testMajorVersionAheadPasses() throws {
        let payload = """
        {
            "version": "2.0.0",
            "description": "major version ahead"
        }
        """.data(using: .utf8)!
        
        XCTAssertNoThrow(try ECDSASignatureValidator.verifySchemaVersion(payload: payload))
    }
    
    // MARK: - Combined Verification Tests
    
    func testVerifySignatureAndSchemaRequiresBoth() async {
        let payload = """
        {
            "version": "1.2.0",
            "description": "test"
        }
        """.data(using: .utf8)!
        
        do {
            _ = try await ECDSASignatureValidator.verifySignatureAndSchema(
                payload: payload,
                signature: Data()
            )
            XCTFail("Should have thrown an error")
        } catch {
            // Expected to throw
        }
    }
    
    // MARK: - Error Description Tests
    
    func testSchemaVersionTooLowErrorDescription() {
        let error = ECDSASignatureValidator.SignatureError.schemaVersionTooLow(
            current: "1.0.0",
            minimum: "1.2.0"
        )
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("1.0.0"))
        XCTAssertTrue(error.errorDescription!.contains("1.2.0"))
        XCTAssertTrue(error.errorDescription!.contains("rollback"))
    }
    
    func testSchemaVersionMissingErrorDescription() {
        let error = ECDSASignatureValidator.SignatureError.schemaVersionMissing
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("version"))
    }
}
