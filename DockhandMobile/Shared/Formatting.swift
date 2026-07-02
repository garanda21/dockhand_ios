import DockhandAPI
import Foundation

private enum DockhandRuntimeState: String {
    case running
    case exited
    case stopped
    case paused
    case created
    case restarting
    case dead
    case removing

    init(rawState: String) {
        self = DockhandRuntimeState(rawValue: rawState.lowercased()) ?? .exited
    }
}

extension String {
    var normalizedDockhandState: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var localizedDockhandStateLabel: String {
        switch normalizedDockhandState {
        case "running":
            return String(localized: "Running")
        case "restarting":
            return String(localized: "Restarting")
        case "paused":
            return String(localized: "Paused")
        case "created":
            return String(localized: "Created")
        case "exited":
            return String(localized: "Exited")
        case "stopped":
            return String(localized: "Stopped")
        case "dead":
            return String(localized: "Dead")
        case "removing":
            return String(localized: "Removing")
        default:
            return self
        }
    }

    var localizedConnectionTypeLabel: String {
        switch normalizedDockhandState {
        case "socket":
            return String(localized: "Socket")
        case "http":
            return String(localized: "HTTP")
        case "https":
            return String(localized: "HTTPS")
        case "tcp":
            return String(localized: "TCP")
        default:
            return replacingOccurrences(of: "-", with: " ")
        }
    }

