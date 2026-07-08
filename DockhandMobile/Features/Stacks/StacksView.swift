import DockhandAPI
import SwiftUI

struct StacksView: View {
    let appModel: AppModel
    @State private var store = StacksStore()
    @State private var sort = StackListSort.name
    @State private var stateFilter = DockhandStateFilter.all

    private var filteredStacks: [Components.Schemas.StackSummary] {
        let filtered = store.stacks.filter { stateFilter.matches($0.status) }
        switch sort {
        case .name:
            return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .state:
            return filtered.sorted {
                if $0.statusRank == $1.statusRank {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.statusRank < $1.statusRank
            }
        }
    }

    private var availableStates: [String] {
        Array(Set(store.stacks.map(\.status.normalizedDockhandState)))
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

            Section("Stacks") {
                if filteredStacks.isEmpty {
                    Text(
                        stateFilter == .all
                            ? String(localized: "No stacks")
                            : String(format: String(localized: "No stacks in %@"), locale: Locale.current, stateFilter.title)
                    )
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredStacks, id: \.name) { stack in
                        NavigationLink {
                            StackEditorView(
                                appModel: appModel,
                                stack: stack,
                                scope: appModel.connectionScope,
                                store: store
                            )
                        } label: {
                            StackRow(stack: stack)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Stacks")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("Sort") {
                        ForEach(StackListSort.allCases) { option in
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
                            selectionLabel(String(localized: "All states"), isSelected: stateFilter == .all)
                        }

                        ForEach(availableStates, id: \.self) { state in
                        Button {
                            stateFilter = DockhandStateFilter.state(state)
                        } label: {
                            selectionLabel(state.localizedDockhandStateLabel, isSelected: stateFilter == DockhandStateFilter.state(state))
                        }
                    }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
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

private enum StackListSort: String, CaseIterable, Identifiable {
    case name
    case state

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return String(localized: "Name")
        case .state: return String(localized: "State")
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
                Text(stack.localizedStatusText.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(stack.status == "running" ? .green : .secondary)
            }
            Text(stack.servicesCount.localizedServicesCountText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct StackEditorView: View {
    let appModel: AppModel
    let stack: Components.Schemas.StackSummary
    let scope: DockhandConnectionScope
    let store: StacksStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var document = StackEditorDocument(composeContent: "", envContent: "", composePath: nil, envPath: nil, suggestedEnvPath: nil, needsFileLocation: false, noEnvFile: false, composeError: nil)
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var saveMessage: String?
    @State private var saveMessageIsError = false
    @State private var activePane: EditorPane = .compose
    @State private var showsRedeploySheet = false
    @State private var showsDownConfirmation = false
    @State private var showsDeleteConfirmation = false
    @State private var deployOptions = StackDeployOptions()
    @State private var isEditorFocused = false

    private var liveStack: Components.Schemas.StackSummary {
        isCurrentScope ? (store.stack(named: stack.name) ?? stack) : stack
    }

    private var isCurrentScope: Bool {
        appModel.isCurrentScope(scope)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(liveStack.name)
                        .font(.title2.weight(.semibold))
                    Text(liveStack.localizedStatusText)
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

                if !isCurrentScope {
                    staleScopeWarning
                }

                actionBar
                containersCard
                editorCard
            }
            .padding()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isEditorFocused = false
        }
        .navigationTitle(liveStack.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(scope.profileID ?? "none"):\(scope.environmentID ?? -1):\(stack.name)") {
            await loadDocument()
        }
        .sheet(isPresented: $showsRedeploySheet) {
            StackRedeploySheet(
                options: $deployOptions,
                isRunning: store.isRunning(.redeploy, stackName: liveStack.name)
            ) {
                showsRedeploySheet = false
                Task { await runRedeploy() }
            }
            .presentationDetents([.height(380)])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog("Bring stack down", isPresented: $showsDownConfirmation, titleVisibility: .visible) {
            Button("Down stack", role: .destructive) {
                Task { await runStackAction(.down) }
            }
        } message: {
            Text("This stops and removes the containers created by this stack in the selected environment.")
        }
        .confirmationDialog("Delete stack", isPresented: $showsDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete stack", role: .destructive) {
                Task { await deleteStack(deleteVolumes: false) }
            }
            Button("Delete stack and volumes", role: .destructive) {
                Task { await deleteStack(deleteVolumes: true) }
            }
        } message: {
            Text("This removes the stack from the selected Dockhand environment. Deleting volumes also removes attached persistent data.")
        }
    }

    private var staleScopeWarning: some View {
        Text("Server or environment changed. Go back and reopen this stack before saving or running actions.")
            .font(.footnote)
            .foregroundStyle(.orange)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(.orange.opacity(0.08)), in: .rect(cornerRadius: 18))
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Stack actions")
                    .font(.headline)
                Spacer()
                if let actionMessage = store.actionMessage(for: liveStack.name) {
                    Text(actionMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                spacing: 10
            ) {
                stackActionButton(.start, "play.fill", String(localized: "Start"))
                stackActionButton(.stop, "stop.fill", String(localized: "Stop"))
                stackActionButton(.restart, "arrow.clockwise", String(localized: "Restart"))
                stackActionButton(.down, "arrow.down.to.line.compact", String(localized: "Down"))
                if liveStack.supportsRedeploy {
                    redeployButton
                }
                deleteButton
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
                Text(liveStack.servicesCount.localizedServicesCountText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if liveStack.containerDetails.isEmpty {
                Text("No containers in this stack")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(liveStack.containerDetails, id: \.id) { container in
                    StackContainerCard(
                        container: container,
                        stackName: liveStack.name,
                        scope: scope,
                        isCurrentScope: isCurrentScope,
                        appModel: appModel,
                        store: store
                    )
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
                        VStack(spacing: 2) {                            
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 16, weight: .semibold))
                               
                            Text("Save")
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(!isCurrentScope || isSaving || isLoading)
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
                    title: String(localized: "Compose file"),
                    text: $document.composeContent,
                    kind: .yaml
                )
            } else {
                editorBlock(
                    title: String(localized: "Environment file"),
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
            SyntaxHighlightingTextEditor(text: text, isFocused: $isEditorFocused, kind: kind)
                .frame(minHeight: 380)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private func loadDocument() async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id,
              isCurrentScope else {
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
            guard !error.isDockhandCancellation else { return }
            saveMessage = error.dockhandUserFacingMessage
            saveMessageIsError = true
        }
    }

    private func saveActivePane() async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id,
              isCurrentScope else {
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
                saveMessage = String(localized: "Compose saved")
            } else {
                try await service.updateStackEnvFile(
                    name: stack.name,
                    environmentID: environmentID,
                    content: document.envContent
                )
                saveMessage = document.envContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? String(localized: ".env removed")
                    : String(localized: ".env saved")
            }
            saveMessageIsError = false
            await store.load(appModel: appModel)
        } catch {
            guard !error.isDockhandCancellation else { return }
            saveMessage = error.dockhandUserFacingMessage
            saveMessageIsError = true
        }
    }

    private func runStackAction(_ action: StackAction) async {
        guard isCurrentScope else { return }
        await store.run(action, stack: liveStack, appModel: appModel)
        saveMessage = store.error
        saveMessageIsError = store.error != nil
    }

    private func runRedeploy() async {
        guard isCurrentScope else { return }
        await store.redeploy(stack: liveStack, appModel: appModel, options: deployOptions)
        saveMessage = store.error
        saveMessageIsError = store.error != nil
    }

    private func deleteStack(deleteVolumes: Bool) async {
        guard isCurrentScope else { return }
        let didDelete = await store.deleteStack(liveStack, appModel: appModel, deleteVolumes: deleteVolumes)
        saveMessage = store.error
        saveMessageIsError = store.error != nil
        if didDelete {
            dismiss()
        }
    }

    private func stackActionButton(_ action: StackAction, _ icon: String, _ title: String) -> some View {
        let isEnabled = isCurrentScope && liveStack.canPerform(action) && !store.hasPendingAction

        return Button {
            if action == .down {
                showsDownConfirmation = true
            } else {
                Task { await runStackAction(action) }
            }
        } label: {
            VStack(spacing: 6) {
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

    private var redeployButton: some View {
        let isEnabled = isCurrentScope && liveStack.canPerform(.redeploy) && !store.hasPendingAction

        return Button {
            showsRedeploySheet = true
        } label: {
            VStack(spacing: 6) {
                if store.isRunning(.redeploy, stackName: liveStack.name) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(height: 18)
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(height: 18)
                }

                Text("Redeploy")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .opacity(isEnabled ? 1 : (colorScheme == .dark ? 0.82 : 0.97))
        }
        .buttonStyle(.glassProminent)
        .disabled(!isEnabled)
    }

    private var deleteButton: some View {
        let isEnabled = isCurrentScope && !store.hasPendingAction

        return Button {
            showsDeleteConfirmation = true
        } label: {
            VStack(spacing: 6) {
                if store.isDeletingStack(liveStack.name) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(height: 18)
                } else {
                    Image(systemName: "trash")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(height: 18)
                }

                Text("Delete")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .opacity(isEnabled ? 1 : (colorScheme == .dark ? 0.82 : 0.97))
        }
        .buttonStyle(.glass)
        .tint(.red)
        .disabled(!isEnabled)
    }
}

private struct StackContainerCard: View {
    let container: Components.Schemas.StackContainerDetail
    let stackName: String
    let scope: DockhandConnectionScope
    let isCurrentScope: Bool
    let appModel: AppModel
    let store: StacksStore
    @Environment(\.colorScheme) private var colorScheme

    private var environmentForPorts: Components.Schemas.Environment? {
        appModel.environment(for: scope)
    }

    private var portAccesses: [PublishedPortAccess] {
        container.publishedPortAccesses(in: environmentForPorts)
    }

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

                Text(container.state.localizedDockhandStateLabel.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(container.state == "running" ? .green : .secondary)
            }

            Text(container.image)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            ExposedPortsGrid(
                accesses: portAccesses,
                emptyText: String(localized: "No ports"),
                minimumItemWidth: 104
            )

            if !container.networkSummary.isEmpty {
                Text(container.networkSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Text(container.status.localizedDockhandStateLabel)
                .font(.footnote)
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                spacing: 8
            ) {
                stackContainerActionButton(.start, "play.fill", String(localized: "Start"))
                stackContainerActionButton(.stop, "stop.fill", String(localized: "Stop"))
                stackContainerActionButton(.restart, "arrow.clockwise", String(localized: "Restart"))
                stackContainerActionButton(.pause, "pause.fill", String(localized: "Pause"))
                stackContainerActionButton(.unpause, "playpause.fill", String(localized: "Resume"))
            }

            HStack(spacing: 10) {
                NavigationLink {
                    ContainerShellView(
                        target: .init(id: container.id, name: container.name),
                        scope: scope,
                        appModel: appModel
                    )
                } label: {
                    Label("Shell", systemImage: "terminal")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                        .contentShape(.rect)
                }
                .buttonStyle(.glass)
                .frame(maxWidth: .infinity)
                .disabled(!isCurrentScope || !container.canOpenShell)

                NavigationLink {
                    ContainerLogsView(
                        target: .init(id: container.id, name: container.name),
                        scope: scope,
                        appModel: appModel
                    )
                } label: {
                    Label("Logs", systemImage: "text.alignleft")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                        .contentShape(.rect)
                }
                .buttonStyle(.glass)
                .frame(maxWidth: .infinity)
                .disabled(!isCurrentScope)
            }
        }
        .padding(16)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
    }

    private func stackContainerActionButton(_ action: ContainerAction, _ icon: String, _ title: String) -> some View {
        let isEnabled = isCurrentScope && container.canPerform(action) && !store.hasPendingAction

        return Button {
            guard isCurrentScope else { return }
            Task {
                await store.run(action, container: container, stackName: stackName, appModel: appModel)
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
            .opacity(isEnabled ? 1 : (colorScheme == .dark ? 0.82 : 0.97))
        }
        .buttonStyle(.glass)
        .disabled(!isEnabled)
    }
}

private struct StackRedeploySheet: View {
    @Binding var options: StackDeployOptions
    let isRunning: Bool
    let onDeploy: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Redeploy stack")
                        .font(.title3.weight(.semibold))
                    Text("Choose how Dockhand should redeploy this compose stack.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 12) {
                    Toggle("Pull images", isOn: $options.pull)
                    Toggle("Build images", isOn: $options.build)
                    Toggle("Force recreate", isOn: $options.forceRecreate)
                }
                .toggleStyle(.switch)
                .padding(18)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))

                Button {
                    dismiss()
                    onDeploy()
                } label: {
                    if isRunning {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Deploy", systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(isRunning)

                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Redeploy")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private enum EditorPane: String, CaseIterable, Identifiable {
    case compose
    case env

    var id: String { rawValue }
    var title: String { self == .compose ? String(localized: "Compose") : ".env" }
}
