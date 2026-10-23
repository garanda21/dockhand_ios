import SwiftUI

private enum DockhandSection: Hashable, CaseIterable {
    case dashboard
    case containers
    case stacks
    case images
    case settings

    var title: LocalizedStringKey {
        switch self {
        case .dashboard: "Dashboard"
        case .containers: "Containers"
        case .stacks: "Stacks"
        case .images: "Images"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .containers: "shippingbox"
        case .stacks: "square.3.layers.3d"
        case .images: "photo.stack"
        case .settings: "gearshape"
        }
    }
}

/// Regular width uses one three-column split view (sections, list, detail);
/// compact width uses a tab bar with a navigation stack per tab.
struct DockhandRootView: View {
    @State private var appModel = AppModel()
    @State private var section: DockhandSection? = .dashboard
    @State private var requestedContainerFilter = ContainerListFilter.all
    @State private var containerFilterRequestRevision = 0

    // Feature state lives here so both layouts share it across size class changes.
    @State private var containersStore = ContainersStore()
    @State private var stacksStore = StacksStore()
    @State private var imagesStore = ImagesStore()
    @State private var selectedContainerID: String?
    @State private var selectedStackName: String?
    @State private var selectedImageID: String?
    @State private var settingsPane: SettingsPane? = .activeServer

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                tabLayout
            } else {
                splitLayout
            }
        }
        .task {
            if appModel.serverProfiles.isEmpty {
                section = .settings
            }
            await appModel.bootstrap()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await appModel.recoverConnectionIfNeeded() }
        }
    }

    // MARK: Regular width

    @ViewBuilder
    private var splitLayout: some View {
        if section == .dashboard {
            NavigationSplitView {
                sectionList
            } detail: {
                NavigationStack { dashboard }
            }
        } else {
            NavigationSplitView {
                sectionList
            } content: {
                contentColumn
            } detail: {
                NavigationStack { detailColumn }
            }
        }
    }

    private var sectionList: some View {
        List(DockhandSection.allCases, id: \.self, selection: $section) { item in
            NavigationLink(value: item) {
                Label(item.title, systemImage: item.systemImage)
            }
        }
        .navigationTitle("Dockhand")
    }

    @ViewBuilder
    private var contentColumn: some View {
        switch section {
        case .containers: containersList
        case .stacks: stacksList
        case .images: imagesList
        case .settings: SettingsList(appModel: appModel, selection: $settingsPane)
        case .dashboard, nil: EmptyView()
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch section {
        case .containers: containerDetail
        case .stacks: stackDetail
        case .images: imageDetail
        case .settings: SettingsView(appModel: appModel, pane: settingsPane ?? .activeServer)
        case .dashboard, nil: EmptyView()
        }
    }

    // MARK: Compact width

    private var tabLayout: some View {
        TabView(selection: Binding(get: { section ?? .dashboard }, set: { section = $0 })) {
            Tab(DockhandSection.dashboard.title, systemImage: DockhandSection.dashboard.systemImage, value: .dashboard) {
                NavigationStack { dashboard }
            }

            Tab(DockhandSection.containers.title, systemImage: DockhandSection.containers.systemImage, value: .containers) {
                NavigationSplitView { containersList } detail: { NavigationStack { containerDetail } }
            }

            Tab(DockhandSection.stacks.title, systemImage: DockhandSection.stacks.systemImage, value: .stacks) {
                NavigationSplitView { stacksList } detail: { NavigationStack { stackDetail } }
            }

            Tab(DockhandSection.images.title, systemImage: DockhandSection.images.systemImage, value: .images) {
                NavigationSplitView { imagesList } detail: { NavigationStack { imageDetail } }
            }

            Tab(DockhandSection.settings.title, systemImage: DockhandSection.settings.systemImage, value: .settings) {
                NavigationStack { SettingsView(appModel: appModel) }
            }
        }
    }

    // MARK: Shared columns

    private var dashboard: some View {
        DashboardView(
            appModel: appModel,
            onOpenSettings: { section = .settings },
            onOpenContainers: openContainers,
            onOpenStacks: { section = .stacks },
            onOpenImages: { section = .images }
        )
    }

    private var containersList: some View {
        ContainersView(
            appModel: appModel,
            requestedFilter: requestedContainerFilter,
            filterRequestRevision: containerFilterRequestRevision,
            store: containersStore,
            selection: $selectedContainerID
        )
    }

    private var containerDetail: some View {
        ContainerDetailColumn(appModel: appModel, store: containersStore, selection: selectedContainerID)
    }

    private var stacksList: some View {
        StacksView(appModel: appModel, store: stacksStore, selection: $selectedStackName)
    }

    private var stackDetail: some View {
        StackDetailColumn(appModel: appModel, store: stacksStore, selection: selectedStackName)
    }

    private var imagesList: some View {
        ImagesView(appModel: appModel, store: imagesStore, selection: $selectedImageID)
    }

    private var imageDetail: some View {
        ImageDetailColumn(appModel: appModel, store: imagesStore, selection: selectedImageID)
    }

    private func openContainers(filter: ContainerListFilter) {
        requestedContainerFilter = filter
        containerFilterRequestRevision &+= 1
        section = .containers
    }
}
