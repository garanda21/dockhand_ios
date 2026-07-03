import Observation
import SwiftUI

@MainActor
@Observable
final class ServerDetailsStore {
    var host: DashboardHostSnapshot?
    var isLoading = false
    var error: String?

    func load(appModel: AppModel) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else {
            host = nil
            error = nil
            return
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            host = try await service.fetchDashboardHost(environmentID: environmentID)
        } catch {
            guard !error.isDockhandCancellation else { return }
            self.error = error.dockhandUserFacingMessage
        }
    }
}

struct SettingsView: View {
    let appModel: AppModel

    @State private var statusMessage: String?
    @State private var detailsStore = ServerDetailsStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                activeServerCard
                serverDetailsCard
                serverLibraryCard

                if let statusMessage {
                    statusCard(statusMessage)
                }
            }
            .padding()
        }
        .navigationTitle(String(localized: "Settings"))
        .navigationBarTitleDisplayMode(.large)
        .task(id: appModel.connectionScopeID) {
            await detailsStore.load(appModel: appModel)
        }
    }

    private var activeServerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Active server"))
                        .font(.headline.weight(.semibold))
                    Text(String(localized: "Quick context and switching."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)
                if let health = appModel.lastHealthStatus {
                    infoChip(String(localized: "Status"), health.uppercased(), systemImage: "heart.text.square", tint: health == "ok" ? .green : .secondary)
                        .frame(maxWidth: 120)
                }

                if appModel.isLoadingEnvironments {
                    ProgressView()
                }
            }

            if let profile = appModel.selectedProfile {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "server.rack")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .glassEffect(.regular.tint(.white.opacity(0.06)), in: .circle)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name)
                                .font(.headline.weight(.semibold))
                                .lineLimit(1)
                            Text(profile.baseURL)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 10) {
                        serverSwitcherMenu
                        //infoChip("Environment", appModel.selectedEnvironmentName, systemImage: "globe")
                        Button {
                            Task {
                                await appModel.refreshEnvironments(forceEnvironmentReset: false)
                                await detailsStore.load(appModel: appModel)
                                statusMessage = appModel.environmentError ?? String(localized: "Active server refreshed")
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.title3)
                                .frame(maxWidth: 60, maxHeight: 50)
                        }
                        .buttonStyle(.glass)
                            
                    }

                    
                }
            } else {
                ContentUnavailableView(
                    String(localized: "No server configured"),
                    systemImage: "server.rack",
                    description: Text(String(localized: "Add a Dockhand server to start switching environments."))
                )

                NavigationLink {
                    ServerProfileDetailView(appModel: appModel, profileID: nil)
                } label: {
                    Label(String(localized: "Add server"), systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(16)
        .glassEffect(.regular.tint(.white.opacity(0.03)), in: .rect(cornerRadius: 22))
    }

    private var serverSwitcherMenu: some View {
        Menu {
            ForEach(appModel.serverProfiles) { profile in
                Button {
                    Task {
                        await appModel.selectServerProfile(profile.id, forceEnvironmentReset: true)
                        statusMessage = appModel.environmentError ?? String(localized: "Server changed")
                    }
                } label: {
                    Label(
                        profile.name,
                        systemImage: appModel.selectedProfileID == profile.id ? "checkmark.circle.fill" : "server.rack"
                    )
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Switch server"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(appModel.selectedProfileName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular.tint(.orange.opacity(0.18)), in: .rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .disabled(appModel.serverProfiles.isEmpty)
    }

    private var serverDetailsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Server details"))
                        .font(.headline.weight(.semibold))
                    Text(String(localized: "Dockhand, Docker and host information for the active environment."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if detailsStore.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let host = detailsStore.host {
                VStack(alignment: .leading, spacing: 14) {
                    let dockhandRows = host.dockhand.map(dockhandDetailRows) ?? []
                    if !dockhandRows.isEmpty {
                        detailGroup(
                            String(localized: "Dockhand"),
                            systemImage: "server.rack",
                            rows: dockhandRows
                        )
                        divider
                    }

                    detailGroup(
                        String(localized: "Docker"),
                        systemImage: "shippingbox",
                        rows: [
                            (String(localized: "Server"), host.docker.serverVersion),
                            (String(localized: "Client"), host.docker.version),
                            (String(localized: "API"), host.docker.apiVersion),
                            (String(localized: "OS"), "\(host.docker.os) / \(host.docker.arch)"),
                            (String(localized: "Kernel"), host.docker.kernelVersion),
                            (String(localized: "Connection"), host.docker.connectionType.localizedConnectionTypeLabel)
                        ]
                    )

                    divider

                    detailGroup(
                        String(localized: "Host"),
                        systemImage: "desktopcomputer",
                        rows: [
                            (String(localized: "Name"), host.host.name),
                            (String(localized: "CPU"), host.host.cpus.localizedCoresCountText),
                            (String(localized: "Memory"), host.host.memory.dockhandByteCount),
                            (String(localized: "Storage"), host.host.storageDriver)
                        ]
                    )
                }
            } else if let error = detailsStore.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(String(localized: "Select an environment to load server details."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 22))
    }

    private var serverLibraryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Server library"))
                        .font(.headline.weight(.semibold))
                    Text(String(localized: "Each server keeps its own details, token and selected environment."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                NavigationLink {
                    ServerProfileDetailView(appModel: appModel, profileID: nil)
                } label: {
                    Label(String(localized: "New"), systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
            }

            VStack(spacing: 10) {
                ForEach(appModel.serverProfiles) { profile in
                    NavigationLink {
                        ServerProfileDetailView(appModel: appModel, profileID: profile.id)
                    } label: {
                        ServerProfileRow(
                            profile: profile,
                            isActive: appModel.selectedProfileID == profile.id,
                            environmentName: appModel.selectedProfileID == profile.id ? appModel.selectedEnvironmentName : nil
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 22))
    }

    private func infoChip(_ title: String, _ value: String, systemImage: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 18))
    }

    private func statusCard(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 18))
    }

    private func dockhandDetailRows(_ dockhand: DashboardHostSnapshot.Dockhand) -> [(String, String)] {
        [
            (String(localized: "Version"), dockhand.version),
            (String(localized: "Build"), dockhand.build),
            (String(localized: "Commit"), dockhand.commit),
            (String(localized: "Runtime"), dockhand.runtime),
            (String(localized: "Database"), dockhand.database)
        ].compactMap { title, value in
            guard let value, !value.isEmpty else { return nil }
            return (title, value)
        }
    }

    private func detailGroup(_ title: String, systemImage: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ForEach(rows, id: \.0) { row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.0)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(row.1)
                        .font(.footnote.weight(.medium))
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(height: 1)
    }
}

private struct ServerProfileRow: View {
    let profile: DockhandServerProfile
    let isActive: Bool
    let environmentName: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: isActive ? "server.rack" : "circle.grid.3x3.fill")
                .font(.headline)
                .foregroundStyle(isActive ? .blue : .secondary)
                .frame(width: 38, height: 38)
                .glassEffect(.regular.tint(.white.opacity(0.05)), in: .circle)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(profile.name)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    if isActive {
                        Text(String(localized: "ACTIVE"))
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .foregroundStyle(.blue)
                            .glassEffect(.regular.tint(.blue.opacity(0.12)), in: .capsule)
                    }
                }

                Text(profile.baseURL)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let environmentName, isActive {
                    Text(String(format: String(localized: "Environment: %@"), locale: Locale.current, environmentName))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 20))
    }
}

private struct ServerProfileDetailView: View {
    let appModel: AppModel
    let profileID: String?

    @Environment(\.dismiss) private var dismiss

    @State private var draftName = ""
    @State private var draftBaseURL = "http://"
    @State private var draftToken = ""
    @State private var statusMessage: String?
    @State private var isSaving = false
    @State private var showDeleteConfirmation = false

    private var editingProfile: DockhandServerProfile? {
        guard let profileID else { return nil }
        return appModel.serverProfiles.first(where: { $0.id == profileID })
    }

    private var isActive: Bool {
        appModel.selectedProfileID == profileID
    }

    private var canSave: Bool {
        !isSaving && !draftBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let editingProfile {
                    detailsCard(editingProfile)
                }

                connectionCard

                if let statusMessage {
                    statusCard(statusMessage)
                }

                actionPanel
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(editingProfile == nil ? String(localized: "New Server") : String(localized: "Server Details"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await saveProfile() }
                } label: {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(editingProfile == nil ? String(localized: "Create") : String(localized: "Save"))
                    }
                }
                .disabled(!canSave)
            }
        }
        .task(id: profileID) {
            loadDraft()
        }
        .confirmationDialog(String(localized: "Delete server?"), isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button(String(localized: "Delete"), role: .destructive) {
                Task { await deleteProfile() }
            }
        } message: {
            Text(String(localized: "This removes the saved URL, token and per-server environment selection."))
        }
    }

    private func detailsCard(_ profile: DockhandServerProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            detailRow(String(localized: "Server ID"), value: profile.id, monospaced: true)
            divider
            detailRow(String(localized: "Active"), value: isActive ? String(localized: "Yes") : String(localized: "No"))
            if isActive {
                divider
                detailRow(String(localized: "Environment"), value: appModel.selectedEnvironmentName)
            }
        }
        .padding(18)
        .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 22))
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardSectionTitle(String(localized: "Connection"))

            editorField(String(localized: "Name"), text: $draftName)
                .textInputAutocapitalization(.words)

            editorField(String(localized: "Base URL"), text: $draftBaseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            secureEditorField(String(localized: "Bearer token (optional)"), text: $draftToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(18)
        .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 22))
    }

    private func statusCard(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 18))
    }

    private var actionPanel: some View {
        VStack(spacing: 12) {
            if let profileID, !isActive {
                Button {
                    Task {
                        await appModel.selectServerProfile(profileID, forceEnvironmentReset: true)
                        statusMessage = appModel.environmentError ?? String(localized: "Server changed")
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        Text(String(localized: "Use this server"))
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.glass)
            }

            if profileID != nil {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text(String(localized: "Delete server"))
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .foregroundStyle(.red)
                .disabled(appModel.serverProfiles.count <= 1 && isActive)
            }
        }
    }

    private func cardSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func detailRow(_ title: String, value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(monospaced ? .footnote.monospaced() : .body)
                .foregroundStyle(.primary)
                .lineLimit(monospaced ? 2 : 1)
                .textSelection(.enabled)
        }
    }

    private func editorField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            TextField(title, text: text)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func secureEditorField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            SecureField(title, text: text)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(height: 1)
    }

    private func loadDraft() {
        if let editingProfile {
            draftName = editingProfile.name
            draftBaseURL = editingProfile.baseURL
            draftToken = KeychainStore.readToken(profileID: editingProfile.id) ?? ""
        } else {
            draftName = ""
            draftBaseURL = "http://"
            draftToken = ""
        }
        statusMessage = nil
    }

    @MainActor
    private func saveProfile() async {
        isSaving = true
        defer { isSaving = false }

        await appModel.saveServerProfile(
            profileID: profileID,
            name: draftName,
            baseURLText: draftBaseURL,
            token: draftToken,
            makeActive: true
        )
        statusMessage = appModel.environmentError ?? String(localized: "Server saved")
        dismiss()
    }

    @MainActor
    private func deleteProfile() async {
        guard let profileID else { return }

        await appModel.deleteServerProfile(profileID)
        dismiss()
    }
}
