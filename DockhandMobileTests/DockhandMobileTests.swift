import XCTest
@testable import DockhandMobile
import DockhandAPI

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

    func testPublishedPortURLUsesEnvironmentPublicIP() {
        let environment = makeEnvironment(publicIP: "10.0.0.24")

        XCTAssertEqual(environment.publishedPortURL(port: 8080)?.absoluteString, "http://10.0.0.24:8080")
    }

    func testPublishedPortURLSupportsIPv6AndTLSPorts() {
        let environment = makeEnvironment(publicIP: "[2001:db8::20]")

        XCTAssertEqual(environment.publishedPortURL(port: 8443)?.absoluteString, "https://[2001:db8::20]:8443")
    }

    func testContainerPortAccessUsesPublishedPortAndPublicIP() {
        let environment = makeEnvironment(publicIP: "192.168.1.50")
        let container = Components.Schemas.Container(
            id: "abc",
            name: "web",
            image: "nginx:latest",
            state: "running",
            status: "Up",
            created: 0,
            ports: [
                .init(ip: "0.0.0.0", privatePort: 80, publicPort: 8080, _type: "tcp")
            ],
            networks: .init(),
            labels: .init()
        )

        let accesses = container.publishedPortAccesses(in: environment)

        XCTAssertEqual(accesses.map(\.label), ["8080:80"])
        XCTAssertEqual(accesses.first?.destinationURL?.absoluteString, "http://192.168.1.50:8080")
    }

    func testPendingUpdateDecodingKeepsContainerIdentity() {
        let updates = DockhandService.decodePendingContainerUpdates([
            "pendingUpdates": [
                [
                    "containerId": "container-1",
                    "containerName": "web",
                    "currentImage": "nginx:latest",
                    "checkedAt": "2026-07-17T10:00:00Z"
                ]
            ]
        ])

        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.containerID, "container-1")
        XCTAssertEqual(updates.first?.containerName, "web")
        XCTAssertEqual(updates.first?.currentImage, "nginx:latest")
    }

    func testVolumeDecodingKeepsContainerUsage() {
        let volumes = DockhandService.decodeVolumes([
            [
                "name": "app-data",
                "driver": "local",
                "scope": "local",
                "usedBy": [
                    ["containerId": "container-1", "containerName": "web"]
                ]
            ]
        ])

        XCTAssertEqual(volumes.count, 1)
        XCTAssertEqual(volumes.first?.name, "app-data")
        XCTAssertEqual(volumes.first?.usedBy.first?.containerID, "container-1")
        XCTAssertEqual(volumes.first?.usedBy.first?.containerName, "web")
    }

    private func makeEnvironment(publicIP: String?) -> Components.Schemas.Environment {
        Components.Schemas.Environment(
            id: 1,
            name: "Lab",
            port: 2375,
            _protocol: "tcp",
            icon: "server",
            collectActivity: false,
            collectMetrics: false,
            highlightChanges: false,
            labels: [],
            connectionType: "socket",
            socketPath: "/var/run/docker.sock",
            publicIp: publicIP,
            createdAt: "2026-07-05T00:00:00Z"
        )
    }
}
