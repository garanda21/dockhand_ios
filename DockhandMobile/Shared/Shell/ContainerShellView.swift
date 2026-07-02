import SwiftUI

struct ContainerShellView: View {
    let target: ContainerShellTarget
    let scope: DockhandConnectionScope
    let appModel: AppModel

    @State private var store = ContainerShellStore()
    @State private var fontSize: CGFloat = 14

    private var isCurrentScope: Bool {
        appModel.isCurrentScope(scope)
    }

    private var canConnect: Bool {
        isCurrentScope && !store.isConnected && (store.shellDetection?.hasAvailableShells ?? true)
    }

    var body: some View {
        VStack(spacing: 0) {
            shellHeader
                .padding(.horizontal)
                .padding(.vertical, 12)

            Divider()

            terminalPanel
        }
        .navigationTitle(target.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Font size", selection: $fontSize) {
                        Text("12 px").tag(CGFloat(12))
                        Text("14 px").tag(CGFloat(14))
                        Text("16 px").tag(CGFloat(16))
                        Text("18 px").tag(CGFloat(18))
                    }
                } label: {
                    Image(systemName: "textformat.size")
                }
            }
        }
        .task(id: "\(target.id)-\(scope.profileID ?? "none")-\(scope.environmentID ?? -1)") {
            store.configure(target: target, scope: scope)
            guard isCurrentScope else {
                store.status = .disconnected
                return
            }
            await store.detectShells(target: target, appModel: appModel)
        }
        .onDisappear {
            store.disconnect()
        }
    }

    private var shellHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !isCurrentScope {
                Text("Server or environment changed. Go back and reopen this shell for the active context.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 10) {
                statusBadge
                Spacer()
                Button {
                    store.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.glass)

                Button {
                    if store.isConnected {
                        store.disconnect()
                    } else {
                        Task { await store.connect(target: target, appModel: appModel) }
                    }
                } label: {
                    Label(store.isConnected ? "Disconnect" : "Connect", systemImage: store.isConnected ? "cable.connector.slash" : "cable.connector")
                }
                .buttonStyle(.glassProminent)
                .disabled(store.isConnected ? false : !canConnect)
            }

            HStack(spacing: 12) {
                shellPicker
                userPicker
            }

            customUserRow

            if let error = store.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.isConnected ? .green : .secondary)
                .frame(width: 8, height: 8)
            Text(store.status.localizedLabel)
                .font(.subheadline.weight(.semibold))
            if store.isDetectingShells {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .foregroundStyle(store.isConnected ? .green : .secondary)
    }

    private var shellPicker: some View {
        Picker("Shell", selection: $store.selectedShell) {
            if let detection = store.shellDetection {
                ForEach(detection.allShells, id: \.path) { shell in
                    Text(shell.available ? shell.label : "\(shell.label) unavailable")
                        .tag(shell.path)
                        .disabled(!shell.available)
                }
            } else {
                Text("Shell (sh)").tag("/bin/sh")
                Text("Bash").tag("/bin/bash")
                Text("Zsh").tag("/bin/zsh")
                Text("Ash").tag("/bin/ash")
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(store.isConnected || store.isDetectingShells)
    }

    private var userPicker: some View {
        Picker("User", selection: $store.selectedUser) {
            ForEach(ContainerShellUser.presets, id: \.value) { option in
                Text(option.label).tag(option.value)
            }
            ForEach(store.customUsers, id: \.self) { user in
                Text(user).tag(user)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(store.isConnected)
    }

    private var customUserRow: some View {
        HStack(spacing: 8) {
            TextField("Add custom user", text: $store.customUserInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .disabled(store.isConnected)
                .onSubmit {
                    store.commitCustomUser()
                }

            Button("Use") {
                store.commitCustomUser()
            }
            .buttonStyle(.glass)
            .disabled(store.customUserInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isConnected)
        }
    }

    private var terminalPanel: some View {
        SwiftTermContainerView(
            feedEvent: store.feedEvent,
            fontSize: fontSize,
            onInput: { store.sendInput($0) },
            onResize: { cols, rows in store.sendResize(cols: cols, rows: rows) }
        )
        .background(.black)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}
