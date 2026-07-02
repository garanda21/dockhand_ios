import DockhandAPI
import Observation
import SwiftUI

@MainActor
@Observable
final class DashboardStore {
    var snapshot: DashboardEnvironmentSnapshot?
    var host: DashboardHostSnapshot?
    var isLoading = false
    var error: String?
    var lastUpdated: Date?

    func load(appModel: AppModel, showLoading: Bool = true) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else {
            snapshot = nil
            host = nil
            error = nil
            lastUpdated = nil
            return
        }

        if showLoading {
            isLoading = true
        }
        error = nil
        defer {
            if showLoading {
                isLoading = false
            }
        }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            snapshot = try await service.fetchDashboardStats(environmentID: environmentID)
            lastUpdated = .now
        } catch {
            self.error = error.localizedDescription
            snapshot = nil
            host = nil
            return
        }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            host = try await service.fetchDashboardHost(environmentID: environmentID)
        } catch {
            host = nil
        }
    }
}

struct DashboardView: View {
    let appModel: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var store = DashboardStore()

    private var dashboardLoadID: String {
        "\(appModel.selectedProfileID ?? "none"):\(appModel.selectedEnvironment?.id ?? -1):\(appModel.environments.count)"
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
        await store.load(appModel: appModel)
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
                        Text("Live refresh every 15s · \(lastUpdated.formatted(date: .omitted, time: .standard))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
                statusTile(String(localized: "Running"), value: snapshot.containers.running, systemImage: "play.fill", tint: .green)
                statusTile(String(localized: "Stopped"), value: snapshot.containers.stopped, systemImage: "stop.fill", tint: .secondary)
                statusTile(String(localized: "Paused"), value: snapshot.containers.paused, systemImage: "pause.fill", tint: .orange)
                statusTile(String(localized: "Restarting"), value: snapshot.containers.restarting, systemImage: "arrow.clockwise", tint: .green)
                statusTile(String(localized: "Alerts"), value: snapshot.containers.unhealthy, systemImage: "exclamationmark.triangle", tint: snapshot.containers.unhealthy == 0 ? .green : .orange)
                statusTile(String(localized: "Updates"), value: snapshot.containers.pendingUpdates, systemImage: "arrow.up.circle", tint: .secondary)
            }

            HStack {
                Text("Total containers")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(snapshot.containers.total)")
                    .font(.title3.weight(.semibold))
            }
        }
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
                inventoryTile(String(localized: "Images"), value: "\(snapshot.images.total)", detail: snapshot.images.totalSize.dockhandByteCount, systemImage: "photo.stack")
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
                inventoryTile(String(localized: "Volumes"), value: "\(snapshot.volumes.total)", detail: snapshot.volumes.totalSize > 0 ? snapshot.volumes.totalSize.dockhandByteCount : String(localized: "No size data"), systemImage: "internaldrive")
                inventoryTile(String(localized: "Networks"), value: "\(snapshot.networks.total)", detail: host?.host.storageDriver ?? String(localized: "Ready"), systemImage: "point.3.connected.trianglepath.dotted")
                inventoryTile(
                    String(localized: "Events"),
                    value: "\(snapshot.events.today)",
                    detail: String(format: String(localized: "%d total"), locale: Locale.current, snapshot.events.total),
                    systemImage: "waveform.path.ecg"
                )
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
        ContentUnavailableView(
            "No environment selected",
            systemImage: "globe.badge.chevron.backward",
            description: Text("Configure Dockhand in Settings or refresh the environment list.")
        )
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

private extension Double {
    var percentText: String {
        (self / 100).formatted(.percent.precision(.fractionLength(1)))
    }
}
