import Foundation
import HTTPTypes
import OpenAPIRuntime

/// A user-defined HTTP header sent with every request to a Dockhand server.
///
/// Values are treated as credentials: they live in the Keychain, are never
/// logged and are redacted from `description`.
public struct DockhandCustomHeader: Codable, Hashable, Identifiable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var id: UUID
    public var name: String
    public var value: String

    public init(id: UUID = UUID(), name: String, value: String) {
        self.id = id
        self.name = name
        self.value = value
    }

    public var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var normalizedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var description: String {
        "\(normalizedName): <redacted>"
    }

    public var debugDescription: String {
        description
    }
}

public enum DockhandCustomHeaderIssue: Error, Equatable, Sendable {
    case emptyName
    case invalidNameCharacters
    case nameTooLong
    case reservedName
    case duplicateName
    case emptyValue
    case invalidValueCharacters
    case valueTooLong
}

public enum DockhandCustomHeaderValidator {
    public static let maximumNameLength = 128
    public static let maximumValueLength = 8192
    public static let maximumHeaderCount = 20

    /// Headers the app or URLSession control. Overriding them would break
    /// Dockhand authentication, request framing or WebSocket upgrades.
    static let reservedNames: Set<String> = [
        "accept",
        "accept-encoding",
        "authorization",
        "connection",
        "content-encoding",
        "content-length",
        "content-type",
        "expect",
        "host",
        "keep-alive",
        "origin",
        "range",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
        "www-authenticate"
    ]

    static let reservedPrefixes = ["proxy-", "sec-"]

    private static let tokenCharacters: CharacterSet = {
        var set = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~")
        set.formUnion(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"))
        return set
    }()

    public static func isReserved(_ name: String) -> Bool {
        let lowercased = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return reservedNames.contains(lowercased) || reservedPrefixes.contains { lowercased.hasPrefix($0) }
    }

    public static func nameIssue(_ name: String) -> DockhandCustomHeaderIssue? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .emptyName }
        if trimmed.count > maximumNameLength { return .nameTooLong }
        if trimmed.unicodeScalars.contains(where: { !tokenCharacters.contains($0) }) { return .invalidNameCharacters }
        if isReserved(trimmed) { return .reservedName }
        return nil
    }

    public static func valueIssue(_ value: String) -> DockhandCustomHeaderIssue? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .emptyValue }
        if trimmed.utf8.count > maximumValueLength { return .valueTooLong }
        // RFC 9110 field-value: visible ASCII, spaces, tabs and obs-text. Rejecting
        // CR/LF/NUL and other controls prevents header injection.
        let hasInvalidScalar = trimmed.unicodeScalars.contains { scalar in
            (scalar.value < 0x20 && scalar != "\t") || scalar.value == 0x7F || scalar.value > 0xFF
        }
        return hasInvalidScalar ? .invalidValueCharacters : nil
    }

    /// Returns the first issue per header, keyed by header id.
    public static func issues(for headers: [DockhandCustomHeader]) -> [UUID: DockhandCustomHeaderIssue] {
        var result: [UUID: DockhandCustomHeaderIssue] = [:]
        var seenNames: Set<String> = []

        for header in headers {
            if let issue = nameIssue(header.name) {
                result[header.id] = issue
                continue
            }
            let lowercased = header.normalizedName.lowercased()
            if !seenNames.insert(lowercased).inserted {
                result[header.id] = .duplicateName
                continue
            }
            if let issue = valueIssue(header.value) {
                result[header.id] = issue
            }
        }

        return result
    }

    /// Headers safe to put on the wire. Invalid entries are dropped rather than
    /// sent, so a corrupted Keychain item can never inject arbitrary headers.
    public static func sanitized(_ headers: [DockhandCustomHeader]) -> [DockhandCustomHeader] {
        let issues = issues(for: headers)
        return headers
            .filter { issues[$0.id] == nil }
            .map { DockhandCustomHeader(id: $0.id, name: $0.normalizedName, value: $0.normalizedValue) }
    }
}

/// Ready-made header sets for common authenticating reverse proxies.
public enum DockhandCustomHeaderPreset: String, CaseIterable, Identifiable, Sendable {
    case pangolin
    case cloudflareAccess

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pangolin: "Pangolin"
        case .cloudflareAccess: "Cloudflare Access"
        }
    }

    public var headerNames: [String] {
        switch self {
        case .pangolin: ["P-Access-Token-Id", "P-Access-Token"]
        case .cloudflareAccess: ["CF-Access-Client-Id", "CF-Access-Client-Secret"]
        }
    }

    public func makeHeaders() -> [DockhandCustomHeader] {
        headerNames.map { DockhandCustomHeader(name: $0, value: "") }
    }
}

public extension URLRequest {
    /// Adds custom headers without replacing anything the app already set.
    mutating func applyDockhandCustomHeaders(_ headers: [DockhandCustomHeader]) {
        for header in DockhandCustomHeaderValidator.sanitized(headers)
        where value(forHTTPHeaderField: header.name) == nil {
            setValue(header.value, forHTTPHeaderField: header.name)
        }
    }
}

