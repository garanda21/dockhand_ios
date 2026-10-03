import DockhandAPI
import Observation
import SwiftUI

@MainActor
@Observable
final class DashboardStore {
    var snapshot: DashboardEnvironmentSnapshot?
    var host: DashboardHostSnapshot?
    var isLoading = false
    var isRefreshingCachedSnapshot = false
    var error: String?
    var lastUpdated: Date?
    var isShowingCachedSnapshot = false

    func restoreCachedSnapshot(appModel: AppModel) {
        guard let profileID = appModel.selectedProfileID,
              let environmentID = appModel.selectedEnvironment?.id,
              let cached = PreferencesStore.cachedDashboardSnapshot(profileID: profileID, environmentID: environmentID) else {
            snapshot = nil
            host = nil
            lastUpdated = nil
            isShowingCachedSnapshot = false
            return
        }

        snapshot = cached.snapshot
        host = cached.host
        lastUpdated = cached.lastUpdated
        error = nil
        isShowingCachedSnapshot = true
    }

    func load(appModel: AppModel, showLoading: Bool = true) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let profileID = appModel.selectedProfileID,
              let environmentID = appModel.selectedEnvironment?.id else {
            snapshot = nil
            host = nil
            error = nil
            lastUpdated = nil
            isShowingCachedSnapshot = false
            return
        }

        if showLoading && snapshot == nil {
            isLoading = true
        }
        if snapshot != nil && isShowingCachedSnapshot {
            isRefreshingCachedSnapshot = true
        }
        error = nil
        defer {
            if showLoading {
                isLoading = false
            }
            isRefreshingCachedSnapshot = false
        }

        do {
            let service = appModel.service(baseURL: baseURL)
            snapshot = try await service.fetchDashboardStats(environmentID: environmentID)
            lastUpdated = .now
            isShowingCachedSnapshot = false
        } catch {
            guard !error.isDockhandCancellation else { return }
            self.error = error.dockhandUserFacingMessage
            if snapshot == nil {
                host = nil
                lastUpdated = nil
                isShowingCachedSnapshot = false
            }
            return
        }

        do {
            let service = appModel.service(baseURL: baseURL)
            host = try await service.fetchDashboardHost(environmentID: environmentID)
        } catch {
            host = nil
        }

        if let snapshot, let lastUpdated {
            PreferencesStore.setCachedDashboardSnapshot(
                CachedDashboardSnapshot(snapshot: snapshot, host: host, lastUpdated: lastUpdated),
                profileID: profileID,
                environmentID: environmentID
            )
        }
    }
}

@MainActor
@Observable
private final class DashboardResourceDetailStore {
    var pendingUpdates: [PendingContainerUpdate] = []
    var serverVersion: String?
    private var updatesLoadToken = UUID()
    var volumes: [VolumeSnapshot] = []
    var networks: [NetworkSnapshot] = []
    var activity = ContainerActivitySnapshot(events: [], total: 0)
    var stacks: [Components.Schemas.StackSummary] = []
    var isLoading = false
    var isCheckingUpdates = false
    var isUpdatingContainers = false
    var updateCheckProgress: Double?
    var operationMessage: String?
    var error: String?

    func loadUpdates(appModel: AppModel) async {
        let scope = appModel.connectionScopeID
        let token = UUID()
        updatesLoadToken = token
        serverVersion = nil
        pendingUpdates = []
        guard let service = service(for: appModel),
              let environmentID = appModel.selectedEnvironment?.id else {
            pendingUpdates = []
            stacks = []
            return
        }

        isLoading = true
        error = nil
        defer { if token == updatesLoadToken { isLoading = false } }

        do {
            async let loadedUpdates = service.fetchPendingContainerUpdates(environmentID: environmentID)
            async let loadedStacks = service.fetchStacks(environmentID: environmentID)
            let (updates, stacks) = try await (loadedUpdates, loadedStacks)
            guard token == updatesLoadToken, scope == appModel.connectionScopeID, !Task.isCancelled else { return }
            pendingUpdates = updates.sorted {
                $0.containerName.localizedCaseInsensitiveCompare($1.containerName) == .orderedAscending
            }
            self.stacks = stacks
            let host = try? await service.fetchDashboardHost(environmentID: environmentID)
            var version = host?.dockhand?.version
            if version == nil {
                version = (try? await service.fetchDockhandChangelog(environmentID: environmentID, serverVersion: nil))?.first?.version
            }
            guard token == updatesLoadToken, scope == appModel.connectionScopeID, !Task.isCancelled else { return }
            serverVersion = version
        } catch {
            guard token == updatesLoadToken, scope == appModel.connectionScopeID, !error.isDockhandCancellation else { return }
            self.error = error.dockhandUserFacingMessage
        }
    }

