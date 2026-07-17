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

    func testNetworkDecodingKeepsConnectedContainers() {
        let networks = DockhandService.decodeNetworks([
            [
                "id": "network-1",
                "name": "frontend",
                "driver": "bridge",
                "scope": "local",
                "internal": false,
                "ipam": ["config": [["subnet": "172.20.0.0/16"]]],
                "containers": [
                    "container-1": ["name": "web", "ipv4Address": "172.20.0.2"]
                ]
            ]
        ])

        XCTAssertEqual(networks.first?.name, "frontend")
        XCTAssertEqual(networks.first?.subnets, ["172.20.0.0/16"])
        XCTAssertEqual(networks.first?.containers.first?.containerID, "container-1")
        XCTAssertEqual(networks.first?.containers.first?.containerName, "web")
    }

    func testActivityDecodingKeepsContainerAndAction() {
        let activity = DockhandService.decodeContainerActivity([
            "events": [
                [
                    "id": 7,
                    "containerId": "container-1",
                    "containerName": "web",
                    "image": "nginx:latest",
                    "action": "restart",
                    "timestamp": "2026-07-17T10:00:00Z"
                ]
            ],
            "total": 42
        ])

        XCTAssertEqual(activity.total, 42)
        XCTAssertEqual(activity.events.first?.containerID, "container-1")
        XCTAssertEqual(activity.events.first?.action, "restart")
    }

    func testContainerListFilterMatchesHealthAndState() {
        let unhealthy = Components.Schemas.Container(
            id: "abc",
            name: "web",
            image: "nginx:latest",
            state: "running",
            status: "Up",
            created: 0,
            health: "unhealthy",
            ports: [],
            networks: .init(),
            labels: .init()
        )

        XCTAssertTrue(ContainerListFilter.state("running").matches(unhealthy))
        XCTAssertTrue(ContainerListFilter.unhealthy.matches(unhealthy))
        XCTAssertFalse(ContainerListFilter.stopped.matches(unhealthy))
        XCTAssertFalse(ContainerListFilter.state("paused").matches(unhealthy))

        var exited = unhealthy
        exited.state = "exited"
        XCTAssertTrue(ContainerListFilter.stopped.matches(exited))
    }

    func testContainerLogSSEParserDecodesConnectedAndLogEvents() throws {
        var parser = ContainerLogSSEParser()

        XCTAssertNil(try parser.consume(line: "event: connected"))
        XCTAssertNil(try parser.consume(line: "data: {\"containerId\":\"container-1\"}"))
        guard case .connected? = try parser.consume(line: "") else {
            return XCTFail("Expected a connected event")
        }

        XCTAssertNil(try parser.consume(line: "event: log"))
        XCTAssertNil(try parser.consume(line: "data: {\"text\":\"first\\nsecond\\n\"}"))
        guard case .log(let text)? = try parser.consume(line: "") else {
            return XCTFail("Expected a log event")
        }
        XCTAssertEqual(text, "first\nsecond\n")
    }

    func testContainerLogSSEParserHandlesHeartbeatErrorAndEnd() throws {
        var parser = ContainerLogSSEParser()

        XCTAssertNil(try parser.consume(line: ": keepalive"))
        XCTAssertNil(try parser.consume(line: ""))

        XCTAssertNil(try parser.consume(line: "event: error"))
        XCTAssertNil(try parser.consume(line: "data: {\"error\":\"Docker API error: 500\"}"))
        guard case .serverError(let message)? = try parser.consume(line: "") else {
            return XCTFail("Expected a server error event")
        }
        XCTAssertEqual(message, "Docker API error: 500")

        XCTAssertNil(try parser.consume(line: "event: end"))
        XCTAssertNil(try parser.consume(line: "data: {\"reason\":\"stream ended\"}"))
        guard case .ended? = try parser.consume(line: "") else {
            return XCTFail("Expected an end event")
        }
    }

    func testContainerLogFormatterOrdersMixedBatchesByTimestampDescending() {
        let logs = """
        2026-07-17T16:06:24.806084337Z timeout
        continuation for timeout
        2026-07-17T15:56:51.539909159Z cancelled
        2026-07-17T13:52:54.527709448Z older
        2026-07-17T17:43:17.961867978Z newest
        2026-07-17T17:43:17.750902313Z second newest
        """

        XCTAssertEqual(
            ContainerLogFormatter.orderedLatestFirst(from: logs),
            """
            2026-07-17T17:43:17.961867978Z newest
            2026-07-17T17:43:17.750902313Z second newest
            2026-07-17T16:06:24.806084337Z timeout
            continuation for timeout
            2026-07-17T15:56:51.539909159Z cancelled
            2026-07-17T13:52:54.527709448Z older
            """
        )
    }

    @MainActor
    func testContainerLogsStorePausesCleanlyWhenAppLeavesForeground() {
        let store = ContainerLogsStore()
        store.isLoading = true
        store.error = "A stale stream error"
        store.streamStatus = "Connecting"

        store.pauseForBackground()

        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.streamStatus, String(localized: "Paused"))
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
