import XCTest
@testable import DockhandMobile

final class DockhandMobileTests: XCTestCase {
    func testByteFormattingUsesBinaryUnits() {
        XCTAssertTrue(1_048_576.dockhandByteCount.contains("MB"))
    }

    func testComposeValidationAcceptsValidYAML() throws {
        XCTAssertNoThrow(try StackEditorValidator.validateCompose("""
        services:
          wakebot:
            image: dgongut/wakebot:latest
            restart: always
        """))
    }

    func testComposeValidationRejectsBrokenYAML() {
        XCTAssertThrowsError(try StackEditorValidator.validateCompose("""
        services:
          wakebot:
            image: dgongut/wakebot:latest
           restart: always
        """))
    }

    func testEnvValidationRejectsBrokenKey() {
        XCTAssertThrowsError(try StackEditorValidator.validateEnv("""
        GOOD_KEY=value
        BAD-KEY=value
        """))
    }
}
