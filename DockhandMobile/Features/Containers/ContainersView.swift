import DockhandAPI
import Observation
import SwiftUI

@MainActor
@Observable
final class ContainersStore {
    var containers: [Components.Schemas.Container] = []
    var isLoading = false
    var error: String?
    var actionMessage: String?
    var activeActionID: String?

    func load(appModel: AppModel) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else {
            containers = []
            return
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            containers = try await service.fetchContainers(environmentID: environmentID)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func run(_ action: ContainerAction, container: Components.Schemas.Container, appModel: AppModel) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else { return }

        activeActionID = actionID(for: action, containerID: container.id)
        error = nil
        defer { activeActionID = nil }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            try await service.containerAction(action, containerID: container.id, environmentID: environmentID)
            actionMessage = "\(container.name) \(action.rawValue)d"
            await load(appModel: appModel)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func isRunning(_ action: ContainerAction, containerID: String) -> Bool {
        activeActionID == actionID(for: action, containerID: containerID)
    }

    private func actionID(for action: ContainerAction, containerID: String) -> String {
        "\(containerID):\(action.rawValue)"
    }
}

struct ContainersView: View {
    let appModel: AppModel
    @State private var store = ContainersStore()

    var body: some View {
        List {
            Section {
                EnvironmentHeaderBar(appModel: appModel)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if let error = store.error {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }

            Section("Containers") {
                ForEach(store.containers, id: \.id) { container in
                    NavigationLink {
                        ContainerDetailView(container: container, appModel: appModel, store: store)
                    } label: {
                        ContainerRow(container: container)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Containers")
        .overlay {
            if store.isLoading && store.containers.isEmpty {
                ProgressView()
            }
        }
        .task(id: appModel.connectionScopeID) {
            await store.load(appModel: appModel)
        }
        .refreshable {
            await store.load(appModel: appModel)
        }
    }
}

private struct ContainerRow: View {
    let container: Components.Schemas.Container

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(container.name)
                    .font(.headline)
                Spacer()
                Text(container.state.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(container.state == "running" ? .green : .secondary)
            }
            Text(container.image)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack {
                Text(container.primaryPortLabel)
                if !container.networkSummary.isEmpty {
                    Text(container.networkSummary)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

private struct ContainerDetailView: View {
    let container: Components.Schemas.Container
    let appModel: AppModel
    let store: ContainersStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(container.name)
                        .font(.title2.weight(.semibold))
                    Text(container.image)
                        .foregroundStyle(.secondary)
                    Text(container.status)
                        .font(.subheadline)
                }
                .padding(20)
                .glassEffect(.regular.tint(.white.opacity(0.03)), in: .rect(cornerRadius: 24))

                actionBar
                logsLink

                detailsBlock("Networks", container.networkSummary.isEmpty ? "No networks" : container.networkSummary)
                detailsBlock("Command", container.command ?? "No command")
                detailsBlock("System Container", container.systemContainer ?? "No")
            }
            .padding()
        }
        .navigationTitle(container.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Actions")
                    .font(.headline)
                Spacer()
                if let actionMessage = store.actionMessage {
                    Text(actionMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                spacing: 10
            ) {
                actionButton(.start, "play.fill", "Start")
                actionButton(.stop, "stop.fill", "Stop")
                actionButton(.restart, "arrow.clockwise", "Restart")
                actionButton(.pause, "pause.fill", "Pause")
                actionButton(.unpause, "playpause.fill", "Resume")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 24))
    }

    private var logsLink: some View {
        NavigationLink {
            ContainerLogsView(
                target: .init(id: container.id, name: container.name),
                appModel: appModel
            )
        } label: {
            Label("View Logs", systemImage: "text.alignleft")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }

    private func actionButton(_ action: ContainerAction, _ icon: String, _ title: String) -> some View {
        Button {
            Task {
                await store.run(action, container: container, appModel: appModel)
            }
        } label: {
            VStack(spacing: 8) {
                if store.isRunning(action, containerID: container.id) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(height: 18)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(height: 18)
                }

                Text(title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.glass)
        .disabled(store.activeActionID != nil)
    }

    private func detailsBlock(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 24))
    }
}
