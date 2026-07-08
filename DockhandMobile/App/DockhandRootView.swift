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

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                DashboardView(appModel: appModel) {
                    selectedTab = .settings
                }
            }
            .tabItem {
                Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent")
            }
            .tag(DockhandTab.dashboard)

            NavigationStack {
                ContainersView(appModel: appModel)
            }
            .tabItem {
                Label("Containers", systemImage: "shippingbox")
            }
            .tag(DockhandTab.containers)

            NavigationStack {
                StacksView(appModel: appModel)
            }
            .tabItem {
                Label("Stacks", systemImage: "square.3.layers.3d")
            }
            .tag(DockhandTab.stacks)

            NavigationStack {
                ImagesView(appModel: appModel)
            }
            .tabItem {
                Label("Images", systemImage: "photo.stack")
            }
            .tag(DockhandTab.images)

            NavigationStack {
                SettingsView(appModel: appModel)
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(DockhandTab.settings)
        }
        .task {
            if appModel.serverProfiles.isEmpty {
                selectedTab = .settings
            }
            await appModel.bootstrap()
        }
    }
}