public struct CustomHeadersMiddleware: ClientMiddleware {
    private let headers: [DockhandCustomHeader]

    public init(headers: [DockhandCustomHeader]) {
        self.headers = DockhandCustomHeaderValidator.sanitized(headers)
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        for header in headers {
            guard let name = HTTPField.Name(header.name), request.headerFields[name] == nil else { continue }
            request.headerFields[name] = header.value
        }
        return try await next(request, body, baseURL)
    }
}

// MARK: - Reverse proxy challenge detection

/// Raised when a reverse proxy answers instead of the Dockhand API, typically
/// because custom authentication headers are missing, wrong or revoked.
public enum DockhandProxyChallengeError: Error, Equatable, Sendable {
    /// The proxy tried to redirect to a sign-in page. The redirect is not followed.
    case redirect(statusCode: Int, host: String?)
    /// HTTP 407 Proxy Authentication Required.
    case proxyAuthenticationRequired
    /// An HTML page came back where the API returns JSON.
    case webPage(statusCode: Int)
    /// A known authenticating proxy rejected the request (for example
    /// Cloudflare Access answering 403 JSON to a missing or invalid service token).
    case accessDenied(statusCode: Int)
}

public enum DockhandProxyChallenge {
    /// Response headers only a proxy adds when it denies a request. Cloudflare
    /// Access sets them on its own 401/403 pages but not on origin responses.
    static let proxyDenialHeaders = ["cf-access-domain", "cf-access-aud"]

    public static func detect(
        statusCode: Int,
        contentType: String?,
        location: String?,
        headerValue: (String) -> String? = { _ in nil }
    ) -> DockhandProxyChallengeError? {
        if (300..<400).contains(statusCode) {
            let host = location.flatMap { URL(string: $0)?.host }
            return .redirect(statusCode: statusCode, host: host)
        }
        if statusCode == 407 {
            return .proxyAuthenticationRequired
        }
        if statusCode == 401 || statusCode == 403,
           proxyDenialHeaders.contains(where: { headerValue($0) != nil }) {
            return .accessDenied(statusCode: statusCode)
        }
        if let contentType, contentType.lowercased().contains("text/html") {
            return .webPage(statusCode: statusCode)
        }
        return nil
    }

    public static func detect(_ response: URLResponse?) -> DockhandProxyChallengeError? {
        guard let response = response as? HTTPURLResponse else { return nil }
        return detect(
            statusCode: response.statusCode,
            contentType: response.value(forHTTPHeaderField: "Content-Type"),
            location: response.value(forHTTPHeaderField: "Location"),
            headerValue: { response.value(forHTTPHeaderField: $0) }
        )
    }

    /// Finds a proxy challenge anywhere in an error chain, including errors
    /// wrapped by the OpenAPI runtime.
    public static func challenge(in error: Error) -> DockhandProxyChallengeError? {
        if let challenge = error as? DockhandProxyChallengeError {
            return challenge
        }
        if let clientError = error as? ClientError {
            return challenge(in: clientError.underlyingError)
        }
        if let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error {
            return challenge(in: underlying)
        }
        return nil
    }
}

public struct ProxyChallengeMiddleware: ClientMiddleware {
    public init() {}

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)
        if let challenge = DockhandProxyChallenge.detect(
            statusCode: response.status.code,
            contentType: response.headerFields[.contentType],
            location: response.headerFields[.location],
            headerValue: { name in HTTPField.Name(name).flatMap { response.headerFields[$0] } }
        ) {
            throw challenge
        }
        return (response, responseBody)
    }
}

// MARK: - Redirect policy

public enum DockhandRedirectPolicy {
    /// Only same-origin redirects without a scheme downgrade are followed.
    /// Anything else would forward the bearer token and custom headers to a
    /// different host, such as a proxy sign-in page.
    public static func allows(from original: URL?, to destination: URL?) -> Bool {
        guard let original, let destination,
              let originalScheme = original.scheme?.lowercased(),
              let destinationScheme = destination.scheme?.lowercased(),
              let originalHost = original.host?.lowercased(),
              let destinationHost = destination.host?.lowercased() else {
            return false
        }
        return originalScheme == destinationScheme
            && originalHost == destinationHost
            && effectivePort(original) == effectivePort(destination)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https", "wss": return 443
        case "http", "ws": return 80
        default: return nil
        }
    }
}

public final class DockhandRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    override public init() {}

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let original = task.originalRequest?.url ?? response.url
        completionHandler(DockhandRedirectPolicy.allows(from: original, to: request.url) ? request : nil)
    }
}

// MARK: - Shared sessions

public enum DockhandHTTPSession {
    public static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        // Each request carries its own credentials; never let cookies from one
        // server profile leak into another that shares a host.
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return configuration
    }

    /// Session for hand-built requests and WebSockets.
    public static let shared = URLSession(
        configuration: makeConfiguration(),
        delegate: DockhandRedirectGuard(),
        delegateQueue: nil
    )

    /// Session for the generated OpenAPI client.
    static let api: URLSession = {
        let configuration = makeConfiguration()
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: configuration, delegate: DockhandRedirectGuard(), delegateQueue: nil)
    }()
}
