import DockhandAPI
import Observation
import SwiftUI

@MainActor
@Observable
final class StacksStore {
    var stacks: [Components.Schemas.StackSummary] = []
    var isLoading = false
    var error: String?
    var actionMessage: String?
    var activeStackActionID: String?
    var activeContainerActionID: String?

    func load(appModel: AppModel) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else {
            stacks = []
            return
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            stacks = try await service.fetchStacks(environmentID: environmentID)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func run(_ action: StackAction, stack: Components.Schemas.StackSummary, appModel: AppModel) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else { return }

        activeStackActionID = stackActionID(for: action, stackName: stack.name)
        error = nil
        defer { activeStackActionID = nil }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            try await service.stackAction(action, stackName: stack.name, environmentID: environmentID)
            actionMessage = "\(stack.name) \(action.rawValue) requested"
            await load(appModel: appModel)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func run(_ action: ContainerAction, container: Components.Schemas.StackContainerDetail, appModel: AppModel) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else { return }

        activeContainerActionID = containerActionID(for: action, containerID: container.id)
        error = nil
        defer { activeContainerActionID = nil }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            try await service.containerAction(action, containerID: container.id, environmentID: environmentID)
            actionMessage = "\(container.name) \(action.rawValue)d"
            await load(appModel: appModel)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stack(named name: String) -> Components.Schemas.StackSummary? {
        stacks.first(where: { $0.name == name })
    }

    func isRunning(_ action: StackAction, stackName: String) -> Bool {
        activeStackActionID == stackActionID(for: action, stackName: stackName)
    }

    func isRunning(_ action: ContainerAction, containerID: String) -> Bool {
        activeContainerActionID == containerActionID(for: action, containerID: containerID)
    }

    var hasPendingAction: Bool {
        activeStackActionID != nil || activeContainerActionID != nil
    }

    private func stackActionID(for action: StackAction, stackName: String) -> String {
        "\(stackName):\(action.rawValue)"
    }

    private func containerActionID(for action: ContainerAction, containerID: String) -> String {
        "\(containerID):\(action.rawValue)"
    }
}

struct StacksView: View {
    let appModel: AppModel
    @State private var store = StacksStore()

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

            Section("Stacks") {
                ForEach(store.stacks, id: \.name) { stack in
                    NavigationLink {
                        StackEditorView(appModel: appModel, stack: stack, store: store)
                    } label: {
                        StackRow(stack: stack)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Stacks")
        .overlay {
            if store.isLoading && store.stacks.isEmpty {
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

private struct StackRow: View {
    let stack: Components.Schemas.StackSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(stack.name)
                    .font(.headline)
                Spacer()
                Text(stack.status.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(stack.status == "running" ? .green : .secondary)
            }
            Text("\(stack.servicesCount) services")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct StackEditorView: View {
    let appModel: AppModel
    let stack: Components.Schemas.StackSummary
    let store: StacksStore

    @State private var document = StackEditorDocument(composeContent: "", envContent: "", composePath: nil, envPath: nil, suggestedEnvPath: nil, needsFileLocation: false, noEnvFile: false, composeError: nil)
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var saveMessage: String?
    @State private var saveMessageIsError = false
    @State private var activePane: EditorPane = .compose

    private var liveStack: Components.Schemas.StackSummary {
        store.stack(named: stack.name) ?? stack
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(liveStack.name)
                        .font(.title2.weight(.semibold))
                    Text(liveStack.status)
                        .foregroundStyle(.secondary)
                    if let composePath = document.composePath, !composePath.isEmpty {
                        Text(composePath)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(20)
                .glassEffect(.regular.tint(.white.opacity(0.03)), in: .rect(cornerRadius: 24))

                actionBar
                containersCard
                editorCard
            }
            .padding()
        }
        .navigationTitle(liveStack.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: appModel.connectionScopeID) {
            await loadDocument()
        }
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Stack actions")
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
                stackActionButton(.start, "play.fill", "Start")
                stackActionButton(.stop, "stop.fill", "Stop")
                stackActionButton(.restart, "arrow.clockwise", "Restart")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 24))
    }

    private var containersCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Containers")
                    .font(.headline)
                Spacer()
                Text("\(liveStack.servicesCount) services")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if liveStack.containerDetails.isEmpty {
                Text("No containers in this stack")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(liveStack.containerDetails, id: \.id) { container in
                    StackContainerCard(container: container, appModel: appModel, store: store)
                }
            }
        }
        .padding(20)
        .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 24))
    }