    var localizedDockerRuntimeText: String {
        let exactStateLabel = localizedDockhandStateLabel
        if exactStateLabel != self {
            return exactStateLabel
        }

        var text = self

        let replacements = [
            ("Up ", String(localized: "Up ")),
            ("Exited ", String(localized: "Exited ")),
            ("Created", String(localized: "Created")),
            ("Paused", String(localized: "Paused")),
            ("Restarting", String(localized: "Restarting")),
            ("Dead", String(localized: "Dead")),
            ("Removal In Progress", String(localized: "Removal In Progress")),
            (" (healthy)", String(localized: " (healthy)")),
            (" (unhealthy)", String(localized: " (unhealthy)")),
            ("About an hour", String(localized: "About an hour")),
            ("About a minute", String(localized: "About a minute")),
            ("Less than a second", String(localized: "Less than a second")),
            ("Less than a minute", String(localized: "Less than a minute"))
        ]

        for (source, target) in replacements {
            text = text.replacingOccurrences(of: source, with: target)
        }

        let unitReplacements: [(pattern: String, singular: String, plural: String)] = [
            (#"(\d+)\s+days?"#, String(localized: "%d day"), String(localized: "%d days")),
            (#"(\d+)\s+hours?"#, String(localized: "%d hour"), String(localized: "%d hours")),
            (#"(\d+)\s+minutes?"#, String(localized: "%d minute"), String(localized: "%d minutes")),
            (#"(\d+)\s+seconds?"#, String(localized: "%d second"), String(localized: "%d seconds")),
            (#"(\d+)\s+weeks?"#, String(localized: "%d week"), String(localized: "%d weeks")),
            (#"(\d+)\s+months?"#, String(localized: "%d month"), String(localized: "%d months"))
        ]

        for replacement in unitReplacements {
            guard let regex = try? NSRegularExpression(pattern: replacement.pattern, options: [.caseInsensitive]) else {
                continue
            }

            let nsrange = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: nsrange).reversed()

            for match in matches {
                guard
                    match.numberOfRanges > 1,
                    let fullRange = Range(match.range(at: 0), in: text),
                    let countRange = Range(match.range(at: 1), in: text),
                    let count = Int(text[countRange])
                else {
                    continue
                }

                let format = count == 1 ? replacement.singular : replacement.plural
                let localized = String(format: format, locale: Locale.current, count)
                text.replaceSubrange(fullRange, with: localized)
            }
        }

        return text
    }

    var dockhandStateRank: Int {
        switch normalizedDockhandState {
        case "running":
            return 0
        case "restarting":
            return 1
        case "paused":
            return 2
        case "created":
            return 3
        case "exited", "stopped":
            return 4
        case "dead":
            return 5
        case "removing":
            return 6
        default:
            return 7
        }
    }
}

enum DockhandStateFilter: Hashable {
    case all
    case state(String)

    var title: String {
        switch self {
        case .all:
            return String(localized: "All states")
        case .state(let state):
            return state.localizedDockhandStateLabel
        }
    }

    func matches(_ state: String) -> Bool {
        switch self {
        case .all:
            return true
        case .state(let value):
            return state.normalizedDockhandState == value.normalizedDockhandState
        }
    }
}

extension Int {
    var dockhandByteCount: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .binary)
    }

    var localizedServicesCountText: String {
        let format = self == 1 ? String(localized: "%d service") : String(localized: "%d services")
        return String(format: format, locale: Locale.current, self)
    }

    var localizedContainersCountText: String {
        let format = self == 1 ? String(localized: "%d container") : String(localized: "%d containers")
        return String(format: format, locale: Locale.current, self)
    }

    var localizedCoresCountText: String {
        let format = self == 1 ? String(localized: "%d core") : String(localized: "%d cores")
        return String(format: format, locale: Locale.current, self)
    }
}

extension Components.Schemas.Environment {
    var hostSummary: String {
        if connectionType == "socket" {
            return socketPath
        }
        if let host, !host.isEmpty {
            return "\(host):\(port)"
        }
        return socketPath
    }

    var metadataChips: [String] {
        var values = [hostSummary]
        values.append(connectionType.replacingOccurrences(of: "-", with: " "))
        if let publicIp, !publicIp.isEmpty {
            values.append(publicIp)
        }
        if let timezone, !timezone.isEmpty {
            values.append(timezone)
        }
        return values
    }
}

extension Components.Schemas.Container {
    private var runtimeState: DockhandRuntimeState {
        DockhandRuntimeState(rawState: state)
    }

    func canPerform(_ action: ContainerAction) -> Bool {
        switch (action, runtimeState) {
        case (.start, .running), (.start, .restarting):
            return false
        case (.start, _):
            return true
        case (.stop, .running), (.stop, .paused), (.stop, .restarting):
            return true
        case (.stop, _):
            return false
        case (.restart, .running), (.restart, .paused), (.restart, .restarting):
            return true
        case (.restart, _):
            return false
        case (.pause, .running):
            return true
        case (.pause, _):
            return false
        case (.unpause, .paused):
            return true
        case (.unpause, _):
            return false
        }
    }

    var canOpenShell: Bool {
        state.normalizedDockhandState == "running"
    }

    var primaryPortLabel: String {
        let labels: [String] = ports.compactMap { (port: Components.Schemas.ContainerPort) -> String? in
                guard let publicPort = port.publicPort else { return nil }
                return "\(publicPort):\(port.privatePort)"
            }
        return labels.first ?? String(localized: "No ports")
    }

    var networkSummary: String {
        networks.additionalProperties
            .map { key, value in
                if let ip = value.ipAddress, !ip.isEmpty {
                    return "\(key) \(ip)"
                }
                return key
            }
            .sorted()
            .joined(separator: " · ")
    }

    var stateRank: Int {
        state.dockhandStateRank
    }
}

extension Components.Schemas.StackSummary {
    var servicesCount: Int {
        containerDetails.count
    }

    var localizedStatusText: String {
        status.localizedDockhandStateLabel
    }

    private var normalizedStatus: String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var statusRank: Int {
        status.dockhandStateRank
    }

    var supportsRedeploy: Bool {
        sourceType?.lowercased() != "git"
    }

    func canPerform(_ action: StackAction) -> Bool {
        let hasActiveContainers = containerDetails.contains {
            let state = DockhandRuntimeState(rawState: $0.state)
            return state == .running || state == .paused || state == .restarting
        }

        switch action {
        case .start:
            return !hasActiveContainers && normalizedStatus != "running"
        case .stop:
            return hasActiveContainers
        case .restart:
            return hasActiveContainers
        case .down:
            return normalizedStatus == "running"
                || normalizedStatus == "stopped"
                || normalizedStatus == "exited"
        case .redeploy:
            return supportsRedeploy
        }
    }
}

extension Components.Schemas.StackContainerDetail {
    private var runtimeState: DockhandRuntimeState {
        DockhandRuntimeState(rawState: state)
    }

    func canPerform(_ action: ContainerAction) -> Bool {
        switch (action, runtimeState) {
        case (.start, .running), (.start, .restarting):
            return false
        case (.start, _):
            return true
        case (.stop, .running), (.stop, .paused), (.stop, .restarting):
            return true
        case (.stop, _):
            return false
        case (.restart, .running), (.restart, .paused), (.restart, .restarting):
            return true
        case (.restart, _):
            return false
        case (.pause, .running):
            return true
        case (.pause, _):
            return false
        case (.unpause, .paused):
            return true
        case (.unpause, _):
            return false
        }
    }

    var canOpenShell: Bool {
        state.normalizedDockhandState == "running"
    }

    var primaryPortLabel: String {
        let labels = ports.compactMap { port -> String? in
            if let display = port.display, !display.isEmpty {
                return display
            }
            guard let publicPort = port.publicPort, let privatePort = port.privatePort else {
                return nil
            }
                return "\(publicPort):\(privatePort)"
        }
        return labels.first ?? String(localized: "No ports")
    }

    var networkSummary: String {
        networks.compactMap { network in
            guard let name = network.name, !name.isEmpty else { return nil }
            if let ipAddress = network.ipAddress, !ipAddress.isEmpty {
                return "\(name) \(ipAddress)"
            }
            return name
        }
        .sorted()
        .joined(separator: " · ")
    }

    var localizedStatusText: String {
        status.localizedDockerRuntimeText
    }
}

extension Components.Schemas.ImageSummary {
    var displayName: String {
        repoTags?.first ?? tags?.first ?? id
    }

    var shortID: String {
        id.replacingOccurrences(of: "sha256:", with: "").prefix(12).description
    }

    var createdAtText: String {
        Date(timeIntervalSince1970: TimeInterval(created))
            .formatted(date: .abbreviated, time: .shortened)
    }

    var isUnused: Bool {
        containers == 0
    }

    var labelPairs: [(key: String, value: String)] {
        (labels?.additionalProperties ?? [:])
            .map { ($0.key, $0.value) }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    var allTags: [String] {
        (repoTags ?? tags ?? []).sorted()
    }

    var allDigests: [String] {
        (repoDigests ?? []).sorted()
    }

    var repositoryKey: String {
        if let reference = allTags.first {
            return reference.dockhandRepositoryName
        }
        if let digest = allDigests.first,
           let atIndex = digest.firstIndex(of: "@") {
            return String(digest[..<atIndex])
        }
        return id
    }
}

private extension String {
    var dockhandRepositoryName: String {
        let slashIndex = lastIndex(of: "/")
        let colonIndex = lastIndex(of: ":")
        if let colonIndex,
           slashIndex.map({ colonIndex > $0 }) ?? true {
            return String(prefix(upTo: colonIndex))
        }
        return self
    }
}
