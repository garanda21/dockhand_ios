import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

public struct BearerAuthMiddleware: ClientMiddleware {
    public let bearerToken: String

    public init(bearerToken: String) {
        self.bearerToken = bearerToken
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.authorization] = "Bearer \(bearerToken)"
        return try await next(request, body, baseURL)
    }
}

public enum DockhandAPIClientFactory {
    public static func makeClient(
        baseURL: URL,
        token: String?,
        customHeaders: [DockhandCustomHeader] = []
    ) -> Client {
        let normalizedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let transport = URLSessionTransport(
            configuration: URLSessionTransport.Configuration(session: DockhandHTTPSession.api)
        )

        let trimmedPath = baseURL.path.hasSuffix("/") ? String(baseURL.path.dropLast()) : baseURL.path
        let normalizedBaseURL = URL(
            string: trimmedPath.isEmpty ? baseURL.absoluteString : baseURL.deletingLastPathComponent().appending(path: trimmedPath).absoluteString
        ) ?? baseURL

        // Challenge detection runs closest to the transport so it sees the raw
        // proxy response before any other middleware.
        var middlewares: [any ClientMiddleware] = []
        if let normalizedToken, !normalizedToken.isEmpty {
            middlewares.append(BearerAuthMiddleware(bearerToken: normalizedToken))
        }
        if !customHeaders.isEmpty {
            middlewares.append(CustomHeadersMiddleware(headers: customHeaders))
        }
        middlewares.append(ProxyChallengeMiddleware())

        return Client(
            serverURL: normalizedBaseURL,
            transport: transport,
            middlewares: middlewares
        )
    }
}
