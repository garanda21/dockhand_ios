import SwiftUI

enum DockhandSection: Hashable, CaseIterable {
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

    var shortcut: KeyEquivalent {
        switch self {
        case .dashboard: "1"
        case .containers: "2"
        case .stacks: "3"
        case .images: "4"
        case .settings: "5"
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

/// A sidebar-adaptable tab view: a bottom tab bar on iPhone, a top tab bar
/// that converts into a sidebar on iPad and Mac. List tabs push their detail
/// on compact width and show list and detail side by side otherwise.
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
        tabLayout
        .focusedSceneValue(\.dockhandNavigation, DockhandNavigation(
            section: section,
            select: { section = $0 },
            refresh: { appModel.requestDashboardRefresh() }
        ))
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

    // MARK: Tabs

    private var tabLayout: some View {
        TabView(selection: Binding(get: { section ?? .dashboard }, set: { section = $0 })) {
            Tab(DockhandSection.dashboard.title, systemImage: DockhandSection.dashboard.systemImage, value: .dashboard) {
                NavigationStack { dashboard }
            }

            Tab(DockhandSection.containers.title, systemImage: DockhandSection.containers.systemImage, value: .containers) {
                listTab(selection: $selectedContainerID) {
                    containersList
                } detail: { id in
                    ContainerDetailColumn(appModel: appModel, store: containersStore, selection: id)
                }
            }

            Tab(DockhandSection.stacks.title, systemImage: DockhandSection.stacks.systemImage, value: .stacks) {
                listTab(selection: $selectedStackName) {
                    stacksList
                } detail: { name in
                    StackDetailColumn(appModel: appModel, store: stacksStore, selection: name)
                }
            }

            Tab(DockhandSection.images.title, systemImage: DockhandSection.images.systemImage, value: .images) {
                listTab(selection: $selectedImageID) {
                    imagesList
                } detail: { id in
                    ImageDetailColumn(appModel: appModel, store: imagesStore, selection: id)
                }
            }

            Tab(DockhandSection.settings.title, systemImage: DockhandSection.settings.systemImage, value: .settings) {
                if horizontalSizeClass == .compact {
                    NavigationStack { SettingsView(appModel: appModel) }
                } else {
                    NavigationSplitView {
                        SettingsList(appModel: appModel, selection: $settingsPane)
                            .toolbar(removing: .sidebarToggle)
                            .toolbarTitleDisplayMode(.large)
                    } detail: {
                        NavigationStack { SettingsView(appModel: appModel, pane: settingsPane ?? .activeServer) }
                    }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    /// Pushes the detail on compact width; shows list and detail side by side otherwise.
    @ViewBuilder
    private func listTab<List: View, Detail: View>(
        selection: Binding<String?>,
        @ViewBuilder list: () -> List,
        @ViewBuilder detail: @escaping (String?) -> Detail
    ) -> some View {
        if horizontalSizeClass == .compact {
            NavigationStack {
                list()
                    .navigationDestination(item: selection) { detail($0) }
            }
        } else {
            NavigationSplitView {
                list()
                    .toolbar(removing: .sidebarToggle)
                    .toolbarTitleDisplayMode(.large)
            } detail: {
                NavigationStack { detail(selection.wrappedValue) }
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

/// Scene actions exposed to the menu bar and the iPad keyboard shortcut overlay.
struct DockhandNavigation {
    let section: DockhandSection?
    let select: (DockhandSection) -> Void
    let refresh: () -> Void
}

extension FocusedValues {
    @Entry var dockhandNavigation: DockhandNavigation?
}

struct DockhandCommands: Commands {
    @FocusedValue(\.dockhandNavigation) private var navigation

    var body: some Commands {
        CommandMenu("Go") {
            ForEach(DockhandSection.allCases, id: \.self) { item in
                Button(item.title) { navigation?.select(item) }
                    .keyboardShortcut(item.shortcut, modifiers: .command)
                    .disabled(navigation == nil || navigation?.section == item)
            }
        }

        CommandGroup(after: .toolbar) {
            Button("Refresh") { navigation?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(navigation == nil)
        }
    }
}
