import DockhandAPI
import SwiftUI

struct EnvironmentHeaderBar: View {
    let appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
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
                    .padding(.vertical, 8)
                }
                .id(menuIdentity)
                .buttonStyle(.glassProminent)
                .disabled(appModel.environments.isEmpty)

                if appModel.isLoadingEnvironments {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28, height: 28)
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

    private var lastHealthStatus: String? {
        appModel.lastHealthStatus?.uppercased()
    }

    private var menuIdentity: String {
        let environmentIDs = appModel.environments.map(\.id).map(String.init).joined(separator: ",")
        return "\(appModel.selectedProfileID ?? "none")|\(environmentIDs)"
    }
}
