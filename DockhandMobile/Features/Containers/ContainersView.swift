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

    func container(id: String) -> Components.Schemas.Container? {
        containers.first(where: { $0.id == id })
    }

    private func actionID(for action: ContainerAction, containerID: String) -> String {
        "\(containerID):\(action.rawValue)"
    }
}

struct ContainersView: View {
    let appModel: AppModel
    @State private var store = ContainersStore()
    @State private var sort = ContainerListSort.name
    @State private var stateFilter = DockhandStateFilter.all

    private var filteredContainers: [Components.Schemas.Container] {
        let filtered = store.containers.filter { stateFilter.matches($0.state) }
        switch sort {
        case .name:
            return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .state:
            return filtered.sorted {
                if $0.stateRank == $1.stateRank {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.stateRank < $1.stateRank
            }
        }
    }

    private var availableStates: [String] {
        Array(Set(store.containers.map(\.state.normalizedDockhandState)))
            .sorted {
                let lhsRank = $0.dockhandStateRank
                let rhsRank = $1.dockhandStateRank
                if lhsRank == rhsRank { return $0 < $1 }
                return lhsRank < rhsRank
            }
    }

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
                if filteredContainers.isEmpty {
                    Text(stateFilter == .all ? "No containers" : "No containers in \(stateFilter.title)")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredContainers, id: \.id) { container in
                        NavigationLink {
                            ContainerDetailView(
                                container: container,
                                scope: appModel.connectionScope,
                                appModel: appModel,
                                store: store
                            )
                        } label: {
                            ContainerRow(container: container)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Containers")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("Sort") {
                        ForEach(ContainerListSort.allCases) { option in
                            Button {
                                sort = option
                            } label: {
                                selectionLabel(option.title, isSelected: sort == option)
                            }
                        }
                    }

                    Section("Filter") {
                        Button {
                            stateFilter = .all
                        } label: {
                            selectionLabel("All states", isSelected: stateFilter == .all)
                        }

                        ForEach(availableStates, id: \.self) { state in
                            Button {
                                stateFilter = DockhandStateFilter.state(state)
                            } label: {
                                selectionLabel(state.capitalized, isSelected: stateFilter == DockhandStateFilter.state(state))
                            }
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
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

    @ViewBuilder
    private func selectionLabel(_ title: String, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 12)
            if isSelected {
                Image(systemName: "checkmark")
            }
        }
    }
}

private enum ContainerListSort: String, CaseIterable, Identifiable {
    case name
    case state

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "Name"
        case .state: return "State"
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
    let scope: DockhandConnectionScope
    let appModel: AppModel
    let store: ContainersStore
    @Environment(\.colorScheme) private var colorScheme

    private var isCurrentScope: Bool {
        appModel.isCurrentScope(scope)
    }

    private var liveContainer: Components.Schemas.Container {
        isCurrentScope ? (store.container(id: container.id) ?? container) : container
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(liveContainer.name)
                        .font(.title2.weight(.semibold))
                    Text(liveContainer.image)
                        .foregroundStyle(.secondary)
                    Text(liveContainer.status)
                        .font(.subheadline)
                }
                .padding(20)
                .glassEffect(.regular.tint(.white.opacity(0.03)), in: .rect(cornerRadius: 24))

                if !isCurrentScope {
                    staleScopeWarning
                }

                actionBar
                quickLinks

                detailsBlock("Networks", liveContainer.networkSummary.isEmpty ? "No networks" : liveContainer.networkSummary)
                detailsBlock("Command", liveContainer.command ?? "No command")
                detailsBlock("System Container", liveContainer.systemContainer ?? "No")
            }
            .padding()
        }
        .navigationTitle(liveContainer.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var staleScopeWarning: some View {
        Text("Server or environment changed. Go back and reopen this container before running actions.")
            .font(.footnote)
            .foregroundStyle(.orange)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(.orange.opacity(0.08)), in: .rect(cornerRadius: 18))
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

    private var quickLinks: some View {
        VStack(spacing: 10) {
            NavigationLink {
                ContainerShellView(
                    target: .init(id: liveContainer.id, name: liveContainer.name),
                    scope: scope,
                    appModel: appModel
                )
            } label: {
                Label("Open Shell", systemImage: "terminal")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 24))
            }
            .buttonStyle(.plain)
            .disabled(!isCurrentScope || !liveContainer.canOpenShell)

            NavigationLink {
                ContainerLogsView(
                    target: .init(id: liveContainer.id, name: liveContainer.name),
                    scope: scope,
                    appModel: appModel
                )
            } label: {
                Label("View Logs", systemImage: "text.alignleft")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 24))
            }
            .buttonStyle(.plain)
            .disabled(!isCurrentScope)
        }
    }

    private func actionButton(_ action: ContainerAction, _ icon: String, _ title: String) -> some View {
        let isEnabled = isCurrentScope && liveContainer.canPerform(action) && store.activeActionID == nil

        return Button {
            guard isCurrentScope else { return }
            Task {
                await store.run(action, container: liveContainer, appModel: appModel)
            }
        } label: {
            VStack(spacing: 6) {
                if store.isRunning(action, containerID: liveContainer.id) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(height: 18)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(height: 18)
                }

                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .opacity(isEnabled ? 1 : (colorScheme == .dark ? 0.82 : 0.97))
        }
        .buttonStyle(.glass)
        .disabled(!isEnabled)
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
