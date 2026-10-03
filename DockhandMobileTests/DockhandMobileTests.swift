import XCTest
@testable import DockhandMobile
import DockhandAPI

final class DockhandMobileTests: XCTestCase {
    func testDockhandVersionUsesOwnContainerRatherThanDockerVersion() throws {
        let snapshot = try DockhandService.decodeDashboardHost([
            "docker": ["version": "29.0", "apiVersion": "1.52"],
            "host": ["name": "example"],
            "runtime": ["runtimeName": "Node.js", "ownContainer": ["labels": ["version": "v1.0.50", "revision": "abc123"]]]
        ])
        XCTAssertEqual(snapshot.dockhand?.version, "v1.0.50")
        XCTAssertEqual(snapshot.dockhand?.commit, "abc123")
        XCTAssertEqual(snapshot.dockhand?.runtime, "Node.js")
        XCTAssertEqual(snapshot.docker.version, "29.0")
    }

    func testDockhandVersionIsAbsentWithoutOwnContainerAndSupportsLegacyFields() throws {
        let unknown = try DockhandService.decodeDashboardHost(["docker": ["version": "29.0"], "host": [:], "runtime": ["runtimeVersion": "24.0"]])
        XCTAssertNil(unknown.dockhand?.version)
        let legacy = try DockhandService.decodeDashboardHost(["docker": [:], "host": [:], "dockhand": ["version": "1.0.35"]])
        XCTAssertEqual(legacy.dockhand?.version, "1.0.35")
    }

    func testChangelogCompatibilityRejectsUnknownAndUnverifiedVersions() {
        for version: String? in [nil, "", "v", "latest", "1.0", "1.0.3", "1.0.4-beta.1", "-", "1..4"] {
            XCTAssertFalse(DockhandChangelogRelease.supportsChangelog(version: version), "Unexpected support: \(version ?? "nil")")
        }
        for version in ["1.0.4", "v1.0.50", "1.0.50-baseline", "1.0.50+build", "1.1.0", "2.0.0"] {
            XCTAssertTrue(DockhandChangelogRelease.supportsChangelog(version: version), version)
        }
    }

    func testChangelogDecodesTypedAndLegacyChangesAndExcludesUpcomingReleases() throws {
        let releases = try DockhandChangelogRelease.decode([
            ["version": "1.0.51", "comingSoon": true, "changes": []],
            ["version": "1.0.50", "date": "2026-09-30", "changes": [["type": "fix", "text": "Fixed issue"], "Legacy note"]]
        ])
        XCTAssertEqual(releases.map(\.version), ["1.0.50"])
        XCTAssertEqual(releases[0].changes.map(\.text), ["Fixed issue", "Legacy note"])
        XCTAssertEqual(releases[0].changes[0].type, "fix")
        XCTAssertThrowsError(try DockhandChangelogRelease.decode([["version": "1.0.50", "changes": [42]]]))
    }