    func checkForUpdates(appModel: AppModel) async {
        guard let service = service(for: appModel),
              let environmentID = appModel.selectedEnvironment?.id else { return }

        isCheckingUpdates = true
        updateCheckProgress = nil
        operationMessage = nil
        error = nil
        defer { isCheckingUpdates = false }

        do {
            let operation = try await service.startContainerUpdateCheck(environmentID: environmentID)
            let result: ContainerUpdateCheckResult
            switch operation {
            case .job(let jobID):
                result = try await watchUpdateCheckJob(jobID, service: service)
            case .completed(let completedResult):
                updateCheckProgress = 1
                result = completedResult
            }
            operationMessage = String(
                format: String(localized: "%1$d updates found after checking %2$d containers"),
                locale: .current,
                result.updatesFound,
                result.total
            )
            await loadUpdates(appModel: appModel)
        } catch {
            guard !error.isDockhandCancellation else { return }
            self.error = error.dockhandUserFacingMessage
        }
    }

    func updateContainers(_ updates: [PendingContainerUpdate], appModel: AppModel) async {
        guard !updates.isEmpty,
              let service = service(for: appModel),
              let environmentID = appModel.selectedEnvironment?.id else { return }

        isUpdatingContainers = true
        operationMessage = nil
        error = nil
        defer { isUpdatingContainers = false }

        do {
            let response = try await service.updateContainers(
                ids: updates.map(\.containerID),
                environmentID: environmentID
            )
            if response.summary.failed > 0 {
                let details = response.results
                    .filter { !$0.success }
                    .map { "\($0.containerName): \($0.error ?? String(localized: "Update failed"))" }
                    .joined(separator: "\n")
                throw DockhandServiceError.message(details)
            }
            operationMessage = String(
                format: String(localized: "%d containers updated"),
                locale: .current,
                response.summary.success
            )
            await loadUpdates(appModel: appModel)
        } catch {
            guard !error.isDockhandCancellation else { return }
            self.error = error.dockhandUserFacingMessage
        }
    }

    private func watchUpdateCheckJob(
        _ jobID: String,
        service: DockhandService
    ) async throws -> ContainerUpdateCheckResult {
        var cursor = 0

        while true {
            try Task.checkCancellation()
            let snapshot = try await service.fetchContainerUpdateCheckJob(id: jobID)

            if cursor < snapshot.lines.count {
                for line in snapshot.lines[cursor...] {
                    if let checked = line.data.checked,
                       let total = line.data.total,
                       total > 0 {
                        updateCheckProgress = Double(checked) / Double(total)
                    }
                }
                cursor = snapshot.lines.count
            }

            if snapshot.status != "running" {
                guard snapshot.status != "error", let result = snapshot.result else {
                    throw DockhandServiceError.message(String(localized: "Update check failed"))
                }
                updateCheckProgress = 1
                return result
            }

            try await Task.sleep(for: .milliseconds(500))
        }
    }

    func loadVolumes(appModel: AppModel) async {
        guard let service = service(for: appModel),
              let environmentID = appModel.selectedEnvironment?.id else {
            volumes = []
            stacks = []
            return
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            async let loadedVolumes = service.fetchVolumes(environmentID: environmentID)
            async let loadedStacks = service.fetchStacks(environmentID: environmentID)
            let (volumes, stacks) = try await (loadedVolumes, loadedStacks)
            self.volumes = volumes.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            self.stacks = stacks
        } catch {
            guard !error.isDockhandCancellation else { return }
            self.error = error.dockhandUserFacingMessage
        }
    }

