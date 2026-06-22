import DockhandAPI
import Foundation

extension Int {
    var dockhandByteCount: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .binary)
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
    var primaryPortLabel: String {
        let labels: [String] = ports.compactMap { (port: Components.Schemas.ContainerPort) -> String? in
                guard let publicPort = port.publicPort else { return nil }
                return "\(publicPort):\(port.privatePort)"
            }
        return labels.first ?? "No ports"
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
}

extension Components.Schemas.StackSummary {
    var servicesCount: Int {
        containerDetails.count
    }
}

extension Components.Schemas.StackContainerDetail {
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
        return labels.first ?? "No ports"
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
}
