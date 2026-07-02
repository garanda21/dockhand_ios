import Foundation

struct ContainerShellTarget: Hashable, Identifiable, Sendable {
    let id: String
    let name: String
}

struct ContainerShellInfo: Hashable, Sendable {
    var path: String
    var label: String
    var available: Bool
}

struct ContainerShellDetectionResult: Hashable, Sendable {
    var shells: [String]
    var defaultShell: String?
    var allShells: [ContainerShellInfo]
    var error: String?

    var hasAvailableShells: Bool {
        !shells.isEmpty
    }

    func bestShell(preferredShell: String) -> String? {
        if shells.contains(preferredShell) {
            return preferredShell
        }

        let preferredName = URL(fileURLWithPath: preferredShell).lastPathComponent
        if let byName = shells.first(where: { URL(fileURLWithPath: $0).lastPathComponent == preferredName }) {
            return byName
        }

        return defaultShell ?? shells.first
    }
}

enum ContainerShellUser: Hashable, Sendable {
    static let presets: [(value: String, label: String)] = [
        ("root", "root"),
        ("nobody", "nobody"),
        ("", String(localized: "Container default"))
    ]
}

struct TerminalFeedEvent: Equatable, Sendable {
    let id = UUID()
    var text: String
}

enum ContainerShellStatus: Sendable {
    case idle
    case detecting
    case connecting
    case connected
    case disconnected
    case ended
    case error

    var localizedLabel: String {
        switch self {
        case .idle:
            return String(localized: "Idle")
        case .detecting:
            return String(localized: "Detecting shells")
        case .connecting:
            return String(localized: "Connecting")
        case .connected:
            return String(localized: "Connected")
        case .disconnected:
            return String(localized: "Disconnected")
        case .ended:
            return String(localized: "Session ended")
        case .error:
            return String(localized: "Error")
        }
    }
}

private struct ContainerShellInputPayload: Encodable {
    var type = "input"
    var data: String
}

private struct ContainerShellResizePayload: Encodable {
    var type = "resize"
    var cols: Int
    var rows: Int
}

struct ContainerShellWebSocketMessage: Decodable {
    var type: String
    var data: String?
    var message: String?
}

extension Encodable {
    func encodedJSONString() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw DockhandServiceError.invalidResponse
        }
        return string
    }
}

extension URL {
    func dockhandWebSocketURL() throws -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            throw DockhandServiceError.invalidResponse
        }

        switch components.scheme?.lowercased() {
        case "http":
            components.scheme = "ws"
        case "https":
            components.scheme = "wss"
        case "ws", "wss":
            break
        default:
            throw DockhandServiceError.invalidResponse
        }

        guard let url = components.url else {
            throw DockhandServiceError.invalidResponse
        }
        return url
    }
}

extension URLSessionWebSocketTask {
    func sendInput(_ data: String) async throws {
        let payload = try ContainerShellInputPayload(data: data).encodedJSONString()
        try await send(.string(payload))
    }

    func sendResize(cols: Int, rows: Int) async throws {
        let payload = try ContainerShellResizePayload(cols: cols, rows: rows).encodedJSONString()
        try await send(.string(payload))
    }
}
