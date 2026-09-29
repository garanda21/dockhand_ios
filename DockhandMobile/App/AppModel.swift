import DockhandAPI
import Foundation
import Observation

struct DockhandConnectionScope: Hashable, Sendable {
    var profileID: String?
    var environmentID: Int?
}

enum DockhandServerAddress {
    static func normalizedURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }

        components.scheme = scheme
        if components.path == "/" {
            components.path = ""
        } else if components.path.count > 1 {
            components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            components.path = components.path.isEmpty ? "" : "/\(components.path)"
        }
        return components.url
    }
}

@MainActor
@Observable
final class AppModel {
    var serverProfiles: [DockhandServerProfile]
    var selectedProfileID: String?
    var token: String
    var customHeaders: [DockhandCustomHeader]
    var environments: [Components.Schemas.Environment] = []
    var selectedEnvironmentID: Int?
    var isLoadingEnvironments = false
    var environmentError: String?
    var lastHealthStatus: String?
    private(set) var dashboardRefreshRevision = 0

    init() {
        let storedProfiles = PreferencesStore.serverProfiles
        let storedProfileID = PreferencesStore.selectedProfileID
        let resolvedProfileID = storedProfileID.flatMap { selectedID in
            storedProfiles.contains(where: { $0.id == selectedID }) ? selectedID : nil
        } ?? storedProfiles.first?.id
        if storedProfileID != resolvedProfileID {
            PreferencesStore.selectedProfileID = resolvedProfileID
        }
        if let resolvedProfileID {
            KeychainStore.migrateLegacyTokenIfNeeded(to: resolvedProfileID)
        }
        let resolvedToken = resolvedProfileID.flatMap { KeychainStore.readToken(profileID: $0) } ?? ""
        let resolvedHeaders = resolvedProfileID.map { KeychainStore.readCustomHeaders(profileID: $0) } ?? []
        let resolvedEnvironmentID = resolvedProfileID.flatMap { PreferencesStore.selectedEnvironmentID(for: $0) }

        self.serverProfiles = storedProfiles
        self.selectedProfileID = resolvedProfileID
        self.token = resolvedToken
        self.customHeaders = resolvedHeaders
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
        selectedProfile.flatMap { DockhandServerAddress.normalizedURL(from: $0.baseURL) }
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

    var connectionScope: DockhandConnectionScope {
        DockhandConnectionScope(profileID: selectedProfileID, environmentID: selectedEnvironmentID)
    }

    /// Builds a service carrying the active profile's token and custom headers.
    func service(baseURL: URL) -> DockhandService {
        DockhandService(baseURL: baseURL, token: token, customHeaders: customHeaders)
    }

    func isCurrentScope(_ scope: DockhandConnectionScope) -> Bool {
        connectionScope == scope
    }

    func environment(for scope: DockhandConnectionScope) -> Components.Schemas.Environment? {
        guard scope.profileID == selectedProfileID else { return nil }
        return environments.first(where: { $0.id == scope.environmentID })
    }

    func bootstrap() async {
        await refreshEnvironments(forceEnvironmentReset: false)
    }

    /// Persists the profile immediately. Reconnecting runs in the background so
    /// an unreachable server never blocks the editor.
    func saveServerProfile(
        profileID: String?,
        name: String,
        baseURLText: String,
        token: String,
        customHeaders: [DockhandCustomHeader] = [],
        makeActive: Bool = true
    ) {
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
        KeychainStore.writeCustomHeaders(DockhandCustomHeaderValidator.sanitized(customHeaders), profileID: targetID)

        if makeActive || selectedProfileID == nil {
            Task { await selectServerProfile(targetID, forceEnvironmentReset: true) }
        }
    }

    func deleteServerProfile(_ profileID: String) async {
        serverProfiles.removeAll { $0.id == profileID }
        PreferencesStore.serverProfiles = serverProfiles
        PreferencesStore.removeSelectedEnvironmentID(for: profileID)
        PreferencesStore.removeCachedDashboardSnapshots(for: profileID)
        KeychainStore.deleteToken(profileID: profileID)
        KeychainStore.deleteCustomHeaders(profileID: profileID)

        if selectedProfileID == profileID {
            selectedProfileID = serverProfiles.first?.id
            PreferencesStore.selectedProfileID = selectedProfileID
            token = selectedProfileID.flatMap { KeychainStore.readToken(profileID: $0) } ?? ""
            customHeaders = selectedProfileID.map { KeychainStore.readCustomHeaders(profileID: $0) } ?? []
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
        customHeaders = KeychainStore.readCustomHeaders(profileID: profileID)
        selectedEnvironmentID = PreferencesStore.selectedEnvironmentID(for: profileID)
        environments = []
        environmentError = nil
        lastHealthStatus = nil
        await refreshEnvironments(forceEnvironmentReset: true)
    }

    func refreshEnvironments(forceEnvironmentReset: Bool = false) async {
        guard selectedProfile != nil else {
            environmentError = nil
            environments = []
            lastHealthStatus = nil
            return
        }

        guard let baseURL = normalizedBaseURL,
              let profileID = selectedProfile?.id else {
            environmentError = String(localized: "Invalid Dockhand URL")
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
            let service = self.service(baseURL: baseURL)
            do {
                lastHealthStatus = try await service.fetchHealthStatus()
            } catch {
                throw DockhandConnectionStageError(stage: .health, underlying: error)
            }

            let loaded: [Components.Schemas.Environment]
            do {
                loaded = try await service.fetchEnvironments()
            } catch {
                throw DockhandConnectionStageError(stage: .environments, underlying: error)
            }
            environments = loaded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            let preferredEnvironmentID = if forceEnvironmentReset {
                PreferencesStore.selectedEnvironmentID(for: profileID) ?? selectedEnvironmentID
            } else {
                selectedEnvironmentID
            }

            if let preferredEnvironmentID,
               environments.contains(where: { $0.id == preferredEnvironmentID }) {
                selectedEnvironmentID = preferredEnvironmentID
            } else {
                selectedEnvironmentID = environments.first?.id
            }

            PreferencesStore.setSelectedEnvironmentID(selectedEnvironmentID, for: profileID)
        } catch {
            guard !error.isDockhandCancellation else { return }
            environmentError = error.dockhandUserFacingMessage
            environments = []
        }
    }

    /// Checks a draft configuration without saving it, so users can verify
    /// proxy headers before committing them.
    func testConnection(
        baseURLText: String,
        token: String,
        customHeaders: [DockhandCustomHeader]
    ) async -> Result<Int, Error> {
        guard let baseURL = DockhandServerAddress.normalizedURL(from: baseURLText) else {
            return .failure(DockhandServiceError.message(String(localized: "Invalid Dockhand URL")))
        }

        let service = DockhandService(baseURL: baseURL, token: token, customHeaders: customHeaders)
        // Sessions wait for connectivity (needed for the local network prompt),
        // so an unknown host would otherwise hang until the resource timeout.
        return await withTaskGroup(of: Result<Int, Error>?.self) { group in
            group.addTask { await Self.runConnectionTest(service) }
            group.addTask {
                try? await Task.sleep(for: Self.connectionTestTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failure(DockhandConnectionStageError(stage: .health, underlying: URLError(.timedOut)))
        }
    }

    static let connectionTestTimeout: Duration = .seconds(20)

    private nonisolated static func runConnectionTest(_ service: DockhandService) async -> Result<Int, Error> {
        do {
            do {
                _ = try await service.fetchHealthStatus()
            } catch {
                throw DockhandConnectionStageError(stage: .health, underlying: error)
            }
            do {
                return .success(try await service.fetchEnvironments().count)
            } catch {
                throw DockhandConnectionStageError(stage: .environments, underlying: error)
            }
        } catch {
            return .failure(error)
        }
    }

    func selectEnvironment(_ environmentID: Int) {
        guard selectedEnvironmentID != environmentID else { return }
        selectedEnvironmentID = environmentID
        if let profileID = selectedProfile?.id {
            PreferencesStore.setSelectedEnvironmentID(environmentID, for: profileID)
        }
    }

    func requestDashboardRefresh() {
        dashboardRefreshRevision &+= 1
    }
}
