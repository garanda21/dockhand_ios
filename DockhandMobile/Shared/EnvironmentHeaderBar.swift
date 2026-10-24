import DockhandAPI
import SwiftUI

extension EnvironmentValues {
    /// False where the layout shows the header elsewhere, such as the iPad sidebar footer.
    @Entry var showsEnvironmentHeader = true
}

struct EnvironmentHeaderBar: View {
    let appModel: AppModel
    @Environment(\.showsEnvironmentHeader) private var showsEnvironmentHeader

    var body: some View {
        if showsEnvironmentHeader {
            header
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Side by side when it fits; stack the picker below on narrow widths (iPhone Duo folded).
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    serverInfo
                    // Pin the picker to the trailing edge on wide layouts (iPhone Duo unfolded, iPad).
                    Spacer(minLength: 0)
                    environmentMenu
                    loadingIndicator
                }

                VStack(alignment: .leading, spacing: 10) {
                    serverInfo
                    HStack(spacing: 10) {
                        environmentMenu
                        loadingIndicator
                    }
                }
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

    private var serverInfo: some View {
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
                Text(appModel.selectedEnvironmentName)
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

    @ViewBuilder
    private var loadingIndicator: some View {
        if appModel.isLoadingEnvironments {
            ProgressView()
                .controlSize(.small)
                .frame(width: 28, height: 28)
        }
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
