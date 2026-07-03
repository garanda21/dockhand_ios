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

    func testUserFacingErrorHidesTechnicalTimeoutDetails() {
        let error = NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue)
        let message = error.dockhandUserFacingMessage

        XCTAssertTrue(message.contains("Dockhand"))
        XCTAssertFalse(message.contains("NSURLErrorDomain"))
        XCTAssertFalse(message.contains("-1001"))
    }

    func testUserFacingErrorHandlesWrappedTransportText() {
        struct WrappedTransportError: LocalizedError {
            var errorDescription: String? {
                #"Client encountered an error invoking the operation "getHealth": Transport threw an error. underlying error: Error Domain=NSURLErrorDomain Code=-1001"#
            }
        }

        let message = WrappedTransportError().dockhandUserFacingMessage
        XCTAssertTrue(message.contains("Dockhand"))
        XCTAssertFalse(message.contains("getHealth"))
        XCTAssertFalse(message.contains("NSURLErrorDomain"))
    }

    func testUserFacingErrorMapsAuthenticationStatus() {
        let message = DockhandServiceError.unexpectedStatus(401).dockhandUserFacingMessage

        XCTAssertTrue(message.contains("token"))
        XCTAssertFalse(message.contains("401"))
    }

    func testUserFacingErrorDetectsCancellation() {
        XCTAssertTrue(CancellationError().isDockhandCancellation)
        XCTAssertTrue(URLError(.cancelled).isDockhandCancellation)
    }

    func testUserFacingErrorDetectsWrappedCancellationText() {
        struct WrappedCancellationError: LocalizedError {
            var errorDescription: String? {
                #"Client encountered an error invoking the operation "listContainers": Transport threw an error. underlying error: Error Domain=NSURLErrorDomain Code=-999 "cancelled""#
            }
        }

        XCTAssertTrue(WrappedCancellationError().isDockhandCancellation)
    }
}
