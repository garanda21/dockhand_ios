import XCTest
@testable import DockhandMobile
import DockhandAPI

final class CustomHeadersTests: XCTestCase {
    private let baseURL = URL(string: "https://dockhand.example.com")!

    private let pangolinHeaders = [
        DockhandCustomHeader(name: "P-Access-Token-Id", value: "token-id"),
        DockhandCustomHeader(name: "P-Access-Token", value: "token-secret")
    ]

    func testServiceAuthorizeAddsBearerAndCustomHeaders() {
        let service = DockhandService(baseURL: baseURL, token: "dh_token", customHeaders: pangolinHeaders)
        var request = URLRequest(url: baseURL.appending(path: "/api/environments"))
        service.authorize(&request)

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer dh_token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "P-Access-Token-Id"), "token-id")
        XCTAssertEqual(request.value(forHTTPHeaderField: "P-Access-Token"), "token-secret")
    }

    func testServiceDropsInvalidHeadersBeforeSending() {
        let service = DockhandService(
            baseURL: baseURL,
            token: "dh_token",
            customHeaders: [
                DockhandCustomHeader(name: "Authorization", value: "Bearer hijack"),
                DockhandCustomHeader(name: "X-Evil", value: "a\r\nHost: evil.example.com"),
                DockhandCustomHeader(name: "X-Good", value: "ok")
            ]
        )
        var request = URLRequest(url: baseURL)
        service.authorize(&request)

        XCTAssertEqual(service.customHeaders.map(\.name), ["X-Good"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer dh_token")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Evil"))
    }

    func testShellWebSocketRequestCarriesCustomHeaders() throws {
        let service = DockhandService(baseURL: baseURL, token: "", customHeaders: pangolinHeaders)
        let request = try service.makeContainerShellRequest(
            containerID: "abc",
            environmentID: 1,
            shell: "/bin/sh",
            user: "root"
        )

        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "P-Access-Token-Id"), "token-id")
        XCTAssertEqual(request.value(forHTTPHeaderField: "P-Access-Token"), "token-secret")
    }

    func testKeychainRoundTripsAndDeletesCustomHeaders() {
        let profileID = "custom-headers-test-\(UUID().uuidString)"
        defer { KeychainStore.deleteCustomHeaders(profileID: profileID) }

        XCTAssertEqual(KeychainStore.readCustomHeaders(profileID: profileID), [])

        KeychainStore.writeCustomHeaders(pangolinHeaders, profileID: profileID)
        XCTAssertEqual(KeychainStore.readCustomHeaders(profileID: profileID), pangolinHeaders)

        let replaced = [DockhandCustomHeader(name: "CF-Access-Client-Id", value: "client")]
        KeychainStore.writeCustomHeaders(replaced, profileID: profileID)
        XCTAssertEqual(KeychainStore.readCustomHeaders(profileID: profileID), replaced)

        KeychainStore.writeCustomHeaders([], profileID: profileID)
        XCTAssertEqual(KeychainStore.readCustomHeaders(profileID: profileID), [])
    }

    func testProxyChallengeMessagesPointToCustomHeaders() {
        let redirect = DockhandConnectionStageError(
            stage: .health,
            underlying: DockhandProxyChallengeError.redirect(statusCode: 302, host: "team.cloudflareaccess.com")
        )
        let redirectMessage = redirect.dockhandUserFacingMessage
        XCTAssertTrue(redirectMessage.contains("team.cloudflareaccess.com"))
        XCTAssertTrue(redirectMessage.localizedCaseInsensitiveContains("headers"))

        let webPage = DockhandProxyChallengeError.webPage(statusCode: 200).dockhandUserFacingMessage
        XCTAssertTrue(webPage.localizedCaseInsensitiveContains("headers"))
        XCTAssertNotEqual(webPage, DockhandServiceError.unexpectedStatus(403).dockhandUserFacingMessage)
    }

    func testDraftKeepsStoredValueUntilReplaced() {
        let stored = DockhandCustomHeader(name: "P-Access-Token", value: "old-secret")
        var draft = CustomHeaderDraft(header: stored)

        XCTAssertFalse(draft.isReplacingValue)
        XCTAssertEqual(draft.header, stored)

        draft.isReplacingValue = true
        draft.newValue = "new-secret"
        XCTAssertEqual(draft.header.value, "new-secret")
        XCTAssertEqual(draft.header.id, stored.id)

        draft.isReplacingValue = false
        XCTAssertEqual(draft.header.value, "old-secret")
    }

    func testDraftsReportMatchingPresets() {
        let drafts = DockhandCustomHeaderPreset.cloudflareAccess.makeHeaders().map { CustomHeaderDraft(name: $0.name) }
        XCTAssertEqual(drafts.matchedPresets, [.cloudflareAccess])
        XCTAssertEqual(drafts.issues.values.sorted { "\($0)" < "\($1)" }, [.emptyValue, .emptyValue])
    }

    /// Live check against a proxy-protected Dockhand, for example behind
    /// Cloudflare Access. Headers use `Name=Value` pairs separated by `;`.
    func testLiveProxyHeadersWhenConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawURL = environment["DOCKHAND_PROXY_URL"],
              let proxyURL = URL(string: rawURL),
              let rawHeaders = environment["DOCKHAND_PROXY_HEADERS"], !rawHeaders.isEmpty else {
            throw XCTSkip("Set DOCKHAND_PROXY_URL and DOCKHAND_PROXY_HEADERS to run the live proxy check")
        }
        let headers = rawHeaders.split(separator: ";").compactMap { pair -> DockhandCustomHeader? in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? DockhandCustomHeader(name: parts[0], value: parts[1]) : nil
        }
        let token = environment["DOCKHAND_PROXY_TOKEN"] ?? ""

        let blocked = DockhandService(baseURL: proxyURL, token: token)
        do {
            _ = try await blocked.fetchEnvironments()
            XCTFail("Proxy let the request through without custom headers")
        } catch {
            XCTAssertNotNil(DockhandUserFacingErrorFormatter.proxyChallenge(in: error), "Unexpected error: \(error)")
        }

        // Generated OpenAPI client path (middleware) must be blocked as well.
        do {
            _ = try await blocked.fetchHealthStatus()
            XCTFail("Proxy let the OpenAPI request through without custom headers")
        } catch {
            XCTAssertNotNil(DockhandUserFacingErrorFormatter.proxyChallenge(in: error), "Unexpected error: \(error)")
        }

        let authorized = DockhandService(baseURL: proxyURL, token: token, customHeaders: headers)
        let health = try await authorized.fetchHealthStatus()
        XCTAssertFalse(health.isEmpty)
        let environments = try await authorized.fetchEnvironments()
        guard let environmentID = environments.first?.id else {
            throw XCTSkip("Proxy check passed for REST; no environment available for logs and shell")
        }

        let containers = try await authorized.fetchContainers(environmentID: environmentID)
        guard let container = containers.first(where: { $0.state == "running" }) else {
            throw XCTSkip("Proxy check passed for REST; no running container available for logs and shell")
        }

        // Server-sent log stream uses its own URLSession delegate.
        do {
            try await blocked.streamContainerLogs(containerID: container.id, environmentID: environmentID, tail: 1) { _ in }
            XCTFail("Proxy let the log stream through without custom headers")
        } catch {
            XCTAssertNotNil(DockhandUserFacingErrorFormatter.proxyChallenge(in: error), "Unexpected error: \(error)")
        }
        let connected = expectation(description: "Log stream connected through the proxy")
        connected.assertForOverFulfill = false
        let streamTask = Task {
            try await authorized.streamContainerLogs(containerID: container.id, environmentID: environmentID, tail: 1) { event in
                if case .connected = event { connected.fulfill() }
            }
        }
        await fulfillment(of: [connected], timeout: 15)
        streamTask.cancel()
        _ = await streamTask.result

        // Shell WebSocket upgrade must carry the headers too.
        let shellRequest = try authorized.makeContainerShellRequest(
            containerID: container.id,
            environmentID: environmentID,
            shell: "/bin/sh",
            user: "root"
        )
        let socket = DockhandHTTPSession.shared.webSocketTask(with: shellRequest)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        // The shell stays silent until it gets input.
        try await socket.sendInput("echo dockhand-proxy-ok\n")
        _ = try await withTimeout(seconds: 15, onTimeout: { socket.cancel() }) { try await socket.receive() }
        XCTAssertEqual((socket.response as? HTTPURLResponse)?.statusCode, 101)

        let blockedSocket = DockhandHTTPSession.shared.webSocketTask(
            with: try blocked.makeContainerShellRequest(
                containerID: container.id,
                environmentID: environmentID,
                shell: "/bin/sh",
                user: "root"
            )
        )
        blockedSocket.resume()
        defer { blockedSocket.cancel(with: .goingAway, reason: nil) }
        do {
            _ = try await withTimeout(seconds: 15, onTimeout: { blockedSocket.cancel() }) { try await blockedSocket.receive() }
            XCTFail("Proxy let the shell WebSocket through without custom headers")
        } catch {
            XCTAssertNotNil(DockhandProxyChallenge.detect(blockedSocket.response), "Unexpected response: \(String(describing: blockedSocket.response))")
        }
    }

    /// `receive()` ignores task cancellation, so the timeout also cancels the socket.
    private func withTimeout<T: Sendable>(
        seconds: Double,
        onTimeout: @escaping @Sendable () -> Void,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                onTimeout()
                throw URLError(.timedOut)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
