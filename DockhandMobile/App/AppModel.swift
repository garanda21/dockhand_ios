import DockhandAPI
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var serverProfiles: [DockhandServerProfile]
    var selectedProfileID: String?
    var token: String
    var environments: [Components.Schemas.Environment] = []
    var selectedEnvironmentID: Int?
    var isLoadingEnvironments = false
    var environmentError: String?
    var lastHealthStatus: String?

    init() {
        let storedProfiles = PreferencesStore.serverProfiles
        let resolvedProfileID = PreferencesStore.selectedProfileID ?? storedProfiles.first?.id
        let resolvedToken = resolvedProfileID.flatMap { KeychainStore.readToken(profileID: $0) } ?? ""
        let resolvedEnvironmentID = resolvedProfileID.flatMap { PreferencesStore.selectedEnvironmentID(for: $0) }

        self.serverProfiles = storedProfiles
        self.selectedProfileID = resolvedProfileID
        self.token = resolvedToken
        self.environments = []
        self.selectedEnvironmentID = resolvedEnvironmentID
        self.isLoadingEnvironments = false
        self.environmentError = nil
        self.lastHealthStatus = nil
    }

    var selectedProfile: DockhandServerProfile? {
        serverProfiles.first(where: { $0.id == selectedProfileID }) ?? serverProfiles.first
    }

    var selectedProfileName: String {
        selectedProfile?.name ?? "No server"
    }

    var baseURLText: String {
        selectedProfile?.baseURL ?? ""
    }

    var hasConnection: Bool {
        normalizedBaseURL != nil
    }

    var normalizedBaseURL: URL? {
        guard let rawURL = selectedProfile?.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: rawURL),
              let scheme = url.scheme,
              !scheme.isEmpty else {
            return nil
        }
        return url
    }

    var selectedEnvironment: Components.Schemas.Environment? {
        environments.first(where: { $0.id == selectedEnvironmentID }) ?? environments.first
    }

    var selectedEnvironmentName: String {
        selectedEnvironment?.name ?? "No environment"
    }

    var connectionScopeID: String {
        "\(selectedProfileID ?? "none"):\(selectedEnvironmentID ?? -1)"
    }

    func bootstrap() async {
        await refreshEnvironments(forceEnvironmentReset: true)
    }

    func saveServerProfile(profileID: String?, name: String, baseURLText: String, token: String, makeActive: Bool = true) async {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedURL = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = cleanedName.isEmpty ? cleanedURL : cleanedName

        let targetID = profileID ?? UUID().uuidString
        let profile = DockhandServerProfile(id: targetID, name: resolvedName, baseURL: cleanedURL)

        if let index = serverProfiles.firstIndex(where: { $0.id == targetID }) {
            serverProfiles[index] = profile
        } else {
            serverProfiles.append(profile)
        }

        serverProfiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        PreferencesStore.serverProfiles = serverProfiles
        KeychainStore.writeToken(token, profileID: targetID)

        if makeActive || selectedProfileID == nil {
            await selectServerProfile(targetID, forceEnvironmentReset: true)
        }
    }

    func deleteServerProfile(_ profileID: String) async {
        serverProfiles.removeAll { $0.id == profileID }
        PreferencesStore.serverProfiles = serverProfiles
        PreferencesStore.removeSelectedEnvironmentID(for: profileID)
        KeychainStore.deleteToken(profileID: profileID)

        if selectedProfileID == profileID {
            selectedProfileID = serverProfiles.first?.id
            PreferencesStore.selectedProfileID = selectedProfileID
            token = selectedProfileID.flatMap { KeychainStore.readToken(profileID: $0) } ?? ""
            selectedEnvironmentID = selectedProfileID.flatMap { PreferencesStore.selectedEnvironmentID(for: $0) }
            environments = []
            lastHealthStatus = nil
            environmentError = nil
            await refreshEnvironments(forceEnvironmentReset: true)
        }
    }

    func selectServerProfile(_ profileID: String, forceEnvironmentReset: Bool = false) async {
        guard selectedProfileID != profileID || forceEnvironmentReset else { return }

        selectedProfileID = profileID
        PreferencesStore.selectedProfileID = profileID
        token = KeychainStore.readToken(profileID: profileID) ?? ""
        selectedEnvironmentID = PreferencesStore.selectedEnvironmentID(for: profileID)
        environments = []
        environmentError = nil
        lastHealthStatus = nil
        await refreshEnvironments(forceEnvironmentReset: true)
    }

    func refreshEnvironments(forceEnvironmentReset: Bool = false) async {
        guard let baseURL = normalizedBaseURL,
              let profileID = selectedProfile?.id else {
            environmentError = "Invalid Dockhand URL"
            environments = []
            lastHealthStatus = nil
            return
        }

        isLoadingEnvironments = true
        environmentError = nil

        defer {
            isLoadingEnvironments = false
        }

        do {
            let service = DockhandService(baseURL: baseURL, token: token)
            lastHealthStatus = try await service.fetchHealthStatus()
            let loaded = try await service.fetchEnvironments()
            environments = loaded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            if forceEnvironmentReset || !environments.contains(where: { $0.id == selectedEnvironmentID }) {
                selectedEnvironmentID = environments.first?.id
            }

            PreferencesStore.setSelectedEnvironmentID(selectedEnvironmentID, for: profileID)
        } catch {
            environmentError = error.localizedDescription
            environments = []
        }
    }

    func selectEnvironment(_ environmentID: Int) {
        guard selectedEnvironmentID != environmentID else { return }
        selectedEnvironmentID = environmentID
        if let profileID = selectedProfile?.id {
            PreferencesStore.setSelectedEnvironmentID(environmentID, for: profileID)
        }
    }
}
