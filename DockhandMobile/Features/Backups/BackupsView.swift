import Observation
import SwiftUI

@MainActor
@Observable
final class BackupsStore {
    /// `nil` until the first load; `false` when the server has backups disabled.
    var isAvailable: Bool?
    var configs: [BackupConfigSnapshot] = []
    var destinations: [BackupDestinationSnapshot] = []
    var testingDestinationID: Int?
    var isLoading = false
    var error: String?
    var actionMessage: String?
    var runningConfigID: Int?
    var runSteps: [String] = []

    private var loadedScopeID: String?

    func destination(id: Int) -> BackupDestinationSnapshot? {
        destinations.first { $0.id == id }
    }

    var failedCount: Int {
        configs.filter { BackupRunState(rawStatus: $0.lastBackupStatus) == .failed }.count
    }

    func load(appModel: AppModel) async {
        let scopeID = appModel.connectionScopeID
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else {
            reset()
            return
        }
        if loadedScopeID != scopeID {
            reset()
            loadedScopeID = scopeID
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let service = appModel.service(baseURL: baseURL)
            guard let loaded = try await service.fetchBackupConfigs(environmentID: environmentID) else {
                guard scopeID == appModel.connectionScopeID else { return }
                isAvailable = false
                configs = []
                return
            }
            // Destinations only label rows; a failure here must not hide the schedules.
            let loadedDestinations = (try? await service.fetchBackupDestinations(environmentID: environmentID)) ?? destinations
            guard scopeID == appModel.connectionScopeID else { return }
            isAvailable = true
            destinations = loadedDestinations.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            configs = loaded.sorted {
                $0.targetName.localizedCaseInsensitiveCompare($1.targetName) == .orderedAscending
            }
        } catch {
            guard !error.isDockhandCancellation, scopeID == appModel.connectionScopeID else { return }
            self.error = error.dockhandUserFacingMessage
        }
    }

    func run(_ config: BackupConfigSnapshot, appModel: AppModel) async {
        guard runningConfigID == nil,
              let baseURL = appModel.normalizedBaseURL else { return }
        let scopeID = appModel.connectionScopeID

        runningConfigID = config.id
        runSteps = [String(localized: "Starting backup…")]
        actionMessage = nil
        error = nil
        defer {
            runningConfigID = nil
            runSteps = []
        }

        do {
            let service = appModel.service(baseURL: baseURL)
            let jobID = try await service.startBackupRun(configID: config.id)
            var snapshot = try await service.fetchBackupRunJob(id: jobID)
            while snapshot.status == "running" {
                guard scopeID == appModel.connectionScopeID else { return }
                if !snapshot.messages.isEmpty, snapshot.messages != runSteps {
                    runSteps = snapshot.messages
                }
                try await Task.sleep(for: .seconds(1))
                snapshot = try await service.fetchBackupRunJob(id: jobID)
            }
            guard scopeID == appModel.connectionScopeID else { return }
            applyResult(snapshot, targetName: config.targetName)
            await load(appModel: appModel)
            // load() clears the error; restore the run outcome on top of the refreshed list.
            if BackupRunState(rawStatus: snapshot.resultStatus ?? snapshot.status) == .failed {
                applyResult(snapshot, targetName: config.targetName)
            }
        } catch {
            guard !error.isDockhandCancellation else { return }
            self.error = error.dockhandUserFacingMessage
        }
    }

    func stop(_ config: BackupConfigSnapshot, appModel: AppModel) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else { return }
        do {
            try await appModel.service(baseURL: baseURL).stopBackupRun(configID: config.id, environmentID: environmentID)
        } catch {
            guard !error.isDockhandCancellation else { return }
            self.error = error.dockhandUserFacingMessage
        }
    }

    func testDestination(_ destination: BackupDestinationSnapshot, appModel: AppModel) async {
        guard testingDestinationID == nil,
              let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else { return }

        testingDestinationID = destination.id
        error = nil
        actionMessage = nil
        defer { testingDestinationID = nil }

        do {
            let failure = try await appModel.service(baseURL: baseURL)
                .testBackupDestination(id: destination.id, environmentID: environmentID)
            await load(appModel: appModel)
            if let failure {
                error = String(format: String(localized: "%1$@ is not reachable: %2$@"), locale: Locale.current, destination.name, failure)
            } else {
                actionMessage = String(format: String(localized: "%@ is reachable"), locale: Locale.current, destination.name)
            }
        } catch {
            guard !error.isDockhandCancellation else { return }
            self.error = error.dockhandUserFacingMessage
        }
    }

    private func applyResult(_ snapshot: BackupRunJobSnapshot, targetName: String) {
        switch BackupRunState(rawStatus: snapshot.resultStatus ?? snapshot.status) {
        case .success:
            actionMessage = String(format: String(localized: "%@ backed up"), locale: Locale.current, targetName)
        case .warning:
            actionMessage = String(
                format: String(localized: "%1$@ backed up with a warning: %2$@"),
                locale: Locale.current,
                targetName,
                snapshot.resultDetail ?? String(localized: "See Dockhand for details")
            )
        case .skipped:
            actionMessage = String(
                format: String(localized: "%1$@ backup skipped: %2$@"),
                locale: Locale.current,
                targetName,
                snapshot.resultDetail ?? String(localized: "See Dockhand for details")
            )
        case .failed, .never:
            error = String(
                format: String(localized: "%1$@ backup failed: %2$@"),
                locale: Locale.current,
                targetName,
                snapshot.resultDetail ?? String(localized: "See Dockhand for details")
            )
        }
    }

    private func reset() {
        isAvailable = nil
        configs = []
        destinations = []
        error = nil
        actionMessage = nil
    }
}