    func testUnsupportedServerRejectsChangelogBeforeNetworking() async {
        let service = DockhandService(baseURL: URL(string: "https://example.invalid")!, token: "")
        do {
            _ = try await service.fetchDockhandChangelog(environmentID: 1, serverVersion: "1.0.3")
            XCTFail("Unsupported servers must not fetch the changelog")
        } catch DockhandServiceError.invalidResponse {
            // Rejected locally; networking would return a transport error.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testStartupDiscardsCorruptPersistedProfiles() throws {
        try withRestoredDefaults(keys: ["dockhand.serverProfiles", "dockhand.baseURL"]) { defaults in
            let corruptData = Data("not-json".utf8)
            defaults.set(corruptData, forKey: "dockhand.serverProfiles")
            defaults.removeObject(forKey: "dockhand.baseURL")

            _ = PreferencesStore.serverProfiles
            let repairedData = defaults.data(forKey: "dockhand.serverProfiles")
            XCTAssertNotEqual(repairedData, corruptData)
            if let repairedData {
                XCTAssertNoThrow(try JSONDecoder().decode([DockhandServerProfile].self, from: repairedData))
            }
        }
    }

    @MainActor
    func testStartupRepairsMissingSelectedProfile() throws {
        let keys = ["dockhand.serverProfiles", "dockhand.selectedProfileID"]
        try withRestoredDefaults(keys: keys) { defaults in
            let profile = DockhandServerProfile(
                id: "available-profile",
                name: "Example",
                baseURL: "https://example.com"
            )
            defaults.set(try JSONEncoder().encode([profile]), forKey: "dockhand.serverProfiles")
            defaults.set("removed-profile", forKey: "dockhand.selectedProfileID")

            let model = AppModel()

            XCTAssertEqual(model.selectedProfileID, profile.id)
            XCTAssertEqual(defaults.string(forKey: "dockhand.selectedProfileID"), profile.id)
        }
    }

    func testTokenNormalizationRemovesCopiedWhitespace() {
        XCTAssertEqual(DockhandToken.normalized("  dh_example\n"), "dh_example")
        XCTAssertEqual(DockhandToken.normalized("\tdh_example\r\n"), "dh_example")
        XCTAssertEqual(DockhandToken.normalized(nil), "")
    }

    func testServiceNormalizesTokenBeforeBuildingRequests() {
        let service = DockhandService(
            baseURL: URL(string: "https://example.com")!,
            token: "  dh_example\n"
        )

        XCTAssertEqual(service.token, "dh_example")
    }

    func testContainerLogErrorPreservesUnsupportedDriverDetail() {
        let data = Data(
            #"{"error":"Failed to get container logs","details":"configured logging driver does not support reading"}"#.utf8
        )
        let error = DockhandService.containerLogError(statusCode: 500, data: data)

        let message = error.dockhandUserFacingMessage
        XCTAssertTrue(message.localizedCaseInsensitiveContains("logging driver")
            || message.localizedCaseInsensitiveContains("driver de logs"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("does not support reading"))
    }

    func testContainerLogErrorKeepsAuthenticationStatus() {
        let error = DockhandService.containerLogError(statusCode: 403, data: Data())

        XCTAssertTrue(error.dockhandUserFacingMessage.localizedCaseInsensitiveContains("token"))
    }

    func testUpdateCheckJobDecodesProgressAndResult() throws {
        let data = Data(#"{"status":"done","lines":[{"event":"progress","data":{"checked":3,"total":5}}],"result":{"total":5,"updatesFound":2,"results":[]}}"#.utf8)

        let snapshot = try JSONDecoder().decode(ContainerUpdateCheckJobSnapshot.self, from: data)
        XCTAssertEqual(snapshot.status, "done")
        XCTAssertEqual(snapshot.lines.first?.data.checked, 3)
        XCTAssertEqual(snapshot.lines.first?.data.total, 5)
        XCTAssertEqual(snapshot.result?.updatesFound, 2)
    }

    func testBatchUpdateResponseDecodesFailures() throws {
        let data = Data(#"{"success":false,"results":[{"containerId":"abc","containerName":"web","success":false,"error":"Pull failed"}],"summary":{"total":1,"success":0,"failed":1}}"#.utf8)

        let response = try JSONDecoder().decode(ContainerBatchUpdateResponse.self, from: data)
        XCTAssertFalse(response.success)
        XCTAssertEqual(response.summary.failed, 1)
        XCTAssertEqual(response.results.first?.containerID, "abc")
        XCTAssertEqual(response.results.first?.error, "Pull failed")
    }

    func testLiveUpdateCheckWhenIntegrationServerIsConfigured() async throws {
        guard let rawURL = ProcessInfo.processInfo.environment["DOCKHAND_INTEGRATION_URL"],
              let baseURL = URL(string: rawURL) else {
            throw XCTSkip("Set DOCKHAND_INTEGRATION_URL to run the live Dockhand check")
        }
        let environmentID = Int(ProcessInfo.processInfo.environment["DOCKHAND_INTEGRATION_ENV"] ?? "") ?? 1
        let service = DockhandService(baseURL: baseURL, token: "")
        let operation = try await service.startContainerUpdateCheck(environmentID: environmentID)

        if case .completed(let result) = operation {
            XCTAssertGreaterThan(result.total, 0)
            XCTAssertGreaterThanOrEqual(result.updatesFound, 0)
            return
        }

        guard case .job(let jobID) = operation else {
            return XCTFail("Unexpected update check response")
        }

        for _ in 0..<120 {
            let snapshot = try await service.fetchContainerUpdateCheckJob(id: jobID)
            if snapshot.status != "running" {
                XCTAssertEqual(snapshot.status, "done")
                XCTAssertNotNil(snapshot.result)
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }

        XCTFail("Dockhand update check did not finish in time")
    }

    func testLiveLogStreamWhenIntegrationContainerIsConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawURL = environment["DOCKHAND_INTEGRATION_URL"],
              let baseURL = URL(string: rawURL),
              let containerID = environment["DOCKHAND_INTEGRATION_LOG_CONTAINER"],
              !containerID.isEmpty else {
            throw XCTSkip("Set the Dockhand integration URL and log container to run the live stream test")
        }
        let environmentID = Int(environment["DOCKHAND_INTEGRATION_ENV"] ?? "") ?? 1
        let service = DockhandService(baseURL: baseURL, token: "")
        let receivedLog = expectation(description: "Receive a streamed container log")
        receivedLog.assertForOverFulfill = false

        let streamTask = Task {
            try await service.streamContainerLogs(
                containerID: containerID,
                environmentID: environmentID,
                tail: 1
            ) { event in
                if case .log(let text) = event, !text.isEmpty {
                    receivedLog.fulfill()
                }
            }
        }

        await fulfillment(of: [receivedLog], timeout: 10)
        streamTask.cancel()
        _ = await streamTask.result
    }

    func testServerAddressAcceptsHTTPAndHTTPSWithPorts() {
        XCTAssertEqual(
            DockhandServerAddress.normalizedURL(from: " https://example.com:3000/ ")?.absoluteString,
            "https://example.com:3000"
        )
        XCTAssertEqual(
            DockhandServerAddress.normalizedURL(from: "http://192.0.2.10:3230")?.absoluteString,
            "http://192.0.2.10:3230"
        )
    }

    func testServerAddressRejectsUnsupportedOrAmbiguousURLs() {
        XCTAssertNil(DockhandServerAddress.normalizedURL(from: "example.com:3000"))
        XCTAssertNil(DockhandServerAddress.normalizedURL(from: "ftp://example.com"))
        XCTAssertNil(DockhandServerAddress.normalizedURL(from: "https://user@example.com"))
        XCTAssertNil(DockhandServerAddress.normalizedURL(from: "https://example.com?token=secret"))
    }

    func testConnectionErrorIdentifiesHealthFailure() {
        let error = DockhandConnectionStageError(
            stage: .health,
            underlying: URLError(.cannotConnectToHost)
        )

        let message = error.dockhandUserFacingMessage
        XCTAssertTrue(message.localizedCaseInsensitiveContains("Dockhand"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("NSURLErrorDomain"))
        XCTAssertNotEqual(message, URLError(.cannotConnectToHost).dockhandUserFacingMessage)
    }

    func testConnectionErrorIdentifiesEnvironmentFailure() {
        let error = DockhandConnectionStageError(
            stage: .environments,
            underlying: DockhandServiceError.unexpectedStatus(403)
        )

        let message = error.dockhandUserFacingMessage
        XCTAssertTrue(message.localizedCaseInsensitiveContains("token"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("Dockhand"))
        XCTAssertNotEqual(message, DockhandServiceError.unexpectedStatus(403).dockhandUserFacingMessage)
    }

    func testConnectionErrorIdentifiesSelectedEnvironmentTransportFailure() {
        struct WrappedTransportError: LocalizedError {
            var errorDescription: String? {
                #"Client encountered an error invoking the operation "listStacks": Transport threw an error. underlying error: Error Domain=NSURLErrorDomain Code=-1001"#
            }
        }

        let error = DockhandConnectionStageError(
            stage: .selectedEnvironment,
            underlying: WrappedTransportError()
        )
        let message = error.dockhandUserFacingMessage

        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("selected Docker environment")
                || message.localizedCaseInsensitiveContains("entorno Docker seleccionado")
        )
        XCTAssertTrue(message.localizedCaseInsensitiveContains("Hawser"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("listStacks"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("NSURLErrorDomain"))
    }

    func testConnectionErrorPreservesSelectedEnvironmentServerError() {
        let error = DockhandConnectionStageError(
            stage: .selectedEnvironment,
            underlying: DockhandServiceError.unexpectedStatus(500)
        )
        let message = error.dockhandUserFacingMessage

        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("selected environment")
                || message.localizedCaseInsensitiveContains("entorno seleccionado")
        )
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("server error")
                || message.localizedCaseInsensitiveContains("error del servidor")
        )
    }

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

    func testUserFacingErrorExplainsAppTransportSecurityFailure() {
        let error = NSError(
            domain: NSURLErrorDomain,
            code: URLError.appTransportSecurityRequiresSecureConnection.rawValue
        )
        let message = error.dockhandUserFacingMessage

        XCTAssertTrue(message.localizedCaseInsensitiveContains("HTTPS"))
        XCTAssertFalse(message.contains("-1022"))
    }

    func testDockhandSessionWaitsForConnectivity() {
        let configuration = URLSessionConfiguration.dockhandEphemeral

        XCTAssertTrue(configuration.waitsForConnectivity)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 120)
    }

    func testAppTransportSecurityAllowsHTTPForLiteralIPAddresses() throws {
        let transportSecurity = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
        )
        let exceptions = try XCTUnwrap(
            transportSecurity["NSExceptionDomains"] as? [String: [String: Any]]
        )

        XCTAssertEqual(
            Set(exceptions.keys),
            ["0.0.0.0/0", "::/0"]
        )
        XCTAssertTrue(exceptions.values.allSatisfy {
            $0["NSExceptionAllowsInsecureHTTPLoads"] as? Bool == true
        })
        XCTAssertNil(transportSecurity["NSAllowsArbitraryLoads"])
    }

    func testUserFacingErrorMapsAuthenticationStatus() {
        let message = DockhandServiceError.unexpectedStatus(401).dockhandUserFacingMessage

        XCTAssertTrue(message.contains("token"))
        XCTAssertFalse(message.contains("401"))
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("expired")
                || message.localizedCaseInsensitiveContains("caducado")
        )
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

    @MainActor
    private func withRestoredDefaults(
        keys: [String],
        operation: (UserDefaults) throws -> Void
    ) rethrows {
        let defaults = UserDefaults.standard
        let previousValues = keys.reduce(into: [String: Any]()) { values, key in
            values[key] = defaults.object(forKey: key)
        }
        defer {
            for key in keys {
                if let value = previousValues[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        try operation(defaults)
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

    func testContainerLogSSEDecoderHandlesLinesSplitAcrossNetworkChunks() throws {
        var decoder = ContainerLogSSEDecoder()

        XCTAssertTrue(try decoder.consume(Data("event: log\r\nda".utf8)).isEmpty)
        let events = try decoder.consume(Data("ta: {\"text\":\"live line\\n\"}\r\n\r\n".utf8))

        guard case .log(let text)? = events.first else {
            return XCTFail("Expected a decoded log event")
        }
        XCTAssertEqual(text, "live line\n")
    }

    @MainActor
    func testContainerLogsStoreBatchesAndOrdersLiveFormatting() async throws {
        let store = ContainerLogsStore()

        store.appendLiveLog("2026-08-14T10:00:00Z older")
        store.appendLiveLog("2026-08-14T10:00:01Z latest")

        XCTAssertTrue(store.document.logs.contains("latest"))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(
            String(store.formattedLogs.characters),
            "2026-08-14T10:00:01Z latest\n2026-08-14T10:00:00Z older"
        )
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
