import DockhandAPI
import SwiftUI

extension EnvironmentValues {
    /// False where the layout shows the header elsewhere, such as the iPad sidebar footer.
    @Entry var showsEnvironmentHeader = true
}

struct EnvironmentHeaderBar: View {
    static let serverPickerKey = "showsServerPickerInHeader"

    let appModel: AppModel
    @Environment(\.showsEnvironmentHeader) private var showsEnvironmentHeader
    @AppStorage(serverPickerKey) private var showsServerPicker = false
    @State private var headerWidth: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var minimumInlineWidth: CGFloat = 300

    private var showsInlinePickers: Bool { headerWidth >= minimumInlineWidth }

    private var pickerLayout: AnyLayout {
        showsInlinePickers
            ? AnyLayout(HStackLayout(alignment: .center, spacing: 10))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
    }

    var body: some View {
        if showsEnvironmentHeader {
            header
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            // AnyLayout rearranges the same menus without duplicating or replacing them.
            // Choose by available width, so changing server names does not change layout.
            pickerLayout {
                serverInfo
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    environmentMenu
                    loadingIndicator
                }
                .frame(maxWidth: showsInlinePickers ? min(248, headerWidth / 2) : .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.width
            } action: { width in
                headerWidth = width
            }

            if let environment = appModel.selectedEnvironment {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        if let lastHealthStatus {
                            Label(lastHealthStatus, systemImage: "heart.text.square")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(lastHealthStatus == "ok" ? .green : .secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .glassEffect(.regular.tint(.white.opacity(0.04)), in: .capsule)
                        }
                        ForEach(environment.metadataChips, id: \.self) { chip in
                            Text(chip)
                                .font(.footnote)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .glassEffect(.regular.tint(.white.opacity(0.06)).interactive(), in: .capsule)
                        }
                    }
                }
            }

            if let error = appModel.environmentError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(.clear)
        .glassEffect(.regular.tint(.white.opacity(0.03)), in: .rect(cornerRadius: 20))
    }

    @ViewBuilder
    private var serverInfo: some View {
        if showsServerPicker && appModel.serverProfiles.count > 1 {
            Menu {
                ForEach(appModel.serverProfiles) { profile in
                    Button {
                        guard profile.id != appModel.selectedProfileID else { return }
                        Task { await appModel.selectServerProfile(profile.id, forceEnvironmentReset: true) }
                    } label: {
                        if appModel.selectedProfileID == profile.id {
                            Label(profile.name, systemImage: "checkmark")
                        } else {
                            Text(profile.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    serverLabel
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(String(localized: "Switch server"))
        } else {
            serverLabel
        }
    }

    private var serverLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(appModel.selectedProfileName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                if let host = appModel.normalizedBaseURL?.host(), !host.isEmpty {
                    Text(host)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var environmentMenu: some View {
        Menu {
            ForEach(appModel.environments, id: \.id) { environment in
                Button {
                    appModel.selectEnvironment(environment.id)
                } label: {
                    Label(environment.name, systemImage: appModel.selectedEnvironmentID == environment.id ? "checkmark.circle.fill" : "globe")
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "globe.europe.africa.fill")
                Text(appModel.isLoadingEnvironments && appModel.environments.isEmpty ? String(localized: "Loading environments…") : appModel.selectedEnvironmentName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .frame(minWidth: 0, maxWidth: 220, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
        }
        .id(menuIdentity)
        .buttonStyle(.glassProminent)
        .controlSize(.small)
        .disabled(appModel.environments.isEmpty)
    }

    private var loadingIndicator: some View {
        Group {
            if appModel.isLoadingEnvironments {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 28, height: 28)
    }

    private var lastHealthStatus: String? {
        appModel.lastHealthStatus?.uppercased()
    }

    private var menuIdentity: String {
        let environmentIDs = appModel.environments.map(\.id).map(String.init).joined(separator: ",")
        return "\(appModel.selectedProfileID ?? "none")|\(environmentIDs)"
    }
}

struct ExposedPortsGrid: View {
    let accesses: [PublishedPortAccess]
    let emptyText: String
    var minimumItemWidth: CGFloat = 120

    var body: some View {
        if accesses.isEmpty {
            Text(emptyText)
                .foregroundStyle(.secondary)
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: minimumItemWidth), spacing: 8, alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(accesses) { access in
                    if let destinationURL = access.destinationURL {
                        Link(destination: destinationURL) {
                            portChip(access.label, isInteractive: true)
                        }
                        .buttonStyle(.plain)
                    } else {
                        portChip(access.label, isInteractive: false)
                    }
                }
            }
        }
    }

    private func portChip(_ label: String, isInteractive: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isInteractive ? "safari" : "network")
                .font(.caption.weight(.semibold))
            Text(label)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(isInteractive ? .primary : .secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassEffect(.regular.tint(.white.opacity(isInteractive ? 0.08 : 0.04)).interactive(), in: .capsule)
    }
}
