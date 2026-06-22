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
    var isLoading = false
    var error: String?
    var tail = 200
    var follow = false
    var streamStatus = "Idle"

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
            document = ContainerLogsDocument(logs: "")
            return
        }

        isLoading = true
        error = nil
        streamStatus = "Loading"
        defer { isLoading = false }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            document = try await service.fetchContainerLogs(
                containerID: target.id,
                environmentID: environmentID,
                tail: tail
            )
            streamStatus = "Snapshot"
        } catch {
            self.error = error.localizedDescription
            streamStatus = "Error"
        }
    }

    func stream(target: ContainerLogTarget, appModel: AppModel) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else {
            document = ContainerLogsDocument(logs: "")
            return
        }

        isLoading = true
        error = nil
        document = ContainerLogsDocument(logs: "")
        streamStatus = "Connecting"
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
                        self.streamStatus = "Live"
                    case .log(let line):
                        self.document.logs.append(line)
                    }
                }
            }
        } catch is CancellationError {
            streamStatus = "Stopped"
        } catch {
            self.error = error.localizedDescription
            streamStatus = "Error"
        }
    }
}

struct ContainerLogsView: View {
    let target: ContainerLogTarget
    let appModel: AppModel

    @State private var store = ContainerLogsStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                controlsCard
                logsCard
            }
            .padding()
        }
        .navigationTitle(target.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: taskKey) {
            await store.run(target: target, appModel: appModel)
        }
        .refreshable {
            await store.run(target: target, appModel: appModel)
        }
    }

    private var taskKey: String {
        "\(target.id)-\(appModel.connectionScopeID)-\(store.tail)-\(store.follow)"
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Logs")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await store.run(target: target, appModel: appModel) }
                } label: {
                    Label(store.follow ? "Reconnect" : "Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
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
                    Text(formattedLogs)
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

    private var formattedLogs: AttributedString {
        ContainerLogFormatter.make(from: store.document.logs)
    }
}

private enum ContainerLogFormatter {
    static func make(from rawLogs: String) -> AttributedString {
        let orderedLines = rawLogs
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
