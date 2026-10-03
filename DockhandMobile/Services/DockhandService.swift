import DockhandAPI
import Foundation

struct StackEditorDocument: Sendable, Hashable {
    var composeContent: String
    var envContent: String
    var composePath: String?
    var envPath: String?
    var suggestedEnvPath: String?
    var needsFileLocation: Bool
    var noEnvFile: Bool
    var composeError: String?
}

struct ContainerLogsDocument: Sendable, Hashable {
    var logs: String
}

struct ImageScanDocument: Sendable, Hashable {
    var stage: String
    var message: String
    var progress: Int?
    var results: [String]
}

struct ImagePullProgressDetail: Decodable, Sendable, Hashable {
    let current: Int64?
    let total: Int64?
}

struct ImagePullProgressEvent: Decodable, Sendable, Hashable {
    let id: String?
    let status: String?
    let progress: String?
    let progressDetail: ImagePullProgressDetail?
    let error: String?
}

struct ImagePullJobLine: Decodable, Sendable, Hashable {
    let event: String?
    let data: ImagePullProgressEvent
}

struct ImagePullJobSnapshot: Decodable, Sendable, Hashable {
    let status: String
    let lines: [ImagePullJobLine]
    let result: ImagePullProgressEvent?
}

enum ImagePullStartResult: Sendable, Hashable {
    case job(String)
    case completed(ImagePullProgressEvent)
}

struct DashboardEnvironmentSnapshot: Codable, Sendable, Hashable {
    struct Containers: Codable, Sendable, Hashable {
        var total: Int
        var running: Int
        var stopped: Int
        var paused: Int
        var restarting: Int
        var unhealthy: Int
        var pendingUpdates: Int
    }

    struct Images: Codable, Sendable, Hashable {
        var total: Int
        var totalSize: Int
    }

    struct Volumes: Codable, Sendable, Hashable {
        var total: Int
        var totalSize: Int
    }

    struct Networks: Codable, Sendable, Hashable {
        var total: Int
    }

    struct Stacks: Codable, Sendable, Hashable {
        var total: Int
        var running: Int
        var partial: Int
        var stopped: Int
    }

    struct Metrics: Codable, Sendable, Hashable {
        var cpuPercent: Double
        var memoryPercent: Double
        var memoryUsed: Int
        var memoryTotal: Int
    }

    struct Events: Codable, Sendable, Hashable {
        var total: Int
        var today: Int
    }

    var id: Int
    var name: String
    var port: Int
    var icon: String
    var socketPath: String
    var collectActivity: Bool
    var collectMetrics: Bool
    var scannerEnabled: Bool
    var updateCheckEnabled: Bool
    var updateCheckAutoUpdate: Bool
    var connectionType: String
    var online: Bool
    var containers: Containers
    var images: Images
    var volumes: Volumes
    var containersSize: Int
    var buildCacheSize: Int
    var networks: Networks
    var stacks: Stacks
    var metrics: Metrics
    var events: Events
}

struct DashboardHostSnapshot: Codable, Sendable, Hashable {
    struct Dockhand: Codable, Sendable, Hashable {
        var version: String?
        var build: String?
        var commit: String?
        var runtime: String?
        var database: String?
    }

    struct Docker: Codable, Sendable, Hashable {
        var version: String
        var apiVersion: String
        var os: String
        var arch: String
        var kernelVersion: String
        var serverVersion: String
        var connectionType: String
        var socketPath: String?
    }

    struct Host: Codable, Sendable, Hashable {
        var name: String
        var cpus: Int
        var memory: Int
        var storageDriver: String
    }

    var dockhand: Dockhand?
    var docker: Docker
    var host: Host
}

struct DockhandChangelogRelease: Identifiable, Sendable, Equatable {
    struct Change: Sendable, Equatable {
        let type: String?
        let text: String
    }

    var id: String { version }
    let version: String
    let date: String?
    let changes: [Change]

    // /api/changelog and runtime.ownContainer.labels.version are verified in
    // official release tags from 1.0.4 through 1.0.50. Unknown builds are gated.
    static func supportsChangelog(version: String?) -> Bool {
        supports(version: version, minimumPatch: 4)
    }

    static func supportsContainerNotes(version: String?) -> Bool {
        supports(version: version, minimumPatch: 43)
    }

    private static func supports(version: String?, minimumPatch: Int) -> Bool {
        guard let version else { return false }
        let value = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let unprefixed = value.hasPrefix("v") ? String(value.dropFirst()) : value
        guard let withoutSuffix = unprefixed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first,
              let core = withoutSuffix.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first else { return false }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return false }
        if major != 1 { return major > 1 }
        if minor != 0 { return minor > 0 }
        return patch > minimumPatch || (patch == minimumPatch && !unprefixed.contains("-"))
    }

    static func decode(_ objects: [[String: Any]]) throws -> [Self] {
        try objects.filter { ($0["comingSoon"] as? Bool) != true }.map { object in
            guard let version = object["version"] as? String,
                  !version.isEmpty, let rawChanges = object["changes"] as? [Any] else {
                throw DockhandServiceError.invalidResponse
            }
            let changes: [Change] = try rawChanges.map { raw in
                if let text = raw as? String { return Change(type: nil, text: text) }
                guard let change = raw as? [String: Any], let text = change["text"] as? String else {
                    throw DockhandServiceError.invalidResponse
                }
                return Change(type: change["type"] as? String, text: text)
            }
            return Self(version: version, date: object["date"] as? String, changes: changes)
        }
    }
}

