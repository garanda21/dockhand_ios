import Foundation
import Observation
import SwiftUI

struct ContainerLogTarget: Identifiable, Hashable {
    let id: String
    let name: String
}

@MainActor
@Observable
final class ContainerLogsStore {
    var document = ContainerLogsDocument(logs: "")
    var formattedLogs = AttributedString("")
    var isLoading = false
    var error: String?
    var tail = 200
    var follow = false
    var streamStatus = String(localized: "Idle")

    private var runGeneration = 0
    private var streamHasReceivedLog = false

    func run(target: ContainerLogTarget, appModel: AppModel) async {
        runGeneration &+= 1
        let generation = runGeneration
        let selectedTail = tail
        let shouldFollow = follow

        if shouldFollow {
            // Keep a usable snapshot on screen while the long-lived stream connects.
            await loadSnapshot(
                target: target,
                appModel: appModel,
                tail: selectedTail,
                generation: generation
            )
            guard isCurrent(generation) else { return }
            await stream(
                target: target,
                appModel: appModel,
                tail: selectedTail,
                generation: generation
            )
        } else {
            await loadSnapshot(
                target: target,
                appModel: appModel,
                tail: selectedTail,
                generation: generation
            )
        }
    }

    func cancelCurrentRun() {
        runGeneration &+= 1
        isLoading = false
        streamStatus = String(localized: "Stopped")
    }

    func pauseForBackground() {
        runGeneration &+= 1
        isLoading = false
        error = nil
        streamStatus = String(localized: "Paused")
    }

    private func loadSnapshot(
        target: ContainerLogTarget,
        appModel: AppModel,
        tail: Int,
        generation: Int
    ) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else {
            if isCurrent(generation) {
                replaceLogs("")
                isLoading = false
            }
            return
        }

        isLoading = true
        error = nil
        streamStatus = String(localized: "Loading")
        defer {
            if isCurrent(generation) {
                isLoading = false
            }
        }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            let loadedDocument = try await service.fetchContainerLogs(
                containerID: target.id,
                environmentID: environmentID,
                tail: tail
            )
            guard isCurrent(generation) else { return }
            replaceLogs(loadedDocument.logs)
            streamStatus = String(localized: "Snapshot")
        } catch let loadError {
            guard isCurrent(generation) else { return }
            guard !loadError.isDockhandCancellation else {
                streamStatus = String(localized: "Stopped")
                return
            }
            error = loadError.dockhandUserFacingMessage
            streamStatus = String(localized: "Error")
        }
    }

    private func stream(
        target: ContainerLogTarget,
        appModel: AppModel,
        tail: Int,
        generation: Int
    ) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else {
            return
        }

        isLoading = true
        error = nil
        streamHasReceivedLog = false
        streamStatus = String(localized: "Connecting")
        defer {
            if isCurrent(generation) {
                isLoading = false
            }
        }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            try await service.streamContainerLogs(
                containerID: target.id,
                environmentID: environmentID,
                tail: tail
            ) { [weak self] event in
                guard let self else { return }
                await MainActor.run {
                    guard self.isCurrent(generation) else { return }
                    switch event {
                    case .connected:
                        self.isLoading = false
                        self.streamStatus = String(localized: "Live")
                    case .log(let line):
                        if !self.streamHasReceivedLog {
                            self.replaceLogs("")
                            self.streamHasReceivedLog = true
                        }
                        self.appendLiveLog(line)
                        self.isLoading = false
                        self.streamStatus = String(localized: "Live")
                    case .serverError(let message):
                        self.error = message
                        self.isLoading = false
                        self.streamStatus = String(localized: "Error")
                    case .ended:
                        self.isLoading = false
                        self.streamStatus = String(localized: "Stopped")
                    }
                }
            }
            guard isCurrent(generation), error == nil else { return }
            streamStatus = String(localized: "Stopped")
        } catch let streamError {
            guard isCurrent(generation) else { return }
            guard !streamError.isDockhandCancellation else {
                streamStatus = String(localized: "Stopped")
                return
            }
            error = streamError.dockhandUserFacingMessage
            streamStatus = String(localized: "Error")
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == runGeneration
    }

    private func replaceLogs(_ logs: String) {
        document = ContainerLogsDocument(logs: logs)
        formattedLogs = ContainerLogFormatter.make(from: logs)
    }

    private func appendLiveLog(_ log: String) {
        guard !log.isEmpty else { return }

        if !document.logs.isEmpty,
           !document.logs.hasSuffix("\n"),
           !log.hasPrefix("\n") {
            document.logs.append("\n")
        }
        document.logs.append(log)

        let maxLength = 200_000
        if document.logs.count > maxLength {
            document.logs = String(document.logs.suffix(maxLength))
        }

        formattedLogs = ContainerLogFormatter.make(from: document.logs)
    }
}

struct ContainerLogsView: View {
    let target: ContainerLogTarget
    let scope: DockhandConnectionScope
    let appModel: AppModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var store = ContainerLogsStore()
    @State private var reconnectRevision = 0

