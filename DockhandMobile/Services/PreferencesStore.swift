import Foundation

struct DockhandServerProfile: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    var baseURL: String

    init(id: String = UUID().uuidString, name: String, baseURL: String) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
    }
}

struct CachedDashboardSnapshot: Codable, Hashable, Sendable {
    var snapshot: DashboardEnvironmentSnapshot
    var host: DashboardHostSnapshot?
    var lastUpdated: Date
}

@MainActor
enum PreferencesStore {
    private static let defaults = UserDefaults.standard
    private static let profilesKey = "dockhand.serverProfiles"
    private static let selectedProfileKey = "dockhand.selectedProfileID"
    private static let selectedEnvironmentsKey = "dockhand.selectedEnvironmentIDsByProfile"
    private static let dashboardSnapshotsKey = "dockhand.dashboardSnapshotsByScope"

    private static let legacyBaseURLKey = "dockhand.baseURL"
    private static let legacySelectedEnvironmentKey = "dockhand.selectedEnvironmentID"

    static var serverProfiles: [DockhandServerProfile] {
        get {
            if let data = defaults.data(forKey: profilesKey),
               let decoded = try? JSONDecoder().decode([DockhandServerProfile].self, from: data),
               !decoded.isEmpty {
                return decoded
            }

            let migrated = migratedLegacyProfiles()
            if !migrated.isEmpty {
                saveProfiles(migrated)
                if selectedProfileID == nil {
                    selectedProfileID = migrated.first?.id
                }
            }
            return migrated
        }
        set {
            saveProfiles(newValue)
        }
    }

    static var selectedProfileID: String? {
        get { defaults.string(forKey: selectedProfileKey) }
        set { defaults.set(newValue, forKey: selectedProfileKey) }
    }

    static func selectedEnvironmentID(for profileID: String) -> Int? {
        selectedEnvironmentIDsByProfile[profileID]
    }

    static func setSelectedEnvironmentID(_ environmentID: Int?, for profileID: String) {
        var values = selectedEnvironmentIDsByProfile
        values[profileID] = environmentID
        selectedEnvironmentIDsByProfile = values
    }

    static func removeSelectedEnvironmentID(for profileID: String) {
        var values = selectedEnvironmentIDsByProfile
        values.removeValue(forKey: profileID)
        selectedEnvironmentIDsByProfile = values
    }

    static func cachedDashboardSnapshot(profileID: String, environmentID: Int) -> CachedDashboardSnapshot? {
        cachedDashboardSnapshots[dashboardCacheKey(profileID: profileID, environmentID: environmentID)]
    }

    static func setCachedDashboardSnapshot(_ snapshot: CachedDashboardSnapshot?, profileID: String, environmentID: Int) {
        var values = cachedDashboardSnapshots
        values[dashboardCacheKey(profileID: profileID, environmentID: environmentID)] = snapshot
        cachedDashboardSnapshots = values
    }

    static func removeCachedDashboardSnapshots(for profileID: String) {
        var values = cachedDashboardSnapshots
        values = values.filter { key, _ in !key.hasPrefix("\(profileID):") }
        cachedDashboardSnapshots = values
    }

    private static var selectedEnvironmentIDsByProfile: [String: Int] {
        get {
            guard let data = defaults.data(forKey: selectedEnvironmentsKey),
                  let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else {
                return migratedLegacySelectedEnvironments()
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: selectedEnvironmentsKey)
            }
        }
    }

    private static var cachedDashboardSnapshots: [String: CachedDashboardSnapshot] {
        get {
            guard let data = defaults.data(forKey: dashboardSnapshotsKey),
                  let decoded = try? JSONDecoder().decode([String: CachedDashboardSnapshot].self, from: data) else {
                return [:]
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: dashboardSnapshotsKey)
            }
        }
    }

    private static func saveProfiles(_ profiles: [DockhandServerProfile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: profilesKey)
        }
    }

    private static func dashboardCacheKey(profileID: String, environmentID: Int) -> String {
        "\(profileID):\(environmentID)"
    }

    private static func migratedLegacyProfiles() -> [DockhandServerProfile] {
        guard let legacyURL = defaults.string(forKey: legacyBaseURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !legacyURL.isEmpty else {
            return []
        }
        return [DockhandServerProfile(name: "Primary", baseURL: legacyURL)]
    }

    private static func migratedLegacySelectedEnvironments() -> [String: Int] {
        guard let profileID = selectedProfileID ?? serverProfiles.first?.id,
              let environmentID = defaults.object(forKey: legacySelectedEnvironmentKey) as? Int else {
            return [:]
        }
        let migrated = [profileID: environmentID]
        if let data = try? JSONEncoder().encode(migrated) {
            defaults.set(data, forKey: selectedEnvironmentsKey)
        }
        return migrated
    }
}
