import SwiftUI

private enum DockhandTab: Hashable {
    case dashboard
    case containers
    case stacks
    case images
    case settings
}

struct DockhandRootView: View {
    @State private var appModel = AppModel()
    @State private var selectedTab: DockhandTab = .dashboard
    @State private var requestedContainerFilter = ContainerListFilter.all
    @State private var containerFilterRequestRevision = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Dashboard", systemImage: "gauge.with.dots.needle.67percent", value: DockhandTab.dashboard) {
                NavigationStack {
                    DashboardView(
                        appModel: appModel,
                        onOpenSettings: { selectedTab = .settings },
                        onOpenContainers: openContainers,
                        onOpenStacks: { selectedTab = .stacks },
                        onOpenImages: { selectedTab = .images }
                    )
                }
            }

            // List tabs own a NavigationSplitView, so they get no outer stack.
            Tab("Containers", systemImage: "shippingbox", value: DockhandTab.containers) {
                ContainersView(
                    appModel: appModel,
                    requestedFilter: requestedContainerFilter,
                    filterRequestRevision: containerFilterRequestRevision
                )
            }

            Tab("Stacks", systemImage: "square.3.layers.3d", value: DockhandTab.stacks) {
                StacksView(appModel: appModel)
            }

            Tab("Images", systemImage: "photo.stack", value: DockhandTab.images) {
                ImagesView(appModel: appModel)
            }

            Tab("Settings", systemImage: "gearshape", value: DockhandTab.settings) {
                NavigationStack {
                    SettingsView(appModel: appModel)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .task {
            if appModel.serverProfiles.isEmpty {
                selectedTab = .settings
            }
            await appModel.bootstrap()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await appModel.recoverConnectionIfNeeded() }
        }
    }

    private func openContainers(filter: ContainerListFilter) {
        requestedContainerFilter = filter
        containerFilterRequestRevision &+= 1
        selectedTab = .containers
    }
}
