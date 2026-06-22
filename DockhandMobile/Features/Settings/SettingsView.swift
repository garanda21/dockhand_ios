import SwiftUI

struct SettingsView: View {
    let appModel: AppModel

    @State private var editingProfileID: String?
    @State private var draftName = ""
    @State private var draftBaseURL = ""
    @State private var draftToken = ""
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section("Servers") {
                ForEach(appModel.serverProfiles) { profile in
                    Button {
                        loadDraft(from: profile)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name)
                                    .foregroundStyle(.primary)
                                Text(profile.baseURL)
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if appModel.selectedProfileID == profile.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }

                Button {
                    startNewProfile()
                } label: {
                    Label("Add server", systemImage: "plus")
                }
            }

            Section(editingProfileID == nil ? "New server" : "Edit server") {
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
                Button(editingProfileID == nil ? "Save server" : "Save changes") {
                    Task {
                        await appModel.saveServerProfile(
                            profileID: editingProfileID,
                            name: draftName,
                            baseURLText: draftBaseURL,
                            token: draftToken,
                            makeActive: true
                        )
                        if let selected = appModel.selectedProfile {
                            loadDraft(from: selected)
                        }
                        statusMessage = appModel.environmentError ?? "Server saved"
                    }
                }
                .disabled(draftBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let editingProfileID {
                    Button("Use this server") {
                        Task {
                            await appModel.selectServerProfile(editingProfileID, forceEnvironmentReset: true)
                            statusMessage = appModel.environmentError ?? "Server changed"
                        }
                    }

                    Button("Delete server", role: .destructive) {
                        Task {
                            await appModel.deleteServerProfile(editingProfileID)
                            if let selected = appModel.selectedProfile {
                                loadDraft(from: selected)
                            } else {
                                startNewProfile()
                            }
                            statusMessage = "Server deleted"
                        }
                    }
                    .disabled(appModel.serverProfiles.count <= 1 && appModel.selectedProfileID == editingProfileID)
                }

                Button("Refresh active server") {
                    Task {
                        await appModel.refreshEnvironments(forceEnvironmentReset: false)
                        statusMessage = appModel.environmentError ?? "Server refreshed"
                    }
                }
                .disabled(appModel.selectedProfile == nil)
            }

            if let selectedProfile = appModel.selectedProfile {
                Section("Active server") {
                    LabeledContent("Name", value: selectedProfile.name)
                    LabeledContent("URL", value: selectedProfile.baseURL)
                    LabeledContent("Environment", value: appModel.selectedEnvironmentName)
                }
            }

            if let statusMessage {
                Section("Status") {
                    Text(statusMessage)
                }
            }
        }
        .navigationTitle("Settings")
        .task {
            if let selected = appModel.selectedProfile {
                loadDraft(from: selected)
            } else {
                startNewProfile()
            }
        }
    }

    private func loadDraft(from profile: DockhandServerProfile) {
        editingProfileID = profile.id
        draftName = profile.name
        draftBaseURL = profile.baseURL
        draftToken = KeychainStore.readToken(profileID: profile.id) ?? ""
    }

    private func startNewProfile() {
        editingProfileID = nil
        draftName = ""
        draftBaseURL = "http://"
        draftToken = ""
    }
}