struct ContainerReleaseNotes: Decodable, Identifiable, Sendable {
    struct Note: Decodable, Sendable {
        let version: String
        let name: String?
        let body: String?
        let url: String
    }
    var id: String { changelogUrl ?? notes.first?.url ?? "notes" }
    let changelogUrl: String?
    let notes: [Note]

    static func webURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }
    var hasContent: Bool { Self.webURL(changelogUrl) != nil || !notes.isEmpty }
}

struct PendingContainerUpdate: Sendable, Hashable {
    var containerID: String
    var containerName: String
    var currentImage: String
    var checkedAt: String?
    var newerTags: [String] = []
}

struct ContainerUpdateCheckProgress: Decodable, Sendable, Hashable {
    var checked: Int?
    var total: Int?
}

struct ContainerUpdateCheckResult: Decodable, Sendable, Hashable {
    var total: Int
    var updatesFound: Int
}

enum ContainerUpdateCheckOperation: Sendable, Hashable {
    case job(String)
    case completed(ContainerUpdateCheckResult)
}

struct ContainerUpdateCheckJobLine: Decodable, Sendable, Hashable {
    var event: String?
    var data: ContainerUpdateCheckProgress
}

struct ContainerUpdateCheckJobSnapshot: Decodable, Sendable, Hashable {
    var status: String
    var lines: [ContainerUpdateCheckJobLine]
    var result: ContainerUpdateCheckResult?
}

struct ContainerBatchUpdateResult: Decodable, Sendable, Hashable {
    var containerID: String
    var containerName: String
    var success: Bool
    var error: String?

    private enum CodingKeys: String, CodingKey {
        case containerID = "containerId"
        case containerName
        case success
        case error
    }
}

struct ContainerBatchUpdateSummary: Decodable, Sendable, Hashable {
    var total: Int
    var success: Int
    var failed: Int
}

struct ContainerBatchUpdateResponse: Decodable, Sendable, Hashable {
    var success: Bool
    var results: [ContainerBatchUpdateResult]
    var summary: ContainerBatchUpdateSummary
}

struct VolumeUsageSnapshot: Sendable, Hashable {
    var containerID: String
    var containerName: String
}

struct VolumeSnapshot: Sendable, Hashable {
    var name: String
    var driver: String
    var scope: String
    var usedBy: [VolumeUsageSnapshot]
}

struct NetworkUsageSnapshot: Sendable, Hashable {
    var containerID: String
    var containerName: String
    var ipv4Address: String
}

struct NetworkSnapshot: Sendable, Hashable {
    var id: String
    var name: String
    var driver: String
    var scope: String
    var isInternal: Bool
    var subnets: [String]
    var containers: [NetworkUsageSnapshot]
}

struct ContainerEventSnapshot: Sendable, Hashable {
    var id: Int
    var containerID: String
    var containerName: String?
    var image: String?
    var action: String
    var timestamp: String
}

struct ContainerActivitySnapshot: Sendable, Hashable {
    var events: [ContainerEventSnapshot]
    var total: Int
}

struct StackDeployOptions: Sendable, Hashable {
    var pull = true
    var build = false
    var forceRecreate = false
}

struct StackRedeployProgressEvent: Decodable, Sendable, Hashable {
    let status: String?
}

struct StackRedeployJobLine: Decodable, Sendable, Hashable {
    let event: String?
    let data: StackRedeployProgressEvent
}

struct StackRedeployResult: Decodable, Sendable, Hashable {
    let success: Bool?
    let status: String?
    let output: String?
    let error: String?
}

struct StackRedeployJobSnapshot: Decodable, Sendable, Hashable {
    let status: String
    let lines: [StackRedeployJobLine]
    let result: StackRedeployResult?
}

enum StackRedeployStartResult: Sendable, Hashable {
    case job(String)
    case completed(StackRedeployResult)
}

enum DockhandServiceError: LocalizedError {
    case invalidResponse
    case logsUnavailable(String?)
    case message(String)
    case unexpectedStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return String(localized: "Invalid response from Dockhand")
        case .logsUnavailable(let reason):
            return reason
        case .message(let message):
            return message
        case .unexpectedStatus(let code):
            return String(
                format: String(localized: "Dockhand returned status %lld"),
                locale: Locale.current,
                Int64(code)
            )
        }
    }
}

struct DockhandService {
    let baseURL: URL
    let token: String
    let customHeaders: [DockhandCustomHeader]

    init(baseURL: URL, token: String, customHeaders: [DockhandCustomHeader] = []) {
        self.baseURL = baseURL
        self.token = DockhandToken.normalized(token)
        self.customHeaders = DockhandCustomHeaderValidator.sanitized(customHeaders)
    }

    private var client: Client {
        DockhandAPIClientFactory.makeClient(
            baseURL: baseURL,
            token: token.isEmpty ? nil : token,
            customHeaders: customHeaders
        )
    }

    /// Adds the Dockhand bearer token and the profile's custom headers. Every
    /// hand-built request must go through here so none skips proxy auth.
    func authorize(_ request: inout URLRequest) {
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.applyDockhandCustomHeaders(customHeaders)
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (data, response) = try await DockhandHTTPSession.shared.data(for: request)
        if let challenge = DockhandProxyChallenge.detect(response) {
            throw challenge
        }
        return (data, response)
    }