    @ViewBuilder
    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Picker("Pane", selection: $activePane) {
                    ForEach(EditorPane.allCases) { pane in
                        Text(pane.title).tag(pane)
                    }
                }
                .pickerStyle(.segmented)

                Button {
                    Task { await saveActivePane() }
                } label: {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 22, height: 22)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(isSaving || isLoading)
            }

            if document.needsFileLocation {
                Text(document.composeError ?? "Dockhand needs the compose file location for this stack.")
                    .foregroundStyle(.red)
            }

            if let saveMessage {
                Text(saveMessage)
                    .font(.footnote)
                    .foregroundStyle(saveMessageIsError ? .red : .secondary)
            }

            if activePane == .compose {
                editorBlock(
                    title: "Compose file",
                    text: $document.composeContent,
                    kind: .yaml
                )
            } else {
                editorBlock(
                    title: "Environment file",
                    text: $document.envContent,
                    kind: .env
                )
            }
        }
        .padding(20)
        .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 24))
    }

    private func editorBlock(title: String, text: Binding<String>, kind: StackEditorSyntaxKind) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            SyntaxHighlightingTextEditor(text: text, kind: kind)
                .frame(minHeight: 380)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private func loadDocument() async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else {
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            document = try await service.fetchStackEditorDocument(name: stack.name, environmentID: environmentID)
            saveMessage = nil
            saveMessageIsError = false
        } catch {
            saveMessage = error.localizedDescription
            saveMessageIsError = true
        }
    }

    private func saveActivePane() async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else {
            return
        }

        isSaving = true
        saveMessage = nil
        saveMessageIsError = false
        defer { isSaving = false }

        do {
            if activePane == .compose {
                try StackEditorValidator.validateCompose(document.composeContent)
            } else {
                try StackEditorValidator.validateEnv(document.envContent)
            }

            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            if activePane == .compose {
                try await service.updateStackCompose(
                    name: stack.name,
                    environmentID: environmentID,
                    content: document.composeContent,
                    composePath: document.composePath,
                    envPath: document.envPath ?? document.suggestedEnvPath
                )
                saveMessage = "Compose saved"
            } else {
                try await service.updateStackEnvFile(
                    name: stack.name,
                    environmentID: environmentID,
                    content: document.envContent
                )
                saveMessage = document.envContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ".env removed" : ".env saved"
            }
            saveMessageIsError = false
            await store.load(appModel: appModel)
        } catch {
            saveMessage = error.localizedDescription
            saveMessageIsError = true
        }
    }

    private func runStackAction(_ action: StackAction) async {
        await store.run(action, stack: liveStack, appModel: appModel)
        saveMessage = store.error
        saveMessageIsError = store.error != nil
    }

    private func stackActionButton(_ action: StackAction, _ icon: String, _ title: String) -> some View {
        Button {
            Task { await runStackAction(action) }
        } label: {
            VStack(spacing: 8) {
                if store.isRunning(action, stackName: liveStack.name) {
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
        .disabled(store.hasPendingAction)
    }
}

private struct StackContainerCard: View {
    let container: Components.Schemas.StackContainerDetail
    let appModel: AppModel
    let store: StacksStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(container.name)
                        .font(.headline)
                    Text(container.service)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(container.state.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(container.state == "running" ? .green : .secondary)
            }

            Text(container.image)
                .font(.footnote)
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
            .lineLimit(2)

            Text(container.status)
                .font(.footnote)
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                spacing: 8
            ) {
                stackContainerActionButton(.start, "play.fill", "Start")
                stackContainerActionButton(.stop, "stop.fill", "Stop")
                stackContainerActionButton(.restart, "arrow.clockwise", "Restart")
                stackContainerActionButton(.pause, "pause.fill", "Pause")
                stackContainerActionButton(.unpause, "playpause.fill", "Resume")
            }

            NavigationLink {
                ContainerLogsView(
                    target: .init(id: container.id, name: container.name),
                    appModel: appModel
                )
            } label: {
                Label("Logs", systemImage: "text.alignleft")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.glass)
        }
        .padding(16)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
    }

    private func stackContainerActionButton(_ action: ContainerAction, _ icon: String, _ title: String) -> some View {
        Button {
            Task {
                await store.run(action, container: container, appModel: appModel)
            }
        } label: {
            VStack(spacing: 6) {
                if store.isRunning(action, containerID: container.id) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(height: 18)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .frame(height: 18)
                }

                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
        }
        .buttonStyle(.glass)
        .disabled(store.hasPendingAction)
    }
}

private enum EditorPane: String, CaseIterable, Identifiable {
    case compose
    case env

    var id: String { rawValue }
    var title: String { self == .compose ? "Compose" : ".env" }
}
