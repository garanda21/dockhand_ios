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
    public static func makeClient(baseURL: URL, token: String?) -> Client {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]

        let session = URLSession(configuration: configuration)
        let transport = URLSessionTransport(
            configuration: URLSessionTransport.Configuration(session: session)
        )

        let trimmedPath = baseURL.path.hasSuffix("/") ? String(baseURL.path.dropLast()) : baseURL.path
        let normalizedBaseURL = URL(
            string: trimmedPath.isEmpty ? baseURL.absoluteString : baseURL.deletingLastPathComponent().appending(path: trimmedPath).absoluteString
        ) ?? baseURL

        let middlewares: [any ClientMiddleware]
        if let token, !token.isEmpty {
            middlewares = [BearerAuthMiddleware(bearerToken: token)]
        } else {
            middlewares = []
        }

        return Client(
            serverURL: normalizedBaseURL,
            transport: transport,
            middlewares: middlewares
        )
    }
}