    static func containerLogError(statusCode: Int, data: Data) -> DockhandServiceError {
        guard statusCode >= 500 else {
            return .unexpectedStatus(statusCode)
        }

        struct ErrorPayload: Decodable {
            let error: String?
            let details: String?
        }

        let payload = try? JSONDecoder().decode(ErrorPayload.self, from: data)
        return .logsUnavailable(payload?.details ?? payload?.error)
    }

    func fetchHealthStatus() async throws -> String {
        let output = try await client.getHealth()
        switch output {
        case .ok(let response):
            return try response.body.json.status
        case .undocumented(let statusCode, _):
            throw DockhandServiceError.unexpectedStatus(statusCode)
        }
    }

    func fetchEnvironments() async throws -> [Components.Schemas.Environment] {
        var request = URLRequest(url: baseURL.appending(path: "/api/environments"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        authorize(&request)

        let (data, response) = try await send(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DockhandServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw DockhandServiceError.unexpectedStatus(httpResponse.statusCode)
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DockhandServiceError.invalidResponse
        }

        return try payload.map(Self.decodeEnvironment)
    }

    func fetchContainers(environmentID: Int) async throws -> [Components.Schemas.Container] {
        let output = try await client.listContainers(query: .init(env: environmentID))
        switch output {
        case .ok(let response):
            return try response.body.json
        case .undocumented(let statusCode, _):
            throw DockhandServiceError.unexpectedStatus(statusCode)
        }
    }

    func fetchImages(environmentID: Int) async throws -> [Components.Schemas.ImageSummary] {
        let output = try await client.listImages(query: .init(env: environmentID))
        switch output {
        case .ok(let response):
            return try response.body.json
        case .undocumented(let statusCode, _):
            throw DockhandServiceError.unexpectedStatus(statusCode)
        }
    }

    func fetchStacks(environmentID: Int) async throws -> [Components.Schemas.StackSummary] {
        let output = try await client.listStacks(query: .init(env: environmentID))
        switch output {
        case .ok(let response):
            return try response.body.json
        case .undocumented(let statusCode, _):
            throw DockhandServiceError.unexpectedStatus(statusCode)
        }
    }

    func fetchDashboardStats(environmentID: Int) async throws -> DashboardEnvironmentSnapshot {
        let response = try await performJSONRequest(
            path: "/api/dashboard/stats",
            method: "GET",
            environmentID: environmentID
        )
        return try Self.decodeDashboardStats(response)
    }

    func fetchDashboardHost(environmentID: Int) async throws -> DashboardHostSnapshot {
        let response = try await performJSONRequest(
            path: "/api/system",
            method: "GET",
            environmentID: environmentID
        )
        return try Self.decodeDashboardHost(response)
    }

    func fetchDockhandChangelog(environmentID: Int, serverVersion: String?) async throws -> [DockhandChangelogRelease] {
        // Without a reported version, a read-only request verifies capability.
        // Never guess the installed version from the bundled release history.
        if let serverVersion, !DockhandChangelogRelease.supportsChangelog(version: serverVersion) {
            throw DockhandServiceError.invalidResponse
        }
        let response = try await performJSONArrayRequest(path: "/api/changelog", method: "GET", environmentID: environmentID)
        return try DockhandChangelogRelease.decode(response)
    }

    func fetchContainerReleaseNotes(update: PendingContainerUpdate, environmentID: Int, serverVersion: String?) async throws -> ContainerReleaseNotes {
        guard DockhandChangelogRelease.supportsContainerNotes(version: serverVersion) else {
            throw DockhandServiceError.invalidResponse
        }
        return try await Self.resolveContainerReleaseNotes(update: update) { identifier in
            let response = try await performJSONRequest(
                path: "/api/containers/\(identifier)/version-notes", method: "GET", environmentID: environmentID,
                additionalQueryItems: [URLQueryItem(name: "versions", value: update.newerTags.joined(separator: ","))]
            )
            return try JSONDecoder().decode(ContainerReleaseNotes.self, from: JSONSerialization.data(withJSONObject: response))
        }
    }

    static func resolveContainerReleaseNotes(
        update: PendingContainerUpdate,
        fetch: (String) async throws -> ContainerReleaseNotes
    ) async throws -> ContainerReleaseNotes {
        do {
            return try await fetch(update.containerID)
        } catch {
            // Pending-update records can outlive a recreated container. Docker
            // accepts its name too; retry only resolution failures in the same env.
            let resolutionFailed: Bool
            switch error {
            case DockhandServiceError.message("Failed to resolve release notes"),
                 DockhandServiceError.unexpectedStatus(404),
                 DockhandServiceError.unexpectedStatus(500): resolutionFailed = true
            default: resolutionFailed = false
            }
            let name = update.containerName
            guard resolutionFailed, name != update.containerID, !name.isEmpty,
                  name.allSatisfy({ $0.isLetter || $0.isNumber || "_.-".contains($0) }),
                  !Task.isCancelled else { throw error }
            return try await fetch(name)
        }
    }

    func fetchPendingContainerUpdates(environmentID: Int) async throws -> [PendingContainerUpdate] {
        let response = try await performJSONRequest(
            path: "/api/containers/pending-updates",
            method: "GET",
            environmentID: environmentID
        )
        return Self.decodePendingContainerUpdates(response)
    }

    func startContainerUpdateCheck(environmentID: Int) async throws -> ContainerUpdateCheckOperation {
        let response = try await performJSONRequest(
            path: "/api/containers/check-updates",
            method: "POST",
            environmentID: environmentID
        )
        if let jobID = response["jobId"] as? String, !jobID.isEmpty {
            return .job(jobID)
        }
        let data = try JSONSerialization.data(withJSONObject: response)
        return .completed(try JSONDecoder().decode(ContainerUpdateCheckResult.self, from: data))
    }

    func fetchContainerUpdateCheckJob(id: String) async throws -> ContainerUpdateCheckJobSnapshot {
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        var request = URLRequest(url: baseURL.appending(path: "/api/jobs/\(encodedID)"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        authorize(&request)

        let (data, response) = try await send(request)
        try Self.validateResponse(response, data: data)
        return try JSONDecoder().decode(ContainerUpdateCheckJobSnapshot.self, from: data)
    }

    func updateContainers(ids: [String], environmentID: Int) async throws -> ContainerBatchUpdateResponse {
        guard !ids.isEmpty else { throw DockhandServiceError.invalidResponse }
        let response = try await performJSONRequest(
            path: "/api/containers/batch-update",
            method: "POST",
            environmentID: environmentID,
            body: ["containerIds": ids]
        )
        let data = try JSONSerialization.data(withJSONObject: response)
        return try JSONDecoder().decode(ContainerBatchUpdateResponse.self, from: data)
    }

    func fetchVolumes(environmentID: Int) async throws -> [VolumeSnapshot] {
        let response = try await performJSONArrayRequest(
            path: "/api/volumes",
            method: "GET",
            environmentID: environmentID
        )
        return Self.decodeVolumes(response)
    }

    func fetchNetworks(environmentID: Int) async throws -> [NetworkSnapshot] {
        let response = try await performJSONArrayRequest(
            path: "/api/networks",
            method: "GET",
            environmentID: environmentID
        )
        return Self.decodeNetworks(response)
    }

    func fetchContainerActivity(environmentID: Int, limit: Int = 100) async throws -> ContainerActivitySnapshot {
        let response = try await performJSONRequest(
            path: "/api/activity",
            method: "GET",
            environmentID: environmentID,
            additionalQueryItems: [
                URLQueryItem(name: "environmentId", value: "\(environmentID)"),
                URLQueryItem(name: "limit", value: "\(limit)")
            ]
        )
        return Self.decodeContainerActivity(response)
    }

    func clearPendingContainerUpdate(containerID: String, environmentID: Int) async throws {
        let response = try await performJSONRequest(
            path: "/api/containers/pending-updates",
            method: "DELETE",
            environmentID: environmentID,
            additionalQueryItems: [URLQueryItem(name: "containerId", value: containerID)]
        )
        guard response["success"] as? Bool == true else {
            throw DockhandServiceError.invalidResponse
        }
    }

    func fetchStackEditorDocument(name: String, environmentID: Int) async throws -> StackEditorDocument {
        async let composeOutput = client.getStackCompose(path: .init(name: name), query: .init(env: environmentID))
        async let envOutput = client.getStackEnvFile(path: .init(name: name), query: .init(env: environmentID))

        let composeResult = try await composeOutput
        let envResult = try await envOutput

        let composeDocument: Components.Schemas.StackComposeDocument
        switch composeResult {
        case .ok(let response):
            composeDocument = try response.body.json
        case .notFound(let response):
            composeDocument = try response.body.json
        case .undocumented(let statusCode, _):
            throw DockhandServiceError.unexpectedStatus(statusCode)
        }

        let envDocument: Components.Schemas.RawEnvDocument
        switch envResult {
        case .ok(let response):
            envDocument = try response.body.json
        case .undocumented(let statusCode, _):
            throw DockhandServiceError.unexpectedStatus(statusCode)
        }

        return StackEditorDocument(
            composeContent: composeDocument.content ?? "",
            envContent: envDocument.content,
            composePath: composeDocument.composePath,
            envPath: composeDocument.envPath,
            suggestedEnvPath: composeDocument.suggestedEnvPath,
            needsFileLocation: composeDocument.needsFileLocation ?? false,
            noEnvFile: envDocument.noEnvFile ?? false,
            composeError: composeDocument.error
        )
    }

    func fetchContainerLogs(
        containerID: String,
        environmentID: Int,
        tail: Int = 200
    ) async throws -> ContainerLogsDocument {
        let encodedID = containerID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? containerID
        let path = "/api/containers/\(encodedID)/logs"

        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw DockhandServiceError.invalidResponse
        }

        components.queryItems = [
            URLQueryItem(name: "env", value: "\(environmentID)"),
            URLQueryItem(name: "tail", value: "\(tail)")
        ]

        guard let url = components.url else {
            throw DockhandServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        authorize(&request)

        let (data, response) = try await send(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DockhandServiceError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw Self.containerLogError(statusCode: httpResponse.statusCode, data: data)
        }

        let decoded = try JSONDecoder().decode(ContainerLogsResponse.self, from: data)
        return ContainerLogsDocument(logs: decoded.logs)
    }

    func fetchContainerShells(
        containerID: String,
        environmentID: Int
    ) async throws -> ContainerShellDetectionResult {
        let encodedID = containerID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? containerID
        let path = "/api/containers/\(encodedID)/shells"

        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw DockhandServiceError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "env", value: "\(environmentID)")]

        guard let url = components.url else {
            throw DockhandServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        authorize(&request)

        let (data, response) = try await send(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DockhandServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw DockhandServiceError.unexpectedStatus(httpResponse.statusCode)
        }

        let decoded = try JSONDecoder().decode(ContainerShellDetectionResponse.self, from: data)
        return decoded.result
    }

    func makeContainerShellRequest(
        containerID: String,
        environmentID: Int,
        shell: String,
        user: String
    ) throws -> URLRequest {
        let encodedID = containerID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? containerID
        let path = "/api/containers/\(encodedID)/exec"
        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw DockhandServiceError.invalidResponse
        }

        components.queryItems = [
            URLQueryItem(name: "shell", value: shell),
            URLQueryItem(name: "user", value: user),
            URLQueryItem(name: "envId", value: "\(environmentID)")
        ]

        guard let url = try components.url?.dockhandWebSocketURL() else {
            throw DockhandServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        authorize(&request)
        return request
    }

    func streamContainerLogs(
        containerID: String,
        environmentID: Int,
        tail: Int = 200,
        onEvent: @escaping @Sendable (ContainerLogEvent) async -> Void
    ) async throws {
        let encodedID = containerID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? containerID
        let path = "/api/containers/\(encodedID)/logs/stream"

        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw DockhandServiceError.invalidResponse
        }

        components.queryItems = [
            URLQueryItem(name: "env", value: "\(environmentID)"),
            URLQueryItem(name: "tail", value: "\(tail)")
        ]

        guard let url = components.url else {
            throw DockhandServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        authorize(&request)

        let eventStream = ContainerLogEventStream(request: request)
        for try await event in eventStream.events {
            try Task.checkCancellation()
            await onEvent(event)
        }
    }

    func updateStackCompose(
        name: String,
        environmentID: Int,
        content: String,
        composePath: String?,
        envPath: String?
    ) async throws {
        let request = Components.Schemas.UpdateStackComposeRequest(
            content: content,
            restart: false,
            composePath: composePath,
            envPath: envPath,
            moveFromDir: nil,
            oldComposePath: nil,
            oldEnvPath: nil
        )

        let output = try await client.updateStackCompose(
            path: .init(name: name),
            query: .init(env: environmentID),
            body: .json(request)
        )

        switch output {
        case .ok(let response):
            let body = try response.body.json
            if body.success == false {
                throw DockhandServiceError.message(body.error ?? "Failed to save compose file")
            }
        case .undocumented(let statusCode, _):
            throw DockhandServiceError.unexpectedStatus(statusCode)
        }
    }

    func updateStackEnvFile(
        name: String,
        environmentID: Int,
        content: String
    ) async throws {
        let request = Components.Schemas.UpdateRawEnvRequest(content: content)
        let output = try await client.updateStackEnvFile(
            path: .init(name: name),
            query: .init(env: environmentID),
            body: .json(request)
        )

        switch output {
        case .ok(let response):
            let body = try response.body.json
            if body.success == false {
                throw DockhandServiceError.message(body.error ?? "Failed to save .env")
            }
        case .undocumented(let statusCode, _):
            throw DockhandServiceError.unexpectedStatus(statusCode)
        }
    }

    func startImagePull(
        imageName: String,
        environmentID: Int
    ) async throws -> ImagePullStartResult {
        guard var components = URLComponents(
            url: baseURL.appending(path: "/api/images/pull"),
            resolvingAgainstBaseURL: false
        ) else {
            throw DockhandServiceError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "env", value: "\(environmentID)")]
        guard let url = components.url else {
            throw DockhandServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "image": imageName,
            "scanAfterPull": false
        ])

        let (data, response) = try await send(request)
        try Self.validateResponse(response, data: data)

        if let payload = try? JSONDecoder().decode(ImagePullJobStartPayload.self, from: data),
           let jobID = payload.jobId,
           !jobID.isEmpty {
            return .job(jobID)
        }

        let completed = try JSONDecoder().decode(ImagePullProgressEvent.self, from: data)
        if let error = completed.error, !error.isEmpty {
            throw DockhandServiceError.message(error)
        }
        if completed.status == "complete" {
            return .completed(completed)
        }
        throw DockhandServiceError.invalidResponse
    }

    func fetchImagePullJob(id: String) async throws -> ImagePullJobSnapshot {
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        var request = URLRequest(url: baseURL.appending(path: "/api/jobs/\(encodedID)"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        authorize(&request)

        let (data, response) = try await send(request)
        try Self.validateResponse(response, data: data)
        return try JSONDecoder().decode(ImagePullJobSnapshot.self, from: data)
    }

    func pruneImages(
        environmentID: Int,
        danglingOnly: Bool
    ) async throws {
        let response = try await performJSONRequest(
            path: "/api/prune/images",
            method: "POST",
            environmentID: environmentID,
            additionalQueryItems: danglingOnly ? [] : [URLQueryItem(name: "dangling", value: "false")]
        )

        if response["success"] as? Bool == true {
            return
        }
        if let error = response["error"] as? String, !error.isEmpty {
            throw DockhandServiceError.message(error)
        }
        throw DockhandServiceError.invalidResponse
    }

    func tagImage(
        imageID: String,
        environmentID: Int,
        repo: String,
        tag: String
    ) async throws {
        let encodedID = imageID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? imageID
        let response = try await performJSONRequest(
            path: "/api/images/\(encodedID)/tag",
            method: "POST",
            environmentID: environmentID,
            body: ["repo": repo, "tag": tag]
        )

        if response["success"] as? Bool == true {
            return
        }
        throw DockhandServiceError.message((response["error"] as? String) ?? "Failed to tag image")
    }

    func deleteImage(
        imageReference: String,
        environmentID: Int
    ) async throws {
        let encodedReference = imageReference.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? imageReference
        let response = try await performJSONRequest(
            path: "/api/images/\(encodedReference)",
            method: "DELETE",
            environmentID: environmentID
        )

        if response["success"] as? Bool == true || response["status"] as? String == "complete" {
            return
        }
        if let error = response["error"] as? String {
            throw DockhandServiceError.message(error)
        }
        throw DockhandServiceError.invalidResponse
    }

    func deleteImageTag(
        imageTag: String,
        environmentID: Int
    ) async throws {
        let response = try await performJSONRequest(
            path: "/api/batch",
            method: "POST",
            environmentID: environmentID,
            body: [
                "operation": "remove",
                "entityType": "images",
                "items": [
                    [
                        "id": imageTag,
                        "name": imageTag
                    ]
                ]
            ]
        )

        if let summary = response["summary"] as? [String: Any],
           let failed = summary["failed"] as? Int,
           failed == 0 {
            return
        }
        if response["type"] as? String == "complete" {
            return
        }
        if let error = response["error"] as? String {
            throw DockhandServiceError.message(error)
        }
        throw DockhandServiceError.invalidResponse
    }

    func scanImage(
        imageName: String,
        environmentID: Int
    ) async throws -> ImageScanDocument {
        let response = try await performJSONRequest(
            path: "/api/images/scan",
            method: "POST",
            environmentID: environmentID,
            body: ["imageName": imageName]
        )

        if let error = response["error"] as? String, !error.isEmpty {
            throw DockhandServiceError.message(error)
        }

        let results: [String] = (response["results"] as? [[String: Any]])?.map {
            if let target = $0["target"] as? String,
               let vulnerability = $0["vulnerability"] as? String {
                return "\(target): \(vulnerability)"
            }
            return $0.description
        } ?? []

        return ImageScanDocument(
            stage: (response["stage"] as? String) ?? "complete",
            message: (response["message"] as? String) ?? "Scan complete",
            progress: response["progress"] as? Int,
            results: results
        )
    }

    func containerAction(_ action: ContainerAction, containerID: String, environmentID: Int) async throws {
        let path = Operations.StartContainer.Input.Path(id: containerID)
        let query = Operations.StartContainer.Input.Query(env: environmentID)

        switch action {
        case .start:
            let output = try await client.startContainer(path: path, query: query)
            try validateAction(output)
        case .stop:
            let output = try await client.stopContainer(path: .init(id: containerID), query: .init(env: environmentID))
            try validateAction(output)
        case .restart:
            let output = try await client.restartContainer(path: .init(id: containerID), query: .init(env: environmentID))
            try validateAction(output)
        case .pause:
            let output = try await client.pauseContainer(path: .init(id: containerID), query: .init(env: environmentID))
            try validateAction(output)
        case .unpause:
            let output = try await client.unpauseContainer(path: .init(id: containerID), query: .init(env: environmentID))
            try validateAction(output)
        }
    }

    func stackAction(_ action: StackAction, stackName: String, environmentID: Int) async throws {
        let encodedName = stackName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stackName
        let response = try await performJSONRequest(
            path: "/api/stacks/\(encodedName)/\(action.endpoint)",
            method: "POST",
            environmentID: environmentID
        )

        if response["success"] as? Bool == true || response["status"] as? String == "complete" {
            return
        }
        if let error = response["error"] as? String, !error.isEmpty {
            throw DockhandServiceError.message(error)
        }
        throw DockhandServiceError.invalidResponse
    }

    func redeployStack(
        stackName: String,
        environmentID: Int,
        options: StackDeployOptions
    ) async throws {
        let encodedName = stackName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stackName
        let response = try await performJSONRequest(
            path: "/api/stacks/\(encodedName)/deploy",
            method: "POST",
            environmentID: environmentID,
            body: [
                "pull": options.pull,
                "build": options.build,
                "forceRecreate": options.forceRecreate
            ]
        )

        if response["success"] as? Bool == true || response["status"] as? String == "complete" {
            return
        }
        if let error = response["error"] as? String, !error.isEmpty {
            throw DockhandServiceError.message(error)
        }
        throw DockhandServiceError.invalidResponse
    }

    func startStackRedeploy(
        stackName: String,
        environmentID: Int,
        options: StackDeployOptions
    ) async throws -> StackRedeployStartResult {
        let encodedName = stackName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stackName
        guard var components = URLComponents(
            url: baseURL.appending(path: "/api/stacks/\(encodedName)/deploy"),
            resolvingAgainstBaseURL: false
        ) else {
            throw DockhandServiceError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "env", value: "\(environmentID)")]
        guard let url = components.url else {
            throw DockhandServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "pull": options.pull,
            "build": options.build,
            "forceRecreate": options.forceRecreate
        ])

        let (data, response) = try await send(request)
        try Self.validateResponse(response, data: data)

        if let payload = try? JSONDecoder().decode(ImagePullJobStartPayload.self, from: data),
           let jobID = payload.jobId,
           !jobID.isEmpty {
            return .job(jobID)
        }

        let result = try JSONDecoder().decode(StackRedeployResult.self, from: data)
        if result.success == false || result.error != nil {
            throw DockhandServiceError.message(result.error ?? "Stack redeploy failed")
        }
        return .completed(result)
    }

    func fetchStackRedeployJob(id: String) async throws -> StackRedeployJobSnapshot {
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        var request = URLRequest(url: baseURL.appending(path: "/api/jobs/\(encodedID)"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        authorize(&request)

        let (data, response) = try await send(request)
        try Self.validateResponse(response, data: data)
        return try JSONDecoder().decode(StackRedeployJobSnapshot.self, from: data)
    }

    func deleteStack(
        stackName: String,
        environmentID: Int,
        deleteVolumes: Bool
    ) async throws {
        let encodedName = stackName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stackName
        var queryItems = [URLQueryItem(name: "force", value: "true")]
        if deleteVolumes {
            queryItems.append(URLQueryItem(name: "volumes", value: "true"))
        }

        let response = try await performJSONRequest(
            path: "/api/stacks/\(encodedName)",
            method: "DELETE",
            environmentID: environmentID,
            additionalQueryItems: queryItems
        )

        if response["success"] as? Bool == true || response["status"] as? String == "complete" {
            return
        }
        if let error = response["error"] as? String, !error.isEmpty {
            throw DockhandServiceError.message(error)
        }
        throw DockhandServiceError.invalidResponse
    }

    private func validateAction(_ output: some Sendable) throws {
        if let output = output as? Operations.StartContainer.Output {
            switch output {
            case .ok(let response):
                let body = try response.body.json
                if body.success == false { throw DockhandServiceError.message(body.error ?? "Action failed") }
            case .undocumented(let statusCode, _):
                throw DockhandServiceError.unexpectedStatus(statusCode)
            }
        } else if let output = output as? Operations.StopContainer.Output {
            switch output {
            case .ok(let response):
                let body = try response.body.json
                if body.success == false { throw DockhandServiceError.message(body.error ?? "Action failed") }
            case .undocumented(let statusCode, _):
                throw DockhandServiceError.unexpectedStatus(statusCode)
            }
        } else if let output = output as? Operations.RestartContainer.Output {
            switch output {
            case .ok(let response):
                let body = try response.body.json
                if body.success == false { throw DockhandServiceError.message(body.error ?? "Action failed") }
            case .undocumented(let statusCode, _):
                throw DockhandServiceError.unexpectedStatus(statusCode)
            }
        } else if let output = output as? Operations.PauseContainer.Output {
            switch output {
            case .ok(let response):
                let body = try response.body.json
                if body.success == false { throw DockhandServiceError.message(body.error ?? "Action failed") }
            case .undocumented(let statusCode, _):
                throw DockhandServiceError.unexpectedStatus(statusCode)
            }
        } else if let output = output as? Operations.UnpauseContainer.Output {
            switch output {
            case .ok(let response):
                let body = try response.body.json
                if body.success == false { throw DockhandServiceError.message(body.error ?? "Action failed") }
            case .undocumented(let statusCode, _):
                throw DockhandServiceError.unexpectedStatus(statusCode)
            }
        } else {
            throw DockhandServiceError.invalidResponse
        }
    }

    private func performJSONRequest(
        path: String,
        method: String,
        environmentID: Int,
        additionalQueryItems: [URLQueryItem] = [],
        body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw DockhandServiceError.invalidResponse
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "env", value: "\(environmentID)"))
        queryItems.append(contentsOf: additionalQueryItems)
        components.queryItems = queryItems
        guard let url = components.url else {
            throw DockhandServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        authorize(&request)
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await send(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DockhandServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let error = json["error"] as? String {
                throw DockhandServiceError.message(error)
            }
            throw DockhandServiceError.unexpectedStatus(httpResponse.statusCode)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private func performJSONArrayRequest(
        path: String,
        method: String,
        environmentID: Int
    ) async throws -> [[String: Any]] {
        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw DockhandServiceError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "env", value: "\(environmentID)")]
        guard let url = components.url else {
            throw DockhandServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        authorize(&request)

        let (data, response) = try await send(request)
        try Self.validateResponse(response, data: data)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw DockhandServiceError.invalidResponse
        }
        return json
    }

    private static func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DockhandServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let error = json["error"] as? String {
                throw DockhandServiceError.message(error)
            }
            throw DockhandServiceError.unexpectedStatus(httpResponse.statusCode)
        }
    }
}

