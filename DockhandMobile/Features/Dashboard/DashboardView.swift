import DockhandAPI
import SwiftUI

struct DashboardView: View {
    let appModel: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                EnvironmentHeaderBar(appModel: appModel)

                if let environment = appModel.selectedEnvironment {
                    summaryCard(environment: environment)
                    featureHints
                } else {
                    emptyState
                }
            }
            .padding()
        }
        .navigationTitle("Dockhand")
        .navigationBarTitleDisplayMode(.large)
        .background(backgroundGradient)
    }

    private func summaryCard(environment: Components.Schemas.Environment) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(environment.name)
                .font(.title2.weight(.semibold))
            Text(environment.hostSummary)
                .font(.body)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                summaryMetric("Protocol", environment._protocol.uppercased())
                summaryMetric("Port", "\(environment.port)")
                summaryMetric("Type", environment.connectionType)
            }
        }
        .padding(20)
        .glassEffect(.regular.tint(.white.opacity(0.04)), in: .rect(cornerRadius: 24))
    }

    private func summaryMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var featureHints: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ready")
                .font(.headline)
            Text("Use the environment picker to switch context instantly. Containers, stacks and images reload against the selected environment.")
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 24))
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No environment selected",
            systemImage: "globe.badge.chevron.backward",
            description: Text("Configure Dockhand in Settings or refresh the environment list.")
        )
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    Color(uiColor: .systemGroupedBackground),
                    Color(uiColor: .secondarySystemGroupedBackground),
                    Color(red: 0.08, green: 0.10, blue: 0.16)
                ]
                : [
                    Color(red: 0.96, green: 0.98, blue: 1.0),
                    Color(red: 0.90, green: 0.94, blue: 0.98)
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}
