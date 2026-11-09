import Foundation
import Observation

@MainActor
@Observable
final class ServerSyncStore {
    private(set) var enabled = UserDefaults.standard.bool(forKey: "dockhand.sync.enabled")
    private(set) var pendingCredentials = Set(UserDefaults.standard.stringArray(forKey: "dockhand.sync.pending") ?? [])
    var error: String?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let cloud = NSUbiquitousKeyValueStore.default
    @ObservationIgnored nonisolated(unsafe) private var observer: NSObjectProtocol?
    @ObservationIgnored private var records: [String: ServerSyncRecord] = [:]
    @ObservationIgnored private var dirty = Set(UserDefaults.standard.stringArray(forKey: "dockhand.sync.dirty") ?? [])
    @ObservationIgnored private var dirtyDates: [String: Date] = {
        guard let data = UserDefaults.standard.data(forKey: "dockhand.sync.dirtyDates") else { return [:] }
        return (try? JSONDecoder().decode([String: Date].self, from: data)) ?? [:]
    }()
    @ObservationIgnored private var owner: Data?
    private static let prefix = "server.v1."

    init() {
        owner = UserDefaults.standard.data(forKey: "dockhand.sync.owner")
        if let data = UserDefaults.standard.data(forKey: "dockhand.sync.records") {
            records = (try? JSONDecoder().decode([String: ServerSyncRecord].self, from: data)) ?? [:]
        }
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud, queue: .main
        ) { [weak self] notification in
            let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            Task { @MainActor [weak self] in
                guard let self, self.enabled else { return }
                if reason == NSUbiquitousKeyValueStoreQuotaViolationChange {
                    self.error = String(localized: "iCloud storage limit reached. Your servers remain saved locally.")
                } else {
                    self.refresh()
                }
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func enable() throws {
        guard let identity = FileManager.default.ubiquityIdentityToken else {
            throw CocoaError(.ubiquitousFileUnavailable)
        }
        let newOwner = try NSKeyedArchiver.archivedData(withRootObject: identity, requiringSecureCoding: false)
        // A different account starts a new journal; never upload the previous account's journal.
        if !sameAccount(identity) { records = [:] }
        owner = newOwner
        UserDefaults.standard.set(newOwner, forKey: "dockhand.sync.owner")
        cloud.synchronize()
        mergeRemote()
        for (position, profile) in PreferencesStore.serverProfiles.enumerated() where records[profile.id] == nil || dirty.contains(profile.id) {
            try publish(profile, position: position)
        }
        enabled = true
        UserDefaults.standard.set(true, forKey: "dockhand.sync.enabled")
        error = nil
        refresh()
    }

    func disable(removeLocal: Bool) {
        enabled = false
        UserDefaults.standard.set(false, forKey: "dockhand.sync.enabled")
        if removeLocal {
            for profile in PreferencesStore.serverProfiles {
                KeychainStore.deleteCredentials(profileID: profile.id)
                PreferencesStore.removeSelectedEnvironmentID(for: profile.id)
                PreferencesStore.removeCachedDashboardSnapshots(for: profile.id)
            }
            records = [:]
            dirty = []
            dirtyDates = [:]
            PreferencesStore.serverProfiles = []
            PreferencesStore.selectedProfileID = nil
        }
        if removeLocal { pendingCredentials = [] }
        persist()
        error = nil
        onChange?()
    }

    func save(_ profile: DockhandServerProfile, position: Int) {
        reloadParticipationIfNeeded()
        pendingCredentials.remove(profile.id)
        dirty.insert(profile.id)
        dirtyDates[profile.id] = max(Date(), (records[profile.id]?.modified ?? .distantPast).addingTimeInterval(0.001))
        persist()
        guard enabled else { return }
        guard let identity = FileManager.default.ubiquityIdentityToken, sameAccount(identity) else { refresh(); return }
        do { try publish(profile, position: position) }
        catch { self.error = String(localized: "Could not sync credentials. Your changes remain saved locally.") }
    }

    func reorder(_ profiles: [DockhandServerProfile]) {
        reloadParticipationIfNeeded()
        if enabled {
            guard let identity = FileManager.default.ubiquityIdentityToken, sameAccount(identity) else { refresh(); return }
        }
        for (position, profile) in profiles.enumerated() {
            guard var record = records[profile.id], !record.deleted else { continue }
            record.position = position
            record.orderModified = max(Date(), record.orderModified.addingTimeInterval(0.001))
            record.orderMutation = UUID().uuidString
            records[profile.id] = record
            if enabled { write(record) }
        }
        persist()
    }

    func delete(_ profile: DockhandServerProfile) {
        reloadParticipationIfNeeded()
        dirty.remove(profile.id)
        persist()
        guard enabled else { return }
        guard let identity = FileManager.default.ubiquityIdentityToken, sameAccount(identity) else { refresh(); return }
        var record = records[profile.id] ?? ServerSyncRecord(profile: profile, modified: .distantPast, mutation: "", credentialID: "", position: 0, deleted: false)
        record.deleted = true
        stamp(&record)
        write(record)
    }

    func foregroundRefresh() {
        if enabled { cloud.synchronize() }
        refresh()
    }

    func refresh() {
        let participationChanged = reloadParticipationIfNeeded()
        guard enabled else {
            if participationChanged { onChange?() }
            return
        }
        guard let identity = FileManager.default.ubiquityIdentityToken, sameAccount(identity) else {
            disable(removeLocal: false)
            error = String(localized: "Your iCloud account changed. Sync has been turned off; your local servers were kept.")
            return
        }
        mergeRemote()
        for (position, profile) in PreferencesStore.serverProfiles.enumerated() where dirty.contains(profile.id) {
            do { try publish(profile, position: position) }
            catch { self.error = String(localized: "Could not sync credentials. Your changes remain saved locally.") }
        }
        var profiles: [DockhandServerProfile] = []
        var pending: Set<String> = []
        for record in records.values.sorted(by: {
            $0.position == $1.position ? $0.profile.id < $1.profile.id : $0.position < $1.position
        }) {
            let id = record.profile.id
            if dirty.contains(id) { continue }
            if record.deleted {
                SyncedServerCredentials.deleteAll(profileID: id)
                KeychainStore.deleteCredentials(profileID: id)
                PreferencesStore.removeSelectedEnvironmentID(for: id)
                PreferencesStore.removeCachedDashboardSnapshots(for: id)
                continue
            }
            profiles.append(record.profile)
            do {
                if let credentials = try SyncedServerCredentials.read(record.credentialID) {
                    let local = try KeychainStore.credentialsForSync(profileID: id)
                    if local.token != credentials.token || local.headers != credentials.headers {
                        try KeychainStore.installSyncedCredentials(credentials, profileID: id)
                    }
                } else { pending.insert(id) }
            } catch { pending.insert(id) }
        }
        // Never discard a local edit whose secret could not be published.
        let known = Set(profiles.map(\.id))
        profiles += PreferencesStore.serverProfiles.filter { (records[$0.id] == nil || dirty.contains($0.id)) && !known.contains($0.id) }
        pendingCredentials = pending
        persist()
        PreferencesStore.serverProfiles = profiles
        onChange?()
    }

    /// Multiple windows can own an AppModel; a device-level opt-out applies to all of them.
    @discardableResult
    private func reloadParticipationIfNeeded() -> Bool {
        let defaults = UserDefaults.standard
        let storedEnabled = defaults.bool(forKey: "dockhand.sync.enabled")
        guard storedEnabled != enabled else { return false }
        enabled = storedEnabled
        owner = defaults.data(forKey: "dockhand.sync.owner")
        if let data = defaults.data(forKey: "dockhand.sync.records"),
           let stored = try? JSONDecoder().decode([String: ServerSyncRecord].self, from: data) { records = stored }
        dirty = Set(defaults.stringArray(forKey: "dockhand.sync.dirty") ?? [])
        if let data = defaults.data(forKey: "dockhand.sync.dirtyDates"),
           let dates = try? JSONDecoder().decode([String: Date].self, from: data) { dirtyDates = dates }
        pendingCredentials = Set(defaults.stringArray(forKey: "dockhand.sync.pending") ?? [])
        return true
    }

    private func publish(_ profile: DockhandServerProfile, position: Int) throws {
        let credentials = try KeychainStore.credentialsForSync(profileID: profile.id)
        if let edited = dirtyDates[profile.id], let remote = records[profile.id], remote.modified > edited {
            dirty.remove(profile.id)
            dirtyDates.removeValue(forKey: profile.id)
            persist()
            return
        }
        let credentialID = "\(profile.id).\(UUID().uuidString)"
        try credentials.write(credentialID)
        var record = ServerSyncRecord(profile: profile, modified: .distantPast, mutation: "", credentialID: credentialID, position: position, deleted: false)
        if let previous = records[profile.id] {
            record.position = previous.position
            record.orderModified = previous.orderModified
            record.orderMutation = previous.orderMutation
        } else {
            record.orderModified = Date()
            record.orderMutation = UUID().uuidString
        }
        stamp(&record)
        if let edited = dirtyDates[profile.id] { record.modified = edited }
        dirtyDates.removeValue(forKey: profile.id)
        dirty.remove(profile.id)
        write(record)
    }

    private func sameAccount(_ identity: any NSCoding & NSCopying & NSObjectProtocol) -> Bool {
        guard let owner, let decoder = try? NSKeyedUnarchiver(forReadingFrom: owner) else { return false }
        decoder.requiresSecureCoding = false
        decoder.decodingFailurePolicy = .setErrorAndReturn
        defer { decoder.finishDecoding() }
        guard let previous = decoder.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSObject else { return false }
        return previous.isEqual(identity)
    }

    private func stamp(_ record: inout ServerSyncRecord) {
        record.modified = max(Date(), (records[record.profile.id]?.modified ?? .distantPast).addingTimeInterval(0.001))
        record.mutation = UUID().uuidString
    }

    private func write(_ record: ServerSyncRecord) {
        records[record.profile.id] = record
        if let data = try? JSONEncoder().encode(record) { cloud.set(data, forKey: Self.prefix + record.profile.id) }
        persist()
    }

    private func mergeRemote() {
        for (key, value) in cloud.dictionaryRepresentation where key.hasPrefix(Self.prefix) {
            guard let data = value as? Data,
                  let remote = try? JSONDecoder().decode(ServerSyncRecord.self, from: data),
                  key == Self.prefix + remote.profile.id else { continue }
            let merged = records[remote.profile.id].map { ServerSyncRecord.merged($0, remote) } ?? remote
            records[remote.profile.id] = merged
            if merged != remote, let data = try? JSONEncoder().encode(merged) {
                cloud.set(data, forKey: key)
            }
        }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(Array(pendingCredentials), forKey: "dockhand.sync.pending")
        if let data = try? JSONEncoder().encode(dirtyDates) { UserDefaults.standard.set(data, forKey: "dockhand.sync.dirtyDates") }
        UserDefaults.standard.set(Array(dirty), forKey: "dockhand.sync.dirty")
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: "dockhand.sync.records") }
    }
}