private struct ImagePullJobStartPayload: Decodable {
    let jobId: String?
}

private struct ContainerLogsResponse: Decodable {
    let logs: String
}

private struct ContainerShellDetectionResponse: Decodable {
    struct ShellInfo: Decodable {
        var path: String
        var label: String
        var available: Bool
    }

    var shells: [String]
    var defaultShell: String?
    var allShells: [ShellInfo]
    var error: String?

    var result: ContainerShellDetectionResult {
        ContainerShellDetectionResult(
            shells: shells,
            defaultShell: defaultShell,
            allShells: allShells.map {
                ContainerShellInfo(path: $0.path, label: $0.label, available: $0.available)
            },
            error: error
        )
    }
}

private struct StreamedLogPayload: Decodable {
    let text: String
}

private struct StreamedLogErrorPayload: Decodable {
    let error: String?
    let reason: String?
}

enum ContainerLogEvent: Sendable {
    case connected
    case log(String)
    case serverError(String)
    case ended
}

struct ContainerLogSSEDecoder {
    private var buffer = Data()
    private var parser = ContainerLogSSEParser()

    mutating func consume(_ data: Data) throws -> [ContainerLogEvent] {
        buffer.append(data)
        var events: [ContainerLogEvent] = []

        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = Data(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            var line = String(decoding: lineData, as: UTF8.self)
            if line.last == "\r" {
                line.removeLast()
            }
            if let event = try parser.consume(line: line) {
                events.append(event)
            }
        }

        return events
    }