enum BackupRunState {
    case success
    case warning
    case skipped
    case failed
    case never

    init(rawStatus: String?) {
        switch rawStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case nil, "":
            self = .never
        case "success", "completed":
            self = .success
        case "warning":
            self = .warning
        case "skipped":
            self = .skipped
        default:
            self = .failed
        }
    }

    var title: String {
        switch self {
        case .success: return String(localized: "Succeeded")
        case .warning: return String(localized: "Warning")
        case .skipped: return String(localized: "Skipped")
        case .failed: return String(localized: "Failed")
        case .never: return String(localized: "Never run")
        }
    }

    var tint: Color {
        switch self {
        case .success: return .green
        case .warning, .skipped: return .orange
        case .failed: return .red
        case .never: return .secondary
        }
    }
}

struct BackupsView: View {
    let appModel: AppModel
    let store: BackupsStore
    @State private var configToConfirm: BackupConfigSnapshot?

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

            if let message = store.actionMessage {
                Section {
                    Label(message, systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }

            if store.isAvailable == true && !store.destinations.isEmpty {
                Section {
                    NavigationLink {
                        BackupDestinationsView(appModel: appModel, store: store)
                    } label: {
                        BackupDestinationsSummaryRow(destinations: store.destinations)
                    }
                }
            }

            Section {
                if store.isAvailable == false {
                    Text("Backups are not enabled on this Dockhand server. Set FEAT_BACKUPS_ENABLED=true on the Dockhand container to turn them on.")
                        .foregroundStyle(.secondary)
                } else if store.configs.isEmpty && !store.isLoading {
                    Text("No backup schedules in this environment. Create them in the Dockhand web UI.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.configs) { config in
                        NavigationLink {
                            BackupConfigDetailView(appModel: appModel, store: store, configID: config.id)
                        } label: {
                            BackupConfigRow(
                                config: config,
                                destinationName: store.destination(id: config.destinationID)?.name,
                                isRunning: store.runningConfigID == config.id,
                                runStep: store.runningConfigID == config.id ? store.runSteps.last : nil,
                                canRun: store.runningConfigID == nil,
                                onRun: { configToConfirm = config },
                                onStop: { Task { await store.stop(config, appModel: appModel) } }
                            )
                        }
                    }
                }
            } header: {
                Text("Schedules")
            } footer: {
                if store.isAvailable == true {
                    Text("Destinations, schedules and restores are managed in the Dockhand web UI.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Backups")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if store.isLoading && store.configs.isEmpty {
                ProgressView()
            }
        }
        .task(id: appModel.connectionScopeID) {
            await store.load(appModel: appModel)
        }
        .refreshable {
            await store.load(appModel: appModel)
        }
        .confirmationDialog(
            String(localized: "Run backup now?"),
            isPresented: Binding(
                get: { configToConfirm != nil },
                set: { if !$0 { configToConfirm = nil } }
            ),
            titleVisibility: .visible,
            presenting: configToConfirm
        ) { config in
            Button(String(localized: "Run backup")) {
                Task { await store.run(config, appModel: appModel) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { config in
            if config.stopBeforeBackup {
                Text(String(format: String(localized: "%@ will be stopped while the backup runs."), locale: Locale.current, config.targetName))
            } else {
                Text(String(format: String(localized: "Dockhand backs up %@ to its configured destination."), locale: Locale.current, config.targetName))
            }
        }
    }
}

private struct BackupConfigRow: View {
    let config: BackupConfigSnapshot
    let destinationName: String?
    let isRunning: Bool
    let runStep: String?
    let canRun: Bool
    let onRun: () -> Void
    let onStop: () -> Void

    private var state: BackupRunState {
        BackupRunState(rawStatus: config.lastBackupStatus)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(config.targetName, systemImage: config.type == "stack" ? "square.3.layers.3d" : "shippingbox")
                    .font(.headline)
                Spacer(minLength: 8)
                if isRunning {
                    Button(action: onStop) {
                        Label("Stop", systemImage: "stop.circle")
                            .labelStyle(.iconOnly)
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .tint(.red)
                    .accessibilityLabel(String(format: String(localized: "Stop backup of %@"), config.targetName))
                } else {
                    Button(action: onRun) {
                        Label("Run now", systemImage: "play.circle")
                            .labelStyle(.iconOnly)
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canRun)
                    .accessibilityLabel(String(format: String(localized: "Run backup of %@"), config.targetName))
                }
            }

            if isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(runStep ?? String(localized: "Running…"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else {
                HStack(spacing: 6) {
                    Text(state.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(state.tint)
                    if let date = config.lastBackupAt?.dockhandBackupDate {
                        Text(date, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !config.enabled {
                        Text("Paused")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
            }

            Text(scheduleSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    private var scheduleSummary: String {
        let destination = destinationName ?? String(localized: "Unknown destination")
        guard let schedule = config.schedule else {
            return String(format: String(localized: "%@ · Manual only"), locale: Locale.current, destination)
        }
        return "\(destination) · \(schedule)"
    }
}

private struct BackupDestinationsSummaryRow: View {
    let destinations: [BackupDestinationSnapshot]

    private var unreachableCount: Int {
        destinations.filter { status in
            guard let value = status.lastTestStatus?.lowercased(), !value.isEmpty else { return false }
            return value != "success"
        }.count
    }

    var body: some View {
        HStack {
            Label("Destinations", systemImage: "externaldrive.connected.to.line.below")
            Spacer()
            if unreachableCount > 0 {
                Text(String(format: String(localized: "%d unreachable"), locale: Locale.current, unreachableCount))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }
            Text("\(destinations.count)")
                .foregroundStyle(.secondary)
        }
    }
}

private struct BackupDestinationsView: View {
    let appModel: AppModel
    let store: BackupsStore

    var body: some View {
        List {
            if let error = store.error {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }

            if let message = store.actionMessage {
                Section {
                    Label(message, systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(store.destinations) { destination in
                    BackupDestinationRow(
                        destination: destination,
                        isTesting: store.testingDestinationID == destination.id,
                        canTest: store.testingDestinationID == nil,
                        onTest: { Task { await store.testDestination(destination, appModel: appModel) } }
                    )
                }
            } footer: {
                Text("Destinations are created and edited in the Dockhand web UI.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Destinations")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await store.load(appModel: appModel)
        }
    }
}

private struct BackupDestinationRow: View {
    let destination: BackupDestinationSnapshot
    let isTesting: Bool
    let canTest: Bool
    let onTest: () -> Void

    private var isHealthy: Bool? {
        switch destination.lastTestStatus?.lowercased() {
        case "success": return true
        case nil, "": return nil
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(destination.name, systemImage: "externaldrive.connected.to.line.below")
                    .font(.headline)
                Spacer(minLength: 8)
                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Test", action: onTest)
                        .buttonStyle(.borderless)
                        .disabled(!canTest)
                        .accessibilityLabel(String(format: String(localized: "Test connection to %@"), destination.name))
                }
            }
            Text(destination.repository)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                switch isHealthy {
                case true?:
                    Text("Reachable")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                case false?:
                    Text("Unreachable")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                case nil:
                    Text("Not tested")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if let date = destination.lastTestAt?.dockhandBackupDate {
                    Text(date, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if isHealthy == false, let error = destination.lastTestError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 4)
    }
}

@MainActor
@Observable
private final class BackupConfigDetailStore {
    var executions: [BackupExecutionSnapshot] = []
    var snapshots: [BackupSnapshotSummary] = []
    var isLoadingExecutions = false
    var isLoadingSnapshots = false
    var executionsError: String?
    var snapshotsError: String?

    func load(configID: Int, appModel: AppModel) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else { return }
        let service = appModel.service(baseURL: baseURL)
        async let executionsLoad: Void = loadExecutions(configID: configID, environmentID: environmentID, service: service)
        async let snapshotsLoad: Void = loadSnapshots(configID: configID, service: service)
        _ = await (executionsLoad, snapshotsLoad)
    }

    private func loadExecutions(configID: Int, environmentID: Int, service: DockhandService) async {
        isLoadingExecutions = true
        defer { isLoadingExecutions = false }
        do {
            executions = try await service.fetchBackupExecutions(configID: configID, environmentID: environmentID)
            executionsError = nil
        } catch {
            guard !error.isDockhandCancellation else { return }
            executionsError = error.dockhandUserFacingMessage
        }
    }

    private func loadSnapshots(configID: Int, service: DockhandService) async {
        isLoadingSnapshots = true
        defer { isLoadingSnapshots = false }
        do {
            snapshots = try await service.fetchBackupSnapshots(configID: configID)
            snapshotsError = nil
        } catch {
            guard !error.isDockhandCancellation else { return }
            snapshotsError = error.dockhandUserFacingMessage
        }
    }
}

private struct BackupConfigDetailView: View {
    let appModel: AppModel
    let store: BackupsStore
    let configID: Int
    @State private var detail = BackupConfigDetailStore()

    private var config: BackupConfigSnapshot? {
        store.configs.first { $0.id == configID }
    }

    var body: some View {
        List {
            if let config {
                Section("Configuration") {
                    LabeledContent("Type", value: config.type == "stack" ? String(localized: "Stack") : String(localized: "Container"))
                    LabeledContent("Destination", value: store.destination(id: config.destinationID)?.name ?? String(localized: "Unknown destination"))
                    LabeledContent("Schedule", value: config.schedule ?? String(localized: "Manual only"))
                    LabeledContent("Status", value: config.enabled ? String(localized: "Active") : String(localized: "Paused"))
                    LabeledContent("Stops during backup", value: config.stopBeforeBackup ? String(localized: "Yes") : String(localized: "No"))
                    LabeledContent("Volumes", value: config.allVolumes
                        ? String(localized: "All volumes")
                        : config.selectedVolumes.joined(separator: ", "))
                    LabeledContent("Retention", value: retentionSummary(config.retention))
                    if !config.tags.isEmpty {
                        LabeledContent("Tags", value: config.tags.joined(separator: ", "))
                    }
                }
            }

            Section("Recent runs") {
                if let error = detail.executionsError {
                    Text(error).foregroundStyle(.red)
                } else if detail.executions.isEmpty {
                    Text(detail.isLoadingExecutions ? String(localized: "Loading…") : String(localized: "No runs yet"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(detail.executions) { execution in
                        BackupExecutionRow(execution: execution)
                    }
                }
            }

            Section {
                if let error = detail.snapshotsError {
                    Text(error).foregroundStyle(.red)
                } else if detail.snapshots.isEmpty {
                    Text(detail.isLoadingSnapshots ? String(localized: "Loading…") : String(localized: "No snapshots"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(detail.snapshots) { snapshot in
                        HStack {
                            Text(snapshot.shortID)
                                .font(.body.monospaced())
                            Spacer()
                            if let date = snapshot.time?.dockhandBackupDate {
                                Text(date, format: .dateTime.day().month().year().hour().minute())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Snapshots")
            } footer: {
                Text("Restores are done from the Dockhand web UI.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(config?.targetName ?? String(localized: "Backup"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(appModel.connectionScopeID):\(config?.lastBackupAt ?? "")") {
            await detail.load(configID: configID, appModel: appModel)
        }
        .refreshable {
            await store.load(appModel: appModel)
            await detail.load(configID: configID, appModel: appModel)
        }
    }

    private func retentionSummary(_ rules: [BackupRetentionRule]) -> String {
        guard !rules.isEmpty else { return String(localized: "Keep all snapshots") }
        return rules.map { rule in
            let format: String
            switch rule.key {
            case "keepLast": format = String(localized: "last %d")
            case "keepHourly": format = String(localized: "%d hourly")
            case "keepDaily": format = String(localized: "%d daily")
            case "keepWeekly": format = String(localized: "%d weekly")
            case "keepMonthly": format = String(localized: "%d monthly")
            default: format = String(localized: "%d yearly")
            }
            return String(format: format, locale: Locale.current, rule.value)
        }
        .joined(separator: " · ")
    }
}

private struct BackupExecutionRow: View {
    let execution: BackupExecutionSnapshot

    private var state: BackupRunState {
        BackupRunState(rawStatus: execution.status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(state.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(state.tint)
                if let date = execution.startedAt?.dockhandBackupDate {
                    Text(date, format: .dateTime.day().month().hour().minute())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(execution.triggeredBy == "manual" ? String(localized: "Manual") : String(localized: "Scheduled"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = execution.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            HStack(spacing: 10) {
                if let duration = execution.durationMilliseconds {
                    Text(Duration.milliseconds(duration).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated, fractionalPart: .show(length: 1))))
                }
                if let added = execution.dataAdded {
                    Text(String(format: String(localized: "%@ added"), locale: Locale.current, added.dockhandByteCount))
                }
                if let snapshot = execution.snapshotShortID {
                    Text(snapshot)
                        .monospaced()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private extension String {
    /// Dockhand writes ISO 8601 timestamps; older rows may use SQLite's `YYYY-MM-DD HH:MM:SS` in UTC.
    var dockhandBackupDate: Date? {
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = (try? fractional.parse(self)) ?? (try? Date.ISO8601FormatStyle().parse(self)) {
            return date
        }
        let sqlite = replacingOccurrences(of: " ", with: "T") + "Z"
        return try? Date.ISO8601FormatStyle().parse(sqlite)
    }
}