    private var isCurrentScope: Bool {
        appModel.isCurrentScope(scope)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !isCurrentScope {
                    staleScopeWarning
                }
                controlsCard
                logsCard
            }
            .padding()
        }
        .navigationTitle(target.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: taskKey) {
            guard scenePhase == .active else {
                store.pauseForBackground()
                return
            }
            guard isCurrentScope else {
                store.streamStatus = String(localized: "Context changed")
                return
            }
            await store.run(target: target, appModel: appModel)
        }
        .refreshable {
            guard isCurrentScope else { return }
            if store.follow {
                reconnectRevision &+= 1
            } else {
                await store.run(target: target, appModel: appModel)
            }
        }
        .onDisappear {
            store.cancelCurrentRun()
        }
    }

    private var taskKey: String {
        "\(target.id)-\(scope.profileID ?? "none")-\(scope.environmentID ?? -1)-\(appModel.connectionScopeID)-\(store.tail)-\(store.follow)-\(scenePhase == .active)-\(reconnectRevision)"
    }

    private var staleScopeWarning: some View {
        Text("Server or environment changed. Go back and reopen logs for the active context.")
            .font(.footnote)
            .foregroundStyle(.orange)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(.orange.opacity(0.08)), in: .rect(cornerRadius: 18))
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Logs")
                    .font(.headline)
                Spacer()
                Button {
                    guard isCurrentScope else { return }
                    reconnectRevision &+= 1
                } label: {
                    Label(store.follow ? "Reconnect" : "Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .disabled(!isCurrentScope)
            }

            Toggle(isOn: $store.follow) {
                Text("Follow")
            }
            .toggleStyle(.switch)

            Picker("Tail", selection: $store.tail) {
                Text("50").tag(50)
                Text("200").tag(200)
                Text("500").tag(500)
            }
            .pickerStyle(.segmented)

            Text(store.streamStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("Latest first")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let error = store.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 24))
    }

    private var logsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.isLoading && store.document.logs.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                if store.document.logs.isEmpty {
                    Text("No logs returned")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(store.formattedLogs)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 24))
    }

}

enum ContainerLogFormatter {
    private struct Entry {
        let timestamp: Date?
        let originalIndex: Int
        var lines: [String]
    }

    private static let leadingTimestampRegex = try? NSRegularExpression(
        pattern: #"^\[?(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z| ?[+-]\d{2}:?\d{2})?)\]?"#
    )

    static func orderedLatestFirst(from rawLogs: String) -> String {
        var lines = rawLogs.components(separatedBy: .newlines)
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }

        var entries: [Entry] = []
        for line in lines {
            if let timestamp = timestamp(in: line) {
                entries.append(
                    Entry(
                        timestamp: timestamp,
                        originalIndex: entries.count,
                        lines: [line]
                    )
                )
            } else if entries.isEmpty {
                entries.append(
                    Entry(
                        timestamp: nil,
                        originalIndex: entries.count,
                        lines: [line]
                    )
                )
            } else {
                entries[entries.count - 1].lines.append(line)
            }
        }

        guard entries.contains(where: { $0.timestamp != nil }) else {
            return lines.reversed().joined(separator: "\n")
        }

        return entries
            .sorted { lhs, rhs in
                switch (lhs.timestamp, rhs.timestamp) {
                case let (lhsTimestamp?, rhsTimestamp?):
                    if lhsTimestamp != rhsTimestamp {
                        return lhsTimestamp > rhsTimestamp
                    }
                    return lhs.originalIndex < rhs.originalIndex
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.originalIndex < rhs.originalIndex
                }
            }
            .flatMap(\.lines)
            .joined(separator: "\n")
    }

    static func make(from rawLogs: String) -> AttributedString {
        let orderedLines = orderedLatestFirst(from: rawLogs)

        let attributed = NSMutableAttributedString(
            string: orderedLines,
            attributes: [
                .foregroundColor: UIColor.secondaryLabel
            ]
        )

        let fullRange = NSRange(location: 0, length: attributed.length)
        let timestampPattern = #"(?m)^(?:\[?\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z| ?[+-]\d{2}:?\d{2})?\]?|[A-Z][a-z]{2}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})"#

        if let regex = try? NSRegularExpression(pattern: timestampPattern) {
            regex.enumerateMatches(in: orderedLines, options: [], range: fullRange) { match, _, _ in
                guard let range = match?.range, range.location != NSNotFound else { return }
                attributed.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: range)
            }
        }

        return AttributedString(attributed)
    }

    private static func timestamp(in line: String) -> Date? {
        guard let regex = leadingTimestampRegex else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges > 1,
              let timestampRange = Range(match.range(at: 1), in: line) else {
            return nil
        }

        var timestamp = String(line[timestampRange])
            .replacingOccurrences(of: ",", with: ".")

        let dateTimeSeparator = timestamp.index(timestamp.startIndex, offsetBy: 10)
        if timestamp[dateTimeSeparator] == " " {
            timestamp.replaceSubrange(dateTimeSeparator...dateTimeSeparator, with: "T")
        }
        timestamp = timestamp.replacingOccurrences(
            of: #" (?=[+-]\d{2}:?\d{2}$)"#,
            with: "",
            options: .regularExpression
        )

        if timestamp.range(of: #"[+-]\d{4}$"#, options: .regularExpression) != nil {
            timestamp.insert(":", at: timestamp.index(timestamp.endIndex, offsetBy: -2))
        }

        if timestamp.contains(".") {
            return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(timestamp)
        }
        return try? Date.ISO8601FormatStyle().parse(timestamp)
    }
}
