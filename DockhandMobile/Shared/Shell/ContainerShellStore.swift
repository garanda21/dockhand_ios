import Foundation
import Observation

@MainActor
@Observable
final class ContainerShellStore {
    var shellDetection: ContainerShellDetectionResult?
    var selectedShell = "/bin/sh"
    var selectedUser = "root"
    var customUserInput = ""
    var customUsers: [String] = []
    var status = ContainerShellStatus.idle
    var isDetectingShells = false
    var isConnected = false
    var error: String?
    var feedEvent: TerminalFeedEvent?

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var preferenceKey = ""

    func configure(target: ContainerShellTarget, scope: DockhandConnectionScope) {
        preferenceKey = Self.preferenceKey(target: target, scope: scope)
        customUsers = Self.loadCustomUsers()
        selectedShell = UserDefaults.standard.string(forKey: "\(preferenceKey).shell") ?? "/bin/sh"
        selectedUser = UserDefaults.standard.string(forKey: "\(preferenceKey).user") ?? "root"
    }

    func detectShells(target: ContainerShellTarget, appModel: AppModel) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else { return }

        isDetectingShells = true
        error = nil
        if status == .idle {
            status = .detecting
        }
        defer { isDetectingShells = false }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            let result = try await service.fetchContainerShells(
                containerID: target.id,
                environmentID: environmentID
            )
            shellDetection = result
            if let best = result.bestShell(preferredShell: selectedShell) {
                selectedShell = best
            }
            if let error = result.error, !error.isEmpty {
                self.error = error
            }
            if status == .detecting {
                status = .idle
            }
        } catch {
            self.error = error.localizedDescription
            status = .error
        }
    }

    func connect(target: ContainerShellTarget, appModel: AppModel) async {
        disconnect(status: .connecting)
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else { return }

        error = nil
        status = .connecting
        appendSystemLine("Connecting to \(target.name)...")
        appendSystemLine("Shell: \(selectedShell), User: \(selectedUser.isEmpty ? "container default" : selectedUser)")
        persistSelection()

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            let request = try service.makeContainerShellRequest(
                containerID: target.id,
                environmentID: environmentID,
                shell: selectedShell,
                user: selectedUser
            )
            let task = URLSession(configuration: .ephemeral).webSocketTask(with: request)
            webSocketTask = task
            task.resume()
            isConnected = true
            status = .connected
            receiveTask = Task { [weak self] in
                await self?.receiveLoop()
            }
        } catch {
            self.error = error.localizedDescription
            status = .error
            isConnected = false
            appendErrorLine(error.localizedDescription)
        }
    }

    func reconnect(target: ContainerShellTarget, appModel: AppModel) async {
        appendSystemLine("Reconnecting...")
        await connect(target: target, appModel: appModel)
    }

    func disconnect(status: ContainerShellStatus = .disconnected) {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        self.status = status
    }

    func sendInput(_ input: String) {
        guard let webSocketTask, isConnected else { return }
        Task {
            do {
                try await webSocketTask.sendInput(input)
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.status = .error
                    self.appendErrorLine(error.localizedDescription)
                }
            }
        }
    }

    func sendResize(cols: Int, rows: Int) {
        guard let webSocketTask, isConnected else { return }
        Task {
            try? await webSocketTask.sendResize(cols: cols, rows: rows)
        }
    }

    func commitCustomUser() {
        let trimmed = customUserInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        selectedUser = trimmed
        customUserInput = ""
        if !ContainerShellUser.presets.contains(where: { $0.value == trimmed }),
           !customUsers.contains(trimmed) {
            customUsers.append(trimmed)
            customUsers.sort()
            Self.saveCustomUsers(customUsers)
        }
    }

    func removeCustomUser(_ user: String) {
        customUsers.removeAll { $0 == user }
        Self.saveCustomUsers(customUsers)
        if selectedUser == user {
            selectedUser = "root"
        }
    }

    func clear() {
        feedEvent = TerminalFeedEvent(text: "\u{001B}[2J\u{001B}[H")
    }

    private func receiveLoop() async {
        guard let webSocketTask else { return }

        do {
            while !Task.isCancelled {
                let message = try await webSocketTask.receive()
                try Task.checkCancellation()
                handle(message)
            }
        } catch is CancellationError {
            isConnected = false
            if status == .connected {
                status = .disconnected
            }
        } catch {
            isConnected = false
            if status != .ended {
                self.error = error.localizedDescription
                status = .error
                appendErrorLine(error.localizedDescription)
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let string):
            handlePayload(string)
        case .data(let data):
            if let string = String(data: data, encoding: .utf8) {
                handlePayload(string)
            }
        @unknown default:
            break
        }
    }

    private func handlePayload(_ payload: String) {
        guard let data = payload.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ContainerShellWebSocketMessage.self, from: data) else {
            feedEvent = TerminalFeedEvent(text: payload)
            return
        }

        switch decoded.type {
        case "output":
            if let output = decoded.data {
                feedEvent = TerminalFeedEvent(text: output)
            }
        case "error":
            let message = decoded.message ?? "Shell error"
            error = message
            status = .error
            appendErrorLine(message)
        case "exit":
            isConnected = false
            status = .ended
            appendSystemLine("Session ended.")
        default:
            break
        }
    }

    private func persistSelection() {
        UserDefaults.standard.set(selectedShell, forKey: "\(preferenceKey).shell")
        UserDefaults.standard.set(selectedUser, forKey: "\(preferenceKey).user")
    }

    private func appendSystemLine(_ line: String) {
        feedEvent = TerminalFeedEvent(text: "\u{001B}[90m\(line)\u{001B}[0m\r\n")
    }

    private func appendErrorLine(_ line: String) {
        feedEvent = TerminalFeedEvent(text: "\u{001B}[31mError: \(line)\u{001B}[0m\r\n")
    }

    private static func preferenceKey(target: ContainerShellTarget, scope: DockhandConnectionScope) -> String {
        "dockhand.shell.\(scope.profileID ?? "none").\(scope.environmentID ?? -1).\(target.id)"
    }

    private static func loadCustomUsers() -> [String] {
        UserDefaults.standard.stringArray(forKey: "dockhand.shell.customUsers") ?? []
    }

    private static func saveCustomUsers(_ users: [String]) {
        UserDefaults.standard.set(users, forKey: "dockhand.shell.customUsers")
    }
}
