import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import DockhandAPI

@Suite("Custom header validation")
struct CustomHeaderValidationTests {
    @Test(arguments: ["P-Access-Token-Id", "CF-Access-Client-Secret", "X-Api-Key", "x_custom.header~1"])
    func acceptsTokenNames(_ name: String) {
        #expect(DockhandCustomHeaderValidator.nameIssue(name) == nil)
    }

    @Test(arguments: ["X Header", "X-Header:", "Ñame", "X-(bad)", "X\r\nInjected"])
    func rejectsNonTokenNames(_ name: String) {
        #expect(DockhandCustomHeaderValidator.nameIssue(name) == .invalidNameCharacters)
    }

    @Test(arguments: [
        "Authorization", "host", "Content-Length", "Transfer-Encoding", "Upgrade",
        "Connection", "Accept", "Sec-WebSocket-Key", "Proxy-Authorization", "PROXY-Connection"
    ])
    func rejectsReservedNames(_ name: String) {
        #expect(DockhandCustomHeaderValidator.nameIssue(name) == .reservedName)
    }

    @Test func rejectsEmptyAndOversizedNames() {
        #expect(DockhandCustomHeaderValidator.nameIssue("   ") == .emptyName)
        #expect(DockhandCustomHeaderValidator.nameIssue(String(repeating: "a", count: 129)) == .nameTooLong)
    }

    @Test(arguments: ["value\r\nX-Injected: 1", "line\nbreak", "nul\u{0}", "del\u{7F}", "emoji 🔑"])
    func rejectsUnsafeValues(_ value: String) {
        #expect(DockhandCustomHeaderValidator.valueIssue(value) == .invalidValueCharacters)
    }

    @Test func acceptsTypicalCredentialValues() {
        #expect(DockhandCustomHeaderValidator.valueIssue("a1b2c3.d4e5-f6_g7~h8/i9+j0=") == nil)
        #expect(DockhandCustomHeaderValidator.valueIssue("with\ttab and spaces") == nil)
    }

    @Test func rejectsEmptyAndOversizedValues() {
        #expect(DockhandCustomHeaderValidator.valueIssue(" \n") == .emptyValue)
        #expect(DockhandCustomHeaderValidator.valueIssue(String(repeating: "a", count: 8193)) == .valueTooLong)
    }

    @Test func flagsDuplicateNamesCaseInsensitively() {
        let first = DockhandCustomHeader(name: "X-Token", value: "one")
        let second = DockhandCustomHeader(name: "x-token", value: "two")
        let issues = DockhandCustomHeaderValidator.issues(for: [first, second])
        #expect(issues[first.id] == nil)
        #expect(issues[second.id] == .duplicateName)
    }

    @Test func sanitizedDropsInvalidAndTrims() {
        let valid = DockhandCustomHeader(name: " X-Token ", value: " secret\n")
        let invalid = DockhandCustomHeader(name: "Authorization", value: "Bearer other")
        let injected = DockhandCustomHeader(name: "X-Evil", value: "a\r\nHost: evil")
        let result = DockhandCustomHeaderValidator.sanitized([valid, invalid, injected])
        #expect(result == [DockhandCustomHeader(id: valid.id, name: "X-Token", value: "secret")])
    }

    @Test func descriptionRedactsValue() {
        let header = DockhandCustomHeader(name: "CF-Access-Client-Secret", value: "super-secret")
        #expect(!String(describing: header).contains("super-secret"))
        #expect(!String(reflecting: header).contains("super-secret"))
        #expect(!"\([header])".contains("super-secret"))
    }

    @Test func presetsProduceValidNames() {
        for preset in DockhandCustomHeaderPreset.allCases {
            let headers = preset.makeHeaders()
            #expect(!headers.isEmpty)
            for header in headers {
                #expect(DockhandCustomHeaderValidator.nameIssue(header.name) == nil)
                #expect(header.value.isEmpty)
            }
        }
        #expect(DockhandCustomHeaderPreset.pangolin.headerNames == ["P-Access-Token-Id", "P-Access-Token"])
        #expect(DockhandCustomHeaderPreset.cloudflareAccess.headerNames == ["CF-Access-Client-Id", "CF-Access-Client-Secret"])
    }
}

@Suite("Custom header application")
struct CustomHeaderApplicationTests {
    @Test func urlRequestGetsHeadersWithoutOverridingExisting() {
        var request = URLRequest(url: URL(string: "https://dockhand.example.com/api/health")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer dh_token", forHTTPHeaderField: "Authorization")
        request.applyDockhandCustomHeaders([
            DockhandCustomHeader(name: "P-Access-Token-Id", value: "id"),
            DockhandCustomHeader(name: "P-Access-Token", value: "secret"),
            DockhandCustomHeader(name: "Authorization", value: "Bearer hijack")
        ])

        #expect(request.value(forHTTPHeaderField: "P-Access-Token-Id") == "id")
        #expect(request.value(forHTTPHeaderField: "P-Access-Token") == "secret")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer dh_token")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test func middlewareAddsHeadersAndKeepsBearer() async throws {
        let bearer = BearerAuthMiddleware(bearerToken: "dh_token")
        let custom = CustomHeadersMiddleware(headers: [
            DockhandCustomHeader(name: "CF-Access-Client-Id", value: "client.access"),
            DockhandCustomHeader(name: "CF-Access-Client-Secret", value: "secret"),
            DockhandCustomHeader(name: "Authorization", value: "Bearer hijack")
        ])
        let captured = RequestRecorder()
        let transport: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?) = { request, _, _ in
            await captured.record(request)
            return (HTTPResponse(status: .ok), nil)
        }

        let request = HTTPRequest(method: .get, scheme: "https", authority: "dockhand.example.com", path: "/api/health")
        let baseURL = URL(string: "https://dockhand.example.com")!
        _ = try await bearer.intercept(request, body: nil, baseURL: baseURL, operationID: "getHealth") { request, body, url in
            try await custom.intercept(request, body: body, baseURL: url, operationID: "getHealth", next: transport)
        }

        let sent = try #require(await captured.request)
        #expect(sent.headerFields[.authorization] == "Bearer dh_token")
        #expect(sent.headerFields[HTTPField.Name("CF-Access-Client-Id")!] == "client.access")
        #expect(sent.headerFields[HTTPField.Name("CF-Access-Client-Secret")!] == "secret")
    }
}