    mutating func finish() throws -> [ContainerLogEvent] {
        guard !buffer.isEmpty else { return [] }
        defer { buffer.removeAll(keepingCapacity: false) }
        let line = String(decoding: buffer, as: UTF8.self)
        return try parser.consume(line: line).map { [$0] } ?? []
    }
}

private final class ContainerLogEventStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var continuation: AsyncThrowingStream<ContainerLogEvent, Error>.Continuation?
    private var decoder = ContainerLogSSEDecoder()
    private var responseStatus: Int?
    private var errorBody = Data()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private let request: URLRequest

    init(request: URLRequest) {
        self.request = request
    }

    lazy var events: AsyncThrowingStream<ContainerLogEvent, Error> = {
        AsyncThrowingStream { continuation in
            self.continuation = continuation

            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            let session = URLSession(
                configuration: .dockhandEphemeral,
                delegate: self,
                delegateQueue: delegateQueue
            )
            let task = session.dataTask(with: self.request)
            self.session = session
            self.task = task
            continuation.onTermination = { [weak self] _ in
                self?.cancel()
            }
            task.resume()
        }
    }()

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            continuation?.finish(throwing: DockhandServiceError.invalidResponse)
            completionHandler(.cancel)
            return
        }

        if let challenge = DockhandProxyChallenge.detect(response) {
            continuation?.finish(throwing: challenge)
            completionHandler(.cancel)
            return
        }

        responseStatus = response.statusCode
        if response.statusCode == 200 {
            continuation?.yield(.connected)
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let original = task.originalRequest?.url ?? response.url
        completionHandler(DockhandRedirectPolicy.allows(from: original, to: request.url) ? request : nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard responseStatus == 200 else {
            errorBody.append(data)
            return
        }

        do {
            for event in try decoder.consume(data) {
                continuation?.yield(event)
            }
        } catch {
            continuation?.finish(throwing: error)
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        defer { releaseResources() }

        if let error {
            if (error as? URLError)?.code == .cancelled {
                continuation?.finish(throwing: CancellationError())
            } else {
                continuation?.finish(throwing: error)
            }
            return
        }

        guard let responseStatus else {
            continuation?.finish(throwing: DockhandServiceError.invalidResponse)
            return
        }
        guard responseStatus == 200 else {
            continuation?.finish(
                throwing: DockhandService.containerLogError(statusCode: responseStatus, data: errorBody)
            )
            return
        }

        do {
            for event in try decoder.finish() {
                continuation?.yield(event)
            }
            continuation?.finish()
        } catch {
            continuation?.finish(throwing: error)
        }
    }

    private func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
    }

    private func releaseResources() {
        continuation = nil
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
    }
}