    func loadNetworks(appModel: AppModel) async {
        guard let service = service(for: appModel),
              let environmentID = appModel.selectedEnvironment?.id else {
            networks = []
            stacks = []
            return
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            async let loadedNetworks = service.fetchNetworks(environmentID: environmentID)
            async let loadedStacks = service.fetchStacks(environmentID: environmentID)
            let (networks, stacks) = try await (loadedNetworks, loadedStacks)
            self.networks = networks.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            self.stacks = stacks
        } catch {
            guard !error.isDockhandCancellation else { return }
            self.error = error.dockhandUserFacingMessage
        }
    }

    func loadActivity(appModel: AppModel) async {
        guard let service = service(for: appModel),
              let environmentID = appModel.selectedEnvironment?.id else {
            activity = ContainerActivitySnapshot(events: [], total: 0)
            stacks = []
            return
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            async let loadedActivity = service.fetchContainerActivity(environmentID: environmentID)
            async let loadedStacks = service.fetchStacks(environmentID: environmentID)
            let (activity, stacks) = try await (loadedActivity, loadedStacks)
            self.activity = activity
            self.stacks = stacks
        } catch {
            guard !error.isDockhandCancellation else { return }
            self.error = error.dockhandUserFacingMessage
        }
    }

    func stackNames(for containerID: String) -> [String] {
        stacks
            .filter { stack in
                stack.containerDetails.contains(where: { $0.id == containerID })
            }
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func service(for appModel: AppModel) -> DockhandService? {
        guard let baseURL = appModel.normalizedBaseURL else { return nil }
        return appModel.service(baseURL: baseURL)
    }
}

struct DashboardView: View {
    let appModel: AppModel
    var onOpenSettings: () -> Void = {}
    var onOpenContainers: (ContainerListFilter) -> Void = { _ in }
    var onOpenStacks: () -> Void = {}
    var onOpenImages: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @State private var store = DashboardStore()

