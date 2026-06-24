import DockhandAPI
import Observation
import SwiftUI

@MainActor
@Observable
final class ImagesStore {
    var images: [Components.Schemas.ImageSummary] = []
    var isLoading = false
    var error: String?
    var actionMessage: String?
    var actionMessageScope: ImageActionScope?
    var activeActionID: String?

    func load(appModel: AppModel) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else {
            images = []
            return
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            images = try await service.fetchImages(environmentID: environmentID)
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func pullImage(named name: String, scope: ImageActionScope = .list, appModel: AppModel) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else { return }

        activeActionID = "pull"
        actionMessage = nil
        actionMessageScope = nil
        error = nil
        defer { activeActionID = nil }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            try await service.pullImage(imageName: name, environmentID: environmentID)
            actionMessage = "\(name) pulled"
            actionMessageScope = scope
            await load(appModel: appModel)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func pruneImages(danglingOnly: Bool, appModel: AppModel) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else { return }

        activeActionID = danglingOnly ? "prune" : "prune-unused"
        actionMessage = nil
        actionMessageScope = nil
        error = nil
        defer { activeActionID = nil }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            try await service.pruneImages(environmentID: environmentID, danglingOnly: danglingOnly)
            actionMessage = danglingOnly ? "Dangling images pruned" : "Unused images pruned"
            actionMessageScope = .list
            await load(appModel: appModel)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func tagImage(_ image: Components.Schemas.ImageSummary, repo: String, tag: String, appModel: AppModel) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else { return }

        activeActionID = actionID("tag", image.id)
        actionMessage = nil
        actionMessageScope = nil
        error = nil
        defer { activeActionID = nil }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            try await service.tagImage(imageID: image.id, environmentID: environmentID, repo: repo, tag: tag)
            actionMessage = "\(repo):\(tag) created"
            actionMessageScope = .image(image.id)
            await load(appModel: appModel)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deleteImage(reference: String, appModel: AppModel) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else { return }

        activeActionID = actionID("delete", reference)
        actionMessage = nil
        actionMessageScope = nil
        error = nil
        defer { activeActionID = nil }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            try await service.deleteImage(imageReference: reference, environmentID: environmentID)
            actionMessage = "\(reference) deleted"
            actionMessageScope = .image(reference)
            await load(appModel: appModel)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deleteImageTag(_ tag: String, imageID: String, appModel: AppModel) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else { return }

        activeActionID = actionID("delete-tag", tag)
        actionMessage = nil
        actionMessageScope = nil
        error = nil
        defer { activeActionID = nil }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            try await service.deleteImageTag(imageTag: tag, environmentID: environmentID)
            actionMessage = "\(tag) removed"
            actionMessageScope = .image(imageID)
            await load(appModel: appModel)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func scanImage(_ image: Components.Schemas.ImageSummary, appModel: AppModel) async throws -> ImageScanDocument {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else {
            throw DockhandServiceError.invalidResponse
        }

        activeActionID = actionID("scan", image.id)
        actionMessage = nil
        actionMessageScope = nil
        error = nil
        defer { activeActionID = nil }

        let service = DockhandService(baseURL: baseURL, token: appModel.token)
        return try await service.scanImage(imageName: image.displayName, environmentID: environmentID)
    }

    func image(id: String) -> Components.Schemas.ImageSummary? {
        images.first(where: { $0.id == id })
    }

    var listActionMessage: String? {
        guard actionMessageScope == .list else { return nil }
        return actionMessage
    }

    func actionMessage(for imageID: String) -> String? {
        guard actionMessageScope == .image(imageID) else { return nil }
        return actionMessage
    }

    func isRunning(_ action: String, reference: String) -> Bool {
        activeActionID == actionID(action, reference)
    }

    private func actionID(_ action: String, _ reference: String) -> String {
        "\(action):\(reference)"
    }
}

enum ImageActionScope: Equatable {
    case list
    case image(String)
}

struct ImagesView: View {
    let appModel: AppModel
    @State private var store = ImagesStore()
    @State private var pullSheetPresented = false
    @State private var stateFilter = ImageStateFilter.all
    @State private var pruneConfirmation: ImagePruneMode?

    private var repositoryUsage: [String: RepositoryImageUsage] {
        Dictionary(
            grouping: store.images,
            by: \.repositoryKey
        ).mapValues { images in
            let hasUsed = images.contains { $0.containers > 0 }
            let hasUnused = images.contains { $0.containers == 0 }
            return RepositoryImageUsage(hasUsed: hasUsed, hasUnused: hasUnused)
        }
    }

