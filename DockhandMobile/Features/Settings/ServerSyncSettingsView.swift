import SwiftUI

struct ServerSyncSettingsView: View {
    let appModel: AppModel
    @State private var confirmDisable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(get: { appModel.serverSync.enabled }, set: { enabled in
                if enabled {
                    do { try appModel.serverSync.enable() }
                    catch { appModel.serverSync.error = String(localized: "Could not enable iCloud sync. Check your iCloud account and iCloud Keychain settings, then try again.") }
                } else { confirmDisable = true }
            })) {
                Label(String(localized: "Sync servers with iCloud"), systemImage: "icloud")
            }
            Text(String(localized: "Sync server addresses, order, tokens and custom headers across your devices. Credentials use iCloud Keychain. Your selected server and environment stay on this device."))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !appModel.serverSync.pendingCredentials.isEmpty {
                Label(String(localized: "Some server credentials are unavailable. Wait for iCloud Keychain or edit the server."), systemImage: "key.icloud")
                    .font(.footnote)
            }
            if let error = appModel.serverSync.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .confirmationDialog(String(localized: "Turn off iCloud sync?"), isPresented: $confirmDisable, titleVisibility: .visible) {
            Button(String(localized: "Keep servers on this device")) {
                appModel.serverSync.disable(removeLocal: false)
            }
            Button(String(localized: "Remove servers from this device"), role: .destructive) {
                appModel.serverSync.disable(removeLocal: true)
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Choose whether to keep a local copy. Servers in iCloud and on your other devices will be kept."))
        }
    }
}