    private var dashboardLoadID: String {
        "\(appModel.selectedProfileID ?? "none"):\(appModel.selectedEnvironment?.id ?? -1):\(appModel.environments.count):\(appModel.dashboardRefreshRevision)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                EnvironmentHeaderBar(appModel: appModel)

                if let environment = appModel.selectedEnvironment {
                    if let error = store.error {
                        errorCard(error)
                    }

                    if let snapshot = store.snapshot {
                        environmentCard(environment: environment, snapshot: snapshot, host: store.host)
                    } else if store.isLoading {
                        loadingCard
                    } else {
                        summaryCard(environment: environment)
                    }
                } else {
                    emptyState
                }
            }
            .padding()
        }
        .navigationTitle("Dockhand")
        .navigationBarTitleDisplayMode(.large)
        .background(backgroundGradient)
        .task(id: dashboardLoadID) {
            await runDashboardLoop()
        }
        .refreshable {
            await store.load(appModel: appModel)
        }
    }

    private func runDashboardLoop() async {
        store.restoreCachedSnapshot(appModel: appModel)
        await store.load(appModel: appModel, showLoading: store.snapshot == nil)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { break }
            await store.load(appModel: appModel, showLoading: false)
        }
    }

    private func summaryCard(environment: Components.Schemas.Environment) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(environment.name)
                .font(.title2.weight(.semibold))
            Text(environment.hostSummary)
                .font(.body)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                summaryMetric(String(localized: "Protocol"), environment._protocol.uppercased())
                summaryMetric(String(localized: "Port"), "\(environment.port)")
                summaryMetric(String(localized: "Type"), environment.connectionType.localizedConnectionTypeLabel)
            }
        }
        .padding(20)
        .glassEffect(.regular.tint(.white.opacity(0.04)), in: .rect(cornerRadius: 24))
    }

    private func errorCard(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.red)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(.red.opacity(0.08)), in: .rect(cornerRadius: 18))
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Loading environment stats")
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.white.opacity(0.03)), in: .rect(cornerRadius: 24))
    }

    private func environmentCard(
        environment: Components.Schemas.Environment,
        snapshot: DashboardEnvironmentSnapshot,
        host: DashboardHostSnapshot?
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            environmentHero(environment: environment, snapshot: snapshot, host: host)
            healthBanner(snapshot: snapshot)
            resourceSection(snapshot: snapshot)
            statusTiles(snapshot: snapshot)
            inventorySection(snapshot: snapshot, host: host)
        }
        .padding(20)
        .glassEffect(.regular.tint(.white.opacity(0.04)), in: .rect(cornerRadius: 24))
    }

    private func environmentHero(
        environment: Components.Schemas.Environment,
        snapshot: DashboardEnvironmentSnapshot,
        host: DashboardHostSnapshot?
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.blue.opacity(colorScheme == .dark ? 0.18 : 0.10))
                    Image(systemName: "globe")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.blue)
                }
                .frame(width: 60, height: 60)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(environment.name)
                            .font(.title2.weight(.semibold))
                            .lineLimit(1)
                        Image(systemName: snapshot.online ? "wifi" : "wifi.slash")
                            .foregroundStyle(snapshot.online ? .green : .secondary)
                    }

                    Text(environment.hostSummary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    if let lastUpdated = store.lastUpdated {
                        let updatedTime = lastUpdated.formatted(date: .omitted, time: .standard)
                        let updateLabel = store.isShowingCachedSnapshot
                            ? String(format: String(localized: "Cached snapshot · %@"), locale: Locale.current, updatedTime)
                            : String(format: String(localized: "Live refresh every 15s · %@"), locale: Locale.current, updatedTime)

                        HStack(spacing: 6) {
                            if store.isRefreshingCachedSnapshot {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(.secondary)
                                    .accessibilityLabel(String(localized: "Refresh"))
                            }

                            Text(updateLabel)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                metadataChip(String(localized: "Connection"), value: environment.connectionType.localizedConnectionTypeLabel, systemImage: "link")
                metadataChip(String(localized: "Docker"), value: host?.docker.serverVersion ?? String(localized: "Unknown"), systemImage: "shippingbox")
                metadataChip(String(localized: "CPU"), value: (host?.host.cpus ?? 0).localizedCoresCountText, systemImage: "cpu")
                metadataChip(String(localized: "Memory"), value: (host?.host.memory ?? snapshot.metrics.memoryTotal).dockhandByteCount, systemImage: "memorychip")
            }
        }
    }

    private func metadataChip(_ title: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func healthBanner(snapshot: DashboardEnvironmentSnapshot) -> some View {
        let message = snapshot.containers.unhealthy == 0
            ? String(localized: "All containers healthy")
            : String(format: String(localized: "%d unhealthy containers"), locale: Locale.current, snapshot.containers.unhealthy)

        return HStack(spacing: 10) {
            Image(systemName: snapshot.containers.unhealthy == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            Text(message)
                .font(.headline.weight(.medium))
        }
        .foregroundStyle(snapshot.containers.unhealthy == 0 ? .green : .orange)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill((snapshot.containers.unhealthy == 0 ? Color.green : Color.orange).opacity(colorScheme == .dark ? 0.14 : 0.10))
        )
    }

    private func resourceSection(snapshot: DashboardEnvironmentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Resources")
                .font(.headline)

            usageRow(
                title: String(localized: "CPU"),
                systemImage: "cpu",
                value: snapshot.metrics.cpuPercent.percentText,
                detail: nil,
                progress: snapshot.metrics.cpuPercent / 100,
                tint: .green
            )

            usageRow(
                title: String(localized: "Memory"),
                systemImage: "memorychip",
                value: snapshot.metrics.memoryPercent.percentText,
                detail: "\(snapshot.metrics.memoryUsed.dockhandByteCount) / \(snapshot.metrics.memoryTotal.dockhandByteCount)",
                progress: snapshot.metrics.memoryPercent / 100,
                tint: .green
            )
        }
    }

    private func usageRow(
        title: String,
        systemImage: String,
        value: String,
        detail: String?,
        progress: Double,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(value)
                        .font(.headline.weight(.semibold))
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ProgressView(value: min(max(progress, 0), 1))
                .tint(tint)
        }
    }

    private func statusTiles(snapshot: DashboardEnvironmentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Containers")
                .font(.headline)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                containerStatusButton(String(localized: "Running"), value: snapshot.containers.running, systemImage: "play.fill", tint: .green, filter: .state("running"))
                containerStatusButton(String(localized: "Stopped"), value: snapshot.containers.stopped, systemImage: "stop.fill", tint: .secondary, filter: .stopped)
                containerStatusButton(String(localized: "Paused"), value: snapshot.containers.paused, systemImage: "pause.fill", tint: .orange, filter: .state("paused"))
                containerStatusButton(String(localized: "Restarting"), value: snapshot.containers.restarting, systemImage: "arrow.clockwise", tint: .green, filter: .state("restarting"))
                containerStatusButton(String(localized: "Alerts"), value: snapshot.containers.unhealthy, systemImage: "exclamationmark.triangle", tint: snapshot.containers.unhealthy == 0 ? .green : .orange, filter: .unhealthy)
                NavigationLink {
                    DashboardUpdatesDetailView(appModel: appModel)
                } label: {
                    statusTile(String(localized: "Updates"), value: snapshot.containers.pendingUpdates, systemImage: "arrow.up.circle", tint: .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the containers and stacks with pending updates")
            }

            Button {
                onOpenContainers(.all)
            } label: {
                HStack {
                    Text("Total containers")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(snapshot.containers.total)")
                        .font(.title3.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func containerStatusButton(
        _ title: String,
        value: Int,
        systemImage: String,
        tint: Color,
        filter: ContainerListFilter
    ) -> some View {
        Button {
            onOpenContainers(filter)
        } label: {
            statusTile(title, value: value, systemImage: systemImage, tint: tint)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the matching containers")
    }

    private func statusTile(_ title: String, value: Int, systemImage: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text("\(value)")
                .font(.title3.weight(.semibold))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func inventorySection(snapshot: DashboardEnvironmentSnapshot, host: DashboardHostSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Inventory")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                Button(action: onOpenImages) {
                    inventoryTile(String(localized: "Images"), value: "\(snapshot.images.total)", detail: snapshot.images.totalSize.dockhandByteCount, systemImage: "photo.stack")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Images")
                Button(action: onOpenStacks) {
                    inventoryTile(
                        String(localized: "Stacks"),
                        value: "\(snapshot.stacks.total)",
                        detail: String(
                            format: String(localized: "%1$d running · %2$d stopped"),
                            locale: Locale.current,
                            snapshot.stacks.running,
                            snapshot.stacks.stopped
                        ),
                        systemImage: "square.3.layers.3d"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Stacks")
                NavigationLink {
                    DashboardVolumesDetailView(appModel: appModel)
                } label: {
                    inventoryTile(String(localized: "Volumes"), value: "\(snapshot.volumes.total)", detail: snapshot.volumes.totalSize > 0 ? snapshot.volumes.totalSize.dockhandByteCount : String(localized: "No size data"), systemImage: "internaldrive")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows each volume and the containers and stacks using it")
                NavigationLink {
                    DashboardNetworksDetailView(appModel: appModel)
                } label: {
                    inventoryTile(String(localized: "Networks"), value: "\(snapshot.networks.total)", detail: host?.host.storageDriver ?? String(localized: "Ready"), systemImage: "point.3.connected.trianglepath.dotted")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows networks and connected containers")
                NavigationLink {
                    DashboardEventsDetailView(appModel: appModel)
                } label: {
                    inventoryTile(
                        String(localized: "Events"),
                        value: "\(snapshot.events.today)",
                        detail: String(format: String(localized: "%d total"), locale: Locale.current, snapshot.events.total),
                        systemImage: "waveform.path.ecg"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows recent container activity")
                inventoryTile(
                    String(localized: "Build cache"),
                    value: snapshot.buildCacheSize.dockhandByteCount,
                    detail: String(
                        format: String(localized: "Containers %@"),
                        locale: Locale.current,
                        snapshot.containersSize.dockhandByteCount
                    ),
                    systemImage: "shippingbox"
                )
            }
        }
    }

    private func inventoryTile(_ title: String, value: String, detail: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 94, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func summaryMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ContentUnavailableView(
                appModel.serverProfiles.isEmpty ? String(localized: "No server configured") : String(localized: "No environment selected"),
                systemImage: appModel.serverProfiles.isEmpty ? "server.rack" : "globe.badge.chevron.backward",
                description: Text(
                    appModel.serverProfiles.isEmpty
                        ? String(localized: "Add a Dockhand server to start switching environments.")
                        : String(localized: "Configure Dockhand in Settings or refresh the environment list.")
                )
            )

            if appModel.serverProfiles.isEmpty {
                Button {
                    onOpenSettings()
                } label: {
                    Label(String(localized: "Settings"), systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    Color(uiColor: .systemGroupedBackground),
                    Color(uiColor: .secondarySystemGroupedBackground),
                    Color(red: 0.08, green: 0.10, blue: 0.16)
                ]
                : [
                    Color(red: 0.96, green: 0.98, blue: 1.0),
                    Color(red: 0.90, green: 0.94, blue: 0.98)
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

private struct DashboardUpdatesDetailView: View {
    let appModel: AppModel
    @State private var store = DashboardResourceDetailStore()
    @State private var updatesToConfirm: [PendingContainerUpdate] = []

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

            if let message = store.operationMessage {
                Section {
                    Label(message, systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    Task { await store.checkForUpdates(appModel: appModel) }
                } label: {
                    Label("Check for updates", systemImage: "arrow.clockwise")
                }
                .disabled(store.isCheckingUpdates || store.isUpdatingContainers)

                if store.isCheckingUpdates {
                    ProgressView(value: store.updateCheckProgress)
                }

                if !store.pendingUpdates.isEmpty {
                    Button {
                        updatesToConfirm = store.pendingUpdates
                    } label: {
                        Label("Update all containers", systemImage: "arrow.up.circle")
                    }
                    .disabled(store.isCheckingUpdates || store.isUpdatingContainers)
                }
            }

            Section("Pending updates") {
                if store.isLoading && store.pendingUpdates.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if store.pendingUpdates.isEmpty && store.error == nil {
                    ContentUnavailableView(
                        "No pending updates",
                        systemImage: "checkmark.circle",
                        description: Text("All checked containers are up to date.")
                    )
                } else {
                    ForEach(store.pendingUpdates, id: \.containerID) { update in
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 7) {
                                Label(update.containerName, systemImage: "shippingbox")
                                    .font(.headline)
                                Text(update.currentImage)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                associationLabel(for: update.containerID)
                                if DockhandChangelogRelease.supportsContainerNotes(version: store.serverVersion),
                                   let baseURL = appModel.normalizedBaseURL,
                                   let environmentID = appModel.selectedEnvironment?.id {
                                    ContainerChangesButton(
                                        service: appModel.service(baseURL: baseURL),
                                        update: update,
                                        environmentID: environmentID,
                                        serverVersion: store.serverVersion
                                    )
                                    .id("\(appModel.connectionScopeID):\(update.containerID)")
                                }
                            }

                            Spacer(minLength: 8)

                            Button {
                                updatesToConfirm = [update]
                            } label: {
                                Image(systemName: "arrow.up.circle")
                                    .font(.title3)
                            }
                            .buttonStyle(.borderless)
                            .disabled(store.isCheckingUpdates || store.isUpdatingContainers)
                            .accessibilityLabel(String(format: String(localized: "Update %@"), update.containerName))
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Available Updates")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: ServerDetailsStore.loadID(appModel: appModel)) {
            await store.loadUpdates(appModel: appModel)
        }
        .refreshable {
            await store.loadUpdates(appModel: appModel)
        }
        .confirmationDialog(
            String(localized: "Update containers?"),
            isPresented: Binding(
                get: { !updatesToConfirm.isEmpty },
                set: { if !$0 { updatesToConfirm = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(format: String(localized: "Update %d containers"), updatesToConfirm.count), role: .destructive) {
                let selectedUpdates = updatesToConfirm
                updatesToConfirm = []
                Task { await store.updateContainers(selectedUpdates, appModel: appModel) }
            }
            Button("Cancel", role: .cancel) {
                updatesToConfirm = []
            }
        } message: {
            Text("Dockhand will pull the latest images and recreate the selected containers while preserving their configuration.")
        }
    }

    private func associationLabel(for containerID: String) -> some View {
        let stackNames = store.stackNames(for: containerID)
        return Label(
            stackNames.isEmpty ? String(localized: "Standalone container") : stackNames.joined(separator: ", "),
            systemImage: stackNames.isEmpty ? "shippingbox" : "square.3.layers.3d"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

private struct DashboardVolumesDetailView: View {
    let appModel: AppModel
    @State private var store = DashboardResourceDetailStore()

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

            Section("Volumes") {
                if store.isLoading && store.volumes.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if store.volumes.isEmpty && store.error == nil {
                    ContentUnavailableView("No volumes", systemImage: "internaldrive")
                } else {
                    ForEach(store.volumes, id: \.name) { volume in
                        volumeRow(volume)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Volumes")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: appModel.connectionScopeID) {
            await store.loadVolumes(appModel: appModel)
        }
        .refreshable {
            await store.loadVolumes(appModel: appModel)
        }
    }

    private func volumeRow(_ volume: VolumeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(volume.name, systemImage: "internaldrive")
                .font(.headline)
            Text("\(volume.driver) · \(volume.scope)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if volume.usedBy.isEmpty {
                Label("Not attached to a container", systemImage: "minus.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(volume.usedBy, id: \.containerID) { usage in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(usage.containerName, systemImage: "shippingbox")
                            .font(.subheadline.weight(.medium))
                        let stackNames = store.stackNames(for: usage.containerID)
                        if !stackNames.isEmpty {
                            Label(stackNames.joined(separator: ", "), systemImage: "square.3.layers.3d")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 4)
                }
            }
        }
        .padding(.vertical, 5)
    }
}

private struct DashboardNetworksDetailView: View {
    let appModel: AppModel
    @State private var store = DashboardResourceDetailStore()

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

            Section("Networks") {
                if store.isLoading && store.networks.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if store.networks.isEmpty && store.error == nil {
                    ContentUnavailableView("No networks", systemImage: "point.3.connected.trianglepath.dotted")
                } else {
                    ForEach(store.networks, id: \.id) { network in
                        networkRow(network)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Networks")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: appModel.connectionScopeID) {
            await store.loadNetworks(appModel: appModel)
        }
        .refreshable {
            await store.loadNetworks(appModel: appModel)
        }
    }

    private func networkRow(_ network: NetworkSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(network.name, systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)

            HStack(spacing: 8) {
                Text("\(network.driver) · \(network.scope)")
                if network.isInternal {
                    Text("Internal")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !network.subnets.isEmpty {
                Label(network.subnets.joined(separator: ", "), systemImage: "number")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if network.containers.isEmpty {
                Label("No connected containers", systemImage: "minus.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(network.containers, id: \.containerID) { usage in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Label(usage.containerName, systemImage: "shippingbox")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            if !usage.ipv4Address.isEmpty {
                                Text(usage.ipv4Address)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        let stackNames = store.stackNames(for: usage.containerID)
                        if !stackNames.isEmpty {
                            Label(stackNames.joined(separator: ", "), systemImage: "square.3.layers.3d")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 4)
                }
            }
        }
        .padding(.vertical, 5)
    }
}

private struct DashboardEventsDetailView: View {
    let appModel: AppModel
    @State private var store = DashboardResourceDetailStore()

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

            Section {
                if store.isLoading && store.activity.events.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if store.activity.events.isEmpty && store.error == nil {
                    ContentUnavailableView(
                        "No activity",
                        systemImage: "waveform.path.ecg",
                        description: Text("Enable activity collection for this environment to record container events.")
                    )
                } else {
                    ForEach(store.activity.events, id: \.id) { event in
                        eventRow(event)
                    }
                }
            } header: {
                Text(
                    String(
                        format: String(localized: "%1$d recent · %2$d total"),
                        locale: .current,
                        store.activity.events.count,
                        store.activity.total
                    )
                )
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: appModel.connectionScopeID) {
            await store.loadActivity(appModel: appModel)
        }
        .refreshable {
            await store.loadActivity(appModel: appModel)
        }
    }

    private func eventRow(_ event: ContainerEventSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(event.action.localizedEventAction, systemImage: event.action.eventSystemImage)
                    .font(.headline)
                Spacer()
                Text(event.timestamp.localizedEventTimestamp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Label(event.containerName ?? String(localized: "Unknown container"), systemImage: "shippingbox")
                .font(.subheadline.weight(.medium))

            if let image = event.image, !image.isEmpty {
                Text(image)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            let stackNames = store.stackNames(for: event.containerID)
            if !stackNames.isEmpty {
                Label(stackNames.joined(separator: ", "), systemImage: "square.3.layers.3d")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private extension String {
    var localizedEventAction: String {
        replacingOccurrences(of: "_", with: " ")
            .capitalized(with: .current)
    }

    var eventSystemImage: String {
        switch lowercased() {
        case "start", "unpause": "play.fill"
        case "stop", "die", "kill", "destroy": "stop.fill"
        case "restart": "arrow.clockwise"
        case "pause": "pause.fill"
        case "oom": "memorychip"
        case "health_status": "heart.text.square"
        case "create": "plus.circle"
        default: "waveform.path.ecg"
        }
    }

    var localizedEventTimestamp: String {
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let standard = Date.ISO8601FormatStyle()
        let date = (try? fractional.parse(self)) ?? (try? standard.parse(self))
        return date?.formatted(date: .abbreviated, time: .shortened) ?? self
    }
}

private extension Double {
    var percentText: String {
        (self / 100).formatted(.percent.precision(.fractionLength(1)))
    }
}

private struct ContainerChangesButton: View {
    let service: DockhandService
    let update: PendingContainerUpdate
    let environmentID: Int
    let serverVersion: String?

    @State private var notes: ContainerReleaseNotes?
    @State private var presentedNotes: ContainerReleaseNotes?

    var body: some View {
        Group {
            if let notes, notes.hasContent {
                Button {
                    presentedNotes = notes
                } label: {
                    Label(String(localized: "View changes"), systemImage: "text.document")
                        .font(.footnote)
                }
                .buttonStyle(.borderless)
            }
        }
        .task(id: update) {
            notes = nil
            guard DockhandChangelogRelease.supportsContainerNotes(version: serverVersion) else { return }
            let result = try? await service.fetchContainerReleaseNotes(update: update, environmentID: environmentID, serverVersion: serverVersion)
            guard !Task.isCancelled else { return }
            notes = result
        }
        .sheet(item: $presentedNotes) { notes in
            ContainerChangesView(containerName: update.containerName, notes: notes)
        }
    }
}

private struct ContainerChangesView: View {
    let containerName: String
    let notes: ContainerReleaseNotes
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let url = ContainerReleaseNotes.webURL(notes.changelogUrl) {
                    Link(destination: url) {
                        Label(String(localized: "Open changelog"), systemImage: "arrow.up.right.square")
                    }
                }
                ForEach(Array(notes.notes.enumerated()), id: \.offset) { _, note in
                    Section {
                        if let body = note.body, !body.isEmpty {
                            Text(verbatim: body)
                                .textSelection(.enabled)
                        }
                        if let url = ContainerReleaseNotes.webURL(note.url) {
                            Link(String(localized: "Open release notes"), destination: url)
                        }
                    } header: {
                        Text(verbatim: note.name ?? note.version)
                    }
                }
            }
            .navigationTitle(containerName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
    }

}