    private var filteredImages: [Components.Schemas.ImageSummary] {
        store.images.filter { image in
            let usage = repositoryUsage[image.repositoryKey] ?? .init(hasUsed: image.containers > 0, hasUnused: image.containers == 0)
            return stateFilter.matches(image: image, usage: usage)
        }
    }

    var body: some View {
        List {
            Section {
                EnvironmentHeaderBar(appModel: appModel)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if let error = store.error {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }

            Section {
                imageActionsPanel
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
            }

            Section("Images") {
                if filteredImages.isEmpty {
                    Text(stateFilter == .all ? "No images" : "No images in \(stateFilter.title)")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredImages, id: \.id) { image in
                        NavigationLink {
                            ImageDetailView(image: image, appModel: appModel, store: store)
                        } label: {
                            ImageRow(
                                image: image,
                                usage: repositoryUsage[image.repositoryKey]
                            )
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Images")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(ImageStateFilter.allCases) { filter in
                        Button {
                            stateFilter = filter
                        } label: {
                            selectionLabel(filter.title, isSelected: stateFilter == filter)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(isPresented: $pullSheetPresented) {
            PullImageSheet(appModel: appModel, store: store, scope: .list)
                .presentationDetents([.medium])
        }
        .confirmationDialog(pruneConfirmation?.title ?? "", isPresented: Binding(
            get: { pruneConfirmation != nil },
            set: { if !$0 { pruneConfirmation = nil } }
        ), titleVisibility: .visible) {
            if let pruneConfirmation {
                Button(pruneConfirmation.confirmTitle, role: .destructive) {
                    let danglingOnly = pruneConfirmation == .danglingOnly
                    Task { await store.pruneImages(danglingOnly: danglingOnly, appModel: appModel) }
                    self.pruneConfirmation = nil
                }
            }
        } message: {
            Text(pruneConfirmation?.message ?? "")
        }
        .overlay {
            if store.isLoading && store.images.isEmpty {
                ProgressView()
            }
        }
        .task(id: appModel.connectionScopeID) {
            await store.load(appModel: appModel)
        }
        .refreshable {
            await store.load(appModel: appModel)
        }
    }

    private var imageActionsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Image actions")
                    .font(.headline)
                Spacer()
                if stateFilter != .all {
                    Text(stateFilter.title)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let actionMessage = store.listActionMessage {
                Label(actionMessage, systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    pruneButton(.danglingOnly, title: "Prune", systemImage: "wand.and.stars.inverse", tint: .primary, isRunning: store.activeActionID == "prune")

                    pruneButton(.allUnused, title: "Prune unused", systemImage: "wand.and.stars", tint: .orange, isRunning: store.activeActionID == "prune-unused")

                    toolButton(
                        title: "Pull",
                        systemImage: "arrow.down.circle",
                        tint: .blue,
                        isProminent: true
                    ) {
                        pullSheetPresented = true
                    }
                }

                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        pruneButton(.danglingOnly, title: "Prune", systemImage: "wand.and.stars.inverse", tint: .primary, isRunning: store.activeActionID == "prune")

                        pruneButton(.allUnused, title: "Prune unused", systemImage: "wand.and.stars", tint: .orange, isRunning: store.activeActionID == "prune-unused")
                    }

                    toolButton(
                        title: "Pull image",
                        systemImage: "arrow.down.circle",
                        tint: .blue,
                        isProminent: true
                    ) {
                        pullSheetPresented = true
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func selectionLabel(_ title: String, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 12)
            if isSelected {
                Image(systemName: "checkmark")
            }
        }
    }

    private func toolButton(
        title: String,
        systemImage: String,
        tint: Color,
        isProminent: Bool = false,
        isRunning: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 44)
        }
        .buttonStyle(isProminent ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.bordered))
        .tint(tint)
        .disabled(isRunning)
    }

    private func pruneButton(
        _ mode: ImagePruneMode,
        title: String,
        systemImage: String,
        tint: Color,
        isRunning: Bool
    ) -> some View {
        toolButton(
            title: title,
            systemImage: systemImage,
            tint: tint,
            isRunning: isRunning
        ) {
            pruneConfirmation = mode
        }
    }
}

private struct AnyButtonStyle: PrimitiveButtonStyle {
    private let makeBodyClosure: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        self.makeBodyClosure = { configuration in
            AnyView(style.makeBody(configuration: configuration))
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        makeBodyClosure(configuration)
    }
}

private struct ImageRow: View {
    let image: Components.Schemas.ImageSummary
    let usage: RepositoryImageUsage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(image.displayName)
                    .font(.headline)
                    .lineLimit(1)

                if image.isUnused {
                    Text("Unused")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.12), in: Capsule())
                } else if usage?.isPartiallyUnused == true {
                    Text("Some unused")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.12), in: Capsule())
                }
            }

            Text(image.shortID)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)

            HStack {
                Text(image.size.dockhandByteCount)
                Text(image.createdAtText)
                Text("\(image.containers) containers")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

private struct RepositoryImageUsage {
    let hasUsed: Bool
    let hasUnused: Bool

    var isPartiallyUnused: Bool {
        hasUsed && hasUnused
    }
}

private enum ImageStateFilter: String, CaseIterable, Identifiable {
    case all
    case inUse = "in-use"
    case someUnused = "some-unused"
    case unused

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .inUse:
            return "In use"
        case .someUnused:
            return "Some unused"
        case .unused:
            return "Unused"
        }
    }

    func matches(image: Components.Schemas.ImageSummary, usage: RepositoryImageUsage) -> Bool {
        switch self {
        case .all:
            return true
        case .inUse:
            return image.containers > 0
        case .someUnused:
            return usage.isPartiallyUnused
        case .unused:
            return image.containers == 0
        }
    }
}