struct ContainerLogSSEParser {
    private var currentEvent: String?
    private var payloadLines: [String] = []

    mutating func consume(line: String) throws -> ContainerLogEvent? {
        let normalizedLine = line.trimmingCharacters(in: .newlines)

        if normalizedLine.isEmpty {
            defer {
                currentEvent = nil
                payloadLines = []
            }

            let payload = payloadLines.joined(separator: "\n")
            switch currentEvent {
            case "connected":
                return .connected
            case "log":
                guard let data = payload.data(using: .utf8) else { return nil }
                let decoded = try JSONDecoder().decode(StreamedLogPayload.self, from: data)
                return .log(decoded.text)
            case "error":
                if let data = payload.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(StreamedLogErrorPayload.self, from: data) {
                    return .serverError(decoded.error ?? decoded.reason ?? payload)
                }
                return .serverError(payload)
            case "end":
                return .ended
            default:
                return nil
            }
        }

        if normalizedLine.hasPrefix(":") {
            return nil
        }
        if normalizedLine.hasPrefix("event:") {
            currentEvent = String(normalizedLine.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        } else if normalizedLine.hasPrefix("data:") {
            payloadLines.append(String(normalizedLine.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

enum ContainerAction: String, CaseIterable, Identifiable {
    case start
    case stop
    case restart
    case pause
    case unpause

    var id: String { rawValue }

    var completedLabel: String {
        switch self {
        case .start:
            return String(localized: "started")
        case .stop:
            return String(localized: "stopped")
        case .restart:
            return String(localized: "restarted")
        case .pause:
            return String(localized: "paused")
        case .unpause:
            return String(localized: "resumed")
        }
    }
}

enum StackAction: String, CaseIterable, Identifiable {
    case start
    case stop
    case restart
    case down
    case redeploy

    var id: String { rawValue }

    var endpoint: String {
        switch self {
        case .start, .stop, .restart, .down:
            return rawValue
        case .redeploy:
            return "deploy"
        }
    }
}
