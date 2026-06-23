import DockhandAPI
import SwiftUI

struct EnvironmentHeaderBar: View {
    let appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.secondary)
                Text(appModel.selectedProfileName)
                    .font(.subheadline.weight(.semibold))
                if let host = appModel.normalizedBaseURL?.host(), !host.isEmpty {
                    Text(host)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 12) {
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
                            .font(.headline)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .id(menuIdentity)
                .buttonStyle(.glassProminent)
                .disabled(appModel.environments.isEmpty)

                Spacer(minLength: 0)

                if appModel.isLoadingEnvironments {
                    ProgressView()
                } else if let lastHealthStatus {
                    Label(lastHealthStatus, systemImage: "heart.text.square")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(lastHealthStatus == "ok" ? .green : .secondary)
                }
            }

            if let environment = appModel.selectedEnvironment {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(environment.metadataChips, id: \.self) { chip in
                            Text(chip)
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .glassEffect(.regular.tint(.white.opacity(0.06)).interactive(), in: .capsule)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if let error = appModel.environmentError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(.clear)
        .glassEffect(.regular.tint(.white.opacity(0.03)), in: .rect(cornerRadius: 22))
    }

    private var lastHealthStatus: String? {
        appModel.lastHealthStatus?.uppercased()
    }

    private var menuIdentity: String {
        let environmentIDs = appModel.environments.map(\.id).map(String.init).joined(separator: ",")
        return "\(appModel.selectedProfileID ?? "none")|\(environmentIDs)"
    }
}
