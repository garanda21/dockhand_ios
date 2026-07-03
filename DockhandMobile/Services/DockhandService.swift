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

struct StackDeployOptions: Sendable, Hashable {
    var pull = true
    var build = false
    var forceRecreate = false
}

enum DockhandServiceError: LocalizedError {
    case invalidResponse
    case message(String)
    case unexpectedStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return String(localized: "Invalid response from Dockhand")
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

    private var client: Client {
        DockhandAPIClientFactory.makeClient(baseURL: baseURL, token: token.isEmpty ? nil : token)
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
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
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
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DockhandServiceError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw DockhandServiceError.unexpectedStatus(httpResponse.statusCode)
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
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
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
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
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
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (bytes, response) = try await URLSession(configuration: .ephemeral).bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DockhandServiceError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw DockhandServiceError.unexpectedStatus(httpResponse.statusCode)
        }

        var currentEvent: String?
        var payloadLines: [String] = []

        for try await line in bytes.lines {
            try Task.checkCancellation()

            if line.isEmpty {
                let payload = payloadLines.joined(separator: "\n")
                if currentEvent == "log",
                   let data = payload.data(using: .utf8) {
                    let decoded = try JSONDecoder().decode(StreamedLogPayload.self, from: data)
                    await onEvent(.log(decoded.text))
                } else if currentEvent == "connected" {
                    await onEvent(.connected)
                }

                currentEvent = nil
                payloadLines = []
                continue
            }

            if line.hasPrefix("event:") {
                currentEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                payloadLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
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

    func pullImage(
        imageName: String,
        environmentID: Int
    ) async throws {
        let body = ["image": imageName]
        let response = try await performJSONRequest(
            path: "/api/images/pull",
            method: "POST",
            environmentID: environmentID,
            body: body
        )

        let status = response["status"] as? String
        let success = response["success"] as? Bool
        let error = response["error"] as? String

        if success == false {
            throw DockhandServiceError.message(error ?? "Image pull failed")
        }
        if let error, !error.isEmpty {
            throw DockhandServiceError.message(error)
        }
        if status == "complete" || success == true {
            return
        }
        throw DockhandServiceError.invalidResponse
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
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
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

enum ContainerLogEvent: Sendable {
    case connected
    case log(String)
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
