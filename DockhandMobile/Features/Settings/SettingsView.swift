import SwiftUI

struct SettingsView: View {
    let appModel: AppModel

    @State private var statusMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                activeServerCard
                serverLibraryCard

                if let statusMessage {
                    statusCard(statusMessage)
                }
            }
            .padding()
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
    }

    private var activeServerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Active server")
                        .font(.headline.weight(.semibold))
                    Text("Quick context and switching.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)
                if let health = appModel.lastHealthStatus {
                    infoChip("Status", health.uppercased(), systemImage: "heart.text.square", tint: health == "ok" ? .green : .secondary)
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
                                statusMessage = appModel.environmentError ?? "Active server refreshed"
                            }
                        } label: {
                            Label("Refresh server", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                            .frame(maxWidth: 120)
                    }

                    
                }
            } else {
                ContentUnavailableView(
                    "No server configured",
                    systemImage: "server.rack",
                    description: Text("Add a Dockhand server to start switching environments.")
                )

                NavigationLink {
                    ServerProfileDetailView(appModel: appModel, profileID: nil)
                } label: {
                    Label("Add server", systemImage: "plus")
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
                        statusMessage = appModel.environmentError ?? "Server changed"
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
                    Text("Switch server")
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

    private var serverLibraryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server library")
                        .font(.headline.weight(.semibold))
                    Text("Each server keeps its own details, token and selected environment.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                NavigationLink {
                    ServerProfileDetailView(appModel: appModel, profileID: nil)
                } label: {
                    Label("New", systemImage: "plus")
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
                        Text("ACTIVE")
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
                    Text("Environment: \(environmentName)")
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

    var body: some View {
        Form {
            if let editingProfile {
                Section {
                    LabeledContent("Server ID", value: editingProfile.id)
                        .font(.footnote.monospaced())
                    LabeledContent("Active", value: isActive ? "Yes" : "No")
                    if isActive {
                        LabeledContent("Environment", value: appModel.selectedEnvironmentName)
                    }
                }
            }

            Section("Connection") {
                TextField("Name", text: $draftName)
                    .textInputAutocapitalization(.words)

                TextField("Base URL", text: $draftBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                SecureField("Bearer token (optional)", text: $draftToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                Button {
                    Task { await saveProfile() }
                } label: {
                    if isSaving {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(editingProfile == nil ? "Create server" : "Save changes")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(isSaving || draftBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let profileID, !isActive {
                    Button("Use this server") {
                        Task {
                            await appModel.selectServerProfile(profileID, forceEnvironmentReset: true)
                            statusMessage = appModel.environmentError ?? "Server changed"
                        }
                    }
                }

                if profileID != nil {
                    Button("Delete server", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                    .disabled(appModel.serverProfiles.count <= 1 && isActive)
                }
            }

            if let statusMessage {
                Section("Status") {
                    Text(statusMessage)
                }
            }
        }
        .navigationTitle(editingProfile == nil ? "New Server" : "Server Details")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: profileID) {
            loadDraft()
        }
        .confirmationDialog("Delete server?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await deleteProfile() }
            }
        } message: {
            Text("This removes the saved URL, token and per-server environment selection.")
        }
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
        statusMessage = appModel.environmentError ?? "Server saved"
        dismiss()
    }

    @MainActor
    private func deleteProfile() async {
        guard let profileID else { return }

        await appModel.deleteServerProfile(profileID)
        dismiss()
    }
}