private enum ImagePruneMode {
    case danglingOnly
    case allUnused

    var title: String {
        switch self {
        case .danglingOnly:
            return "Prune dangling images"
        case .allUnused:
            return "Prune unused images"
        }
    }

    var confirmTitle: String {
        switch self {
        case .danglingOnly:
            return "Prune"
        case .allUnused:
            return "Prune unused"
        }
    }

    var message: String {
        switch self {
        case .danglingOnly:
            return "This removes untagged intermediate layers in the selected Dockhand environment."
        case .allUnused:
            return "This removes every image not used by any container in the selected Dockhand environment."
        }
    }
}

private struct ImageDetailView: View {
    let image: Components.Schemas.ImageSummary
    let appModel: AppModel
    let store: ImagesStore

    @State private var scanResult: ImageScanDocument?
    @State private var pullSheetPresented = false
    @State private var tagSheetPresented = false
    @State private var deleteConfirmationPresented = false
    @State private var deleteTagConfirmation: ImageTagDeletionTarget?

    private var liveImage: Components.Schemas.ImageSummary {
        store.image(id: image.id) ?? image
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusCard
                summaryCard
                actionsCard
                tagsCard
                digestsCard
                labelsCard
                scanCard
            }
            .padding()
        }
        .navigationTitle(liveImage.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $pullSheetPresented) {
            PullImageSheet(appModel: appModel, store: store, suggestedName: liveImage.displayName, scope: .image(liveImage.id))
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $tagSheetPresented) {
            TagImageSheet(image: liveImage, appModel: appModel, store: store)
                .presentationDetents([.medium])
        }
        .confirmationDialog("Delete image", isPresented: $deleteConfirmationPresented, titleVisibility: .visible) {
            Button("Delete image", role: .destructive) {
                Task { await store.deleteImage(reference: liveImage.id, appModel: appModel) }
            }
        } message: {
            Text("This removes the full image object from the selected Dockhand environment.")
        }
        .confirmationDialog("Delete tag", isPresented: Binding(
            get: { deleteTagConfirmation != nil },
            set: { if !$0 { deleteTagConfirmation = nil } }
        ), titleVisibility: .visible) {
            if let target = deleteTagConfirmation {
                Button("Delete tag", role: .destructive) {
                    Task { await store.deleteImageTag(target.reference, imageID: liveImage.id, appModel: appModel) }
                    deleteTagConfirmation = nil
                }
            }
        } message: {
            Text(deleteTagConfirmation?.message ?? "")
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        if let error = store.error {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular.tint(.red.opacity(0.08)), in: .rect(cornerRadius: 18))
        } else if let actionMessage = store.actionMessage(for: liveImage.id) {
            Text(actionMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 18))
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(liveImage.displayName)
                    .font(.title3.weight(.semibold))
                if liveImage.isUnused {
                    Text("Unused")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }

            Text(liveImage.id)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                metric("Size", liveImage.size.dockhandByteCount)
                metric("Virtual", liveImage.virtualSize.dockhandByteCount)
                metric("Created", liveImage.createdAtText)
                metric("Used by", "\(liveImage.containers) containers")
            }
        }
        .padding(20)
        .glassEffect(.regular.tint(.white.opacity(0.03)), in: .rect(cornerRadius: 24))
    }

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Actions")
                .font(.headline)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                actionButton(
                    title: "Scan",
                    systemImage: "shield.checkered",
                    isRunning: store.isRunning("scan", reference: liveImage.id)
                ) {
                    Task {
                        do {
                            scanResult = try await store.scanImage(liveImage, appModel: appModel)
                        } catch {
                            store.error = error.localizedDescription
                        }
                    }
                }

                actionButton(title: "Tag", systemImage: "tag") {
                    tagSheetPresented = true
                }

                actionButton(title: "Pull", systemImage: "arrow.down.circle") {
                    pullSheetPresented = true
                }

                actionButton(title: "Delete", systemImage: "trash", role: .destructive) {
                    deleteConfirmationPresented = true
                }
                .disabled(liveImage.containers > 0)
            }

            if liveImage.containers > 0 {
                Text("Delete is disabled while the image is used by containers.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 24))
    }

    private var tagsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tags")
                .font(.headline)

            if liveImage.allTags.isEmpty {
                Text("No tags")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(liveImage.allTags, id: \.self) { tag in
                    HStack {
                        Text(tag)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            deleteTagConfirmation = .init(reference: tag)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.glass)
                        .disabled(store.isRunning("delete-tag", reference: tag))
                    }
                }
            }
        }
        .padding(20)
        .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 24))
    }

    @ViewBuilder
    private var digestsCard: some View {
        if !liveImage.allDigests.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Digests")
                    .font(.headline)

                ForEach(liveImage.allDigests, id: \.self) { digest in
                    Text(digest)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(20)
            .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 24))
        }
    }

    @ViewBuilder
    private var labelsCard: some View {
        if !liveImage.labelPairs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Labels")
                    .font(.headline)

                ForEach(liveImage.labelPairs, id: \.key) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.key)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.blue)
                        Text(item.value)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(20)
            .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 24))
        }
    }

    @ViewBuilder
    private var scanCard: some View {
        if let scanResult {
            VStack(alignment: .leading, spacing: 12) {
                Text("Scan")
                    .font(.headline)
                Text(scanResult.message)
                    .foregroundStyle(.secondary)

                if let progress = scanResult.progress {
                    Text("\(progress)%")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }

                if scanResult.results.isEmpty {
                    Text("No vulnerabilities reported")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(scanResult.results, id: \.self) { line in
                        Text(line)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
            .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 24))
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionButton(
        title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        isRunning: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 8) {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .frame(height: 18)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(height: 18)
                }
                Text(title)
                    .font(.footnote.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.glass)
    }
}

private struct ImageTagDeletionTarget: Equatable {
    let reference: String

    var message: String {
        "Remove tag \(reference)?"
    }
}

private struct PullImageSheet: View {
    let appModel: AppModel
    let store: ImagesStore
    var suggestedName: String = ""
    var scope: ImageActionScope = .list

    @Environment(\.dismiss) private var dismiss
    @State private var imageName = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("nginx:latest", text: $imageName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .navigationTitle("Pull image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pull") {
                        Task {
                            await store.pullImage(named: imageName.isEmpty ? suggestedName : imageName, scope: scope, appModel: appModel)
                            dismiss()
                        }
                    }
                    .disabled((imageName.isEmpty ? suggestedName : imageName).isEmpty || store.activeActionID == "pull")
                }
            }
        }
        .onAppear {
            if imageName.isEmpty {
                imageName = suggestedName
            }
        }
    }
}

private struct TagImageSheet: View {
    let image: Components.Schemas.ImageSummary
    let appModel: AppModel
    let store: ImagesStore

    @Environment(\.dismiss) private var dismiss
    @State private var repo = ""
    @State private var tag = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Repository", text: $repo)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Tag", text: $tag)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .navigationTitle("Tag image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await store.tagImage(image, repo: repo, tag: tag, appModel: appModel)
                            dismiss()
                        }
                    }
                    .disabled(repo.isEmpty || tag.isEmpty || store.isRunning("tag", reference: image.id))
                }
            }
        }
        .onAppear {
            if repo.isEmpty {
                let base = image.displayName.split(separator: ":").dropLast().joined(separator: ":")
                repo = base.isEmpty ? image.displayName : base
            }
        }
    }
}