@Suite("Proxy challenge detection")
struct ProxyChallengeTests {
    @Test func redirectToSignInIsChallenge() {
        let challenge = DockhandProxyChallenge.detect(
            statusCode: 302,
            contentType: nil,
            location: "https://team.cloudflareaccess.com/cdn-cgi/access/login"
        )
        #expect(challenge == .redirect(statusCode: 302, host: "team.cloudflareaccess.com"))
    }

    @Test func htmlPageIsChallenge() {
        #expect(DockhandProxyChallenge.detect(statusCode: 200, contentType: "text/html; charset=utf-8", location: nil) == .webPage(statusCode: 200))
        #expect(DockhandProxyChallenge.detect(statusCode: 403, contentType: "TEXT/HTML", location: nil) == .webPage(statusCode: 403))
    }

    @Test func cloudflareAccessJSONDenialIsChallenge() {
        let headers = ["cf-access-domain": "dockhand.example.com", "content-type": "application/json; charset=utf-8"]
        let challenge = DockhandProxyChallenge.detect(
            statusCode: 403,
            contentType: headers["content-type"],
            location: nil,
            headerValue: { headers[$0.lowercased()] }
        )
        #expect(challenge == .accessDenied(statusCode: 403))
    }

    @Test func dockhandForbiddenWithoutProxyHeadersIsNotChallenge() {
        let headers = ["content-type": "application/json"]
        let challenge = DockhandProxyChallenge.detect(
            statusCode: 403,
            contentType: headers["content-type"],
            location: nil,
            headerValue: { headers[$0.lowercased()] }
        )
        #expect(challenge == nil)
    }

    @Test func proxyAuthRequiredIsChallenge() {
        #expect(DockhandProxyChallenge.detect(statusCode: 407, contentType: nil, location: nil) == .proxyAuthenticationRequired)
    }

    @Test func dockhandJSONErrorsAreNotChallenges() {
        #expect(DockhandProxyChallenge.detect(statusCode: 401, contentType: "application/json", location: nil) == nil)
        #expect(DockhandProxyChallenge.detect(statusCode: 200, contentType: "application/json", location: nil) == nil)
        #expect(DockhandProxyChallenge.detect(statusCode: 200, contentType: "text/event-stream", location: nil) == nil)
    }

    @Test func challengeIsFoundInsideClientError() {
        let clientError = ClientError(
            operationID: "getHealth",
            operationInput: (),
            causeDescription: "Middleware threw an error.",
            underlyingError: DockhandProxyChallengeError.webPage(statusCode: 200)
        )
        #expect(DockhandProxyChallenge.challenge(in: clientError) == .webPage(statusCode: 200))
        #expect(DockhandProxyChallenge.challenge(in: URLError(.timedOut)) == nil)
    }

    @Test func middlewareThrowsOnChallenge() async {
        let middleware = ProxyChallengeMiddleware()
        let request = HTTPRequest(method: .get, scheme: "https", authority: "dockhand.example.com", path: "/api/health")
        await #expect(throws: DockhandProxyChallengeError.self) {
            _ = try await middleware.intercept(
                request,
                body: nil,
                baseURL: URL(string: "https://dockhand.example.com")!,
                operationID: "getHealth"
            ) { _, _, _ in
                var response = HTTPResponse(status: .found)
                response.headerFields[.location] = "https://pangolin.example.com/auth/resource/1"
                return (response, nil)
            }
        }
    }
}

@Suite("Redirect policy")
struct RedirectPolicyTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test func allowsSameOrigin() {
        #expect(DockhandRedirectPolicy.allows(from: url("https://dockhand.example.com/api/a"), to: url("https://dockhand.example.com/api/b")))
        #expect(DockhandRedirectPolicy.allows(from: url("https://Dockhand.example.com/"), to: url("https://dockhand.example.com:443/x")))
    }

    @Test func blocksCrossOriginAndDowngrade() {
        #expect(!DockhandRedirectPolicy.allows(from: url("https://dockhand.example.com/api"), to: url("https://auth.example.com/login")))
        #expect(!DockhandRedirectPolicy.allows(from: url("https://dockhand.example.com/api"), to: url("http://dockhand.example.com/api")))
        #expect(!DockhandRedirectPolicy.allows(from: url("https://dockhand.example.com/api"), to: url("https://dockhand.example.com:8443/api")))
        #expect(!DockhandRedirectPolicy.allows(from: nil, to: url("https://dockhand.example.com/api")))
    }
}

private actor RequestRecorder {
    private(set) var request: HTTPRequest?

    func record(_ request: HTTPRequest) {
        self.request = request
    }
}
