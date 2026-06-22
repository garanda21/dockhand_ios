import SwiftUI

struct DockhandRootView: View {
    @State private var appModel = AppModel()

    var body: some View {
        TabView {
            NavigationStack {
                DashboardView(appModel: appModel)
            }
            .tabItem {
                Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent")
            }

            NavigationStack {
                ContainersView(appModel: appModel)
            }
            .tabItem {
                Label("Containers", systemImage: "shippingbox")
            }

            NavigationStack {
                StacksView(appModel: appModel)
            }
            .tabItem {
                Label("Stacks", systemImage: "square.3.layers.3d")
            }

            NavigationStack {
                ImagesView(appModel: appModel)
            }
            .tabItem {
                Label("Images", systemImage: "photo.stack")
            }

            NavigationStack {
                SettingsView(appModel: appModel)
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .task {
            await appModel.bootstrap()
        }
    }
}
