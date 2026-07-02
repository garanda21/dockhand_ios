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

    func run(target: ContainerLogTarget, appModel: AppModel) async {
        if follow {
            await stream(target: target, appModel: appModel)
        } else {
            await loadSnapshot(target: target, appModel: appModel)
        }
    }

    func loadSnapshot(target: ContainerLogTarget, appModel: AppModel) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else {
            replaceLogs("")
            return
        }

        isLoading = true
        error = nil
        streamStatus = String(localized: "Loading")
        defer { isLoading = false }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            let loadedDocument = try await service.fetchContainerLogs(
                containerID: target.id,
                environmentID: environmentID,
                tail: tail
            )
            replaceLogs(loadedDocument.logs)
            streamStatus = String(localized: "Snapshot")
        } catch {
            self.error = error.localizedDescription
            streamStatus = String(localized: "Error")
        }
    }

    func stream(target: ContainerLogTarget, appModel: AppModel) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else {
            replaceLogs("")
            return
        }

        isLoading = true
        error = nil
        replaceLogs("")
        streamStatus = String(localized: "Connecting")
        defer { isLoading = false }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            try await service.streamContainerLogs(
                containerID: target.id,
                environmentID: environmentID,
                tail: tail
            ) { [weak self] event in
                guard let self else { return }
                await MainActor.run {
                    switch event {
                    case .connected:
                        self.streamStatus = String(localized: "Live")
                    case .log(let line):
                        self.prependLiveLog(line)
                    }
                }
            }
        } catch is CancellationError {
            streamStatus = String(localized: "Stopped")
        } catch {
            self.error = error.localizedDescription
            streamStatus = String(localized: "Error")
        }
    }

    private func replaceLogs(_ logs: String) {
        document = ContainerLogsDocument(logs: logs)
        formattedLogs = ContainerLogFormatter.make(from: logs, latestFirst: false)
    }

    private func prependLiveLog(_ log: String) {
        let separator = log.hasSuffix("\n") ? "" : "\n"
        document.logs = log + separator + document.logs

        let maxLength = 200_000
        if document.logs.count > maxLength {
            document.logs = String(document.logs.prefix(maxLength))
        }

        formattedLogs = ContainerLogFormatter.make(from: document.logs, latestFirst: true)
    }
}

struct ContainerLogsView: View {
    let target: ContainerLogTarget
    let scope: DockhandConnectionScope
    let appModel: AppModel

    @State private var store = ContainerLogsStore()

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
            guard isCurrentScope else {
                store.streamStatus = String(localized: "Context changed")
                return
            }
            await store.run(target: target, appModel: appModel)
        }
        .refreshable {
            guard isCurrentScope else { return }
            await store.run(target: target, appModel: appModel)
        }
    }

    private var taskKey: String {
        "\(target.id)-\(scope.profileID ?? "none")-\(scope.environmentID ?? -1)-\(appModel.connectionScopeID)-\(store.tail)-\(store.follow)"
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
                    Task { await store.run(target: target, appModel: appModel) }
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

private enum ContainerLogFormatter {
    static func make(from rawLogs: String, latestFirst: Bool) -> AttributedString {
        let orderedLines = latestFirst
            ? rawLogs
            : rawLogs
                .components(separatedBy: .newlines)
                .reversed()
                .joined(separator: "\n")

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
}
