import DockhandAPI
import SwiftUI

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
                    Text(
                        stateFilter == .all
                            ? String(localized: "No images")
                            : String(format: String(localized: "No images in %@"), locale: Locale.current, stateFilter.title)
                    )
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredImages, id: \.id) { image in
                        NavigationLink {
                            ImageDetailView(
                                image: image,
                                scope: appModel.connectionScope,
                                appModel: appModel,
                                store: store
                            )
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
            PullImageSheet(appModel: appModel, scope: appModel.connectionScope, store: store, actionScope: .list)
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
                VStack(spacing: 12) {
                    pruneButton(.danglingOnly, title: String(localized: "Prune"), systemImage: "wand.and.stars.inverse", tint: .primary, height: 20, isRunning: store.activeActionID == "prune")

                    pruneButton(.allUnused, title: String(localized: "Prune unused"), systemImage: "wand.and.stars", tint: .orange, height: 20, isRunning: store.activeActionID == "prune-unused")

                    toolButton(
                        title: String(localized: "Pull"),
                        systemImage: "arrow.down.circle",
                        tint: .blue,
                        isProminent: true,
                        height: 20
                    ) {
                        pullSheetPresented = true
                    }
                }

                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        pruneButton(.danglingOnly, title: String(localized: "Prune"), systemImage: "wand.and.stars.inverse", tint: .primary, height: 20, isRunning: store.activeActionID == "prune")

                        pruneButton(.allUnused, title: String(localized: "Prune unused"), systemImage: "wand.and.stars", tint: .orange, height: 20, isRunning: store.activeActionID == "prune-unused")
                    }

                    toolButton(
                        title: String(localized: "Pull image"),
                        systemImage: "arrow.down.circle",
                        tint: .blue,
                        isProminent: true,
                        height: 20
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
        height: CGFloat = 44,
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
            .frame(height: height)
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
        height: CGFloat,
        isRunning: Bool
    ) -> some View {
        toolButton(
            title: title,
            systemImage: systemImage,
            tint: tint,
            isRunning: isRunning,
            height: height
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
                Text(image.containers.localizedContainersCountText)
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
            return String(localized: "All")
        case .inUse:
            return String(localized: "In use")
        case .someUnused:
            return String(localized: "Some unused")
        case .unused:
            return String(localized: "Unused")
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
            return String(localized: "Prune dangling images")
        case .allUnused:
            return String(localized: "Prune unused images")
        }
    }

    var confirmTitle: String {
        switch self {
        case .danglingOnly:
            return String(localized: "Prune")
        case .allUnused:
            return String(localized: "Prune unused")
        }
    }

    var message: String {
        switch self {
        case .danglingOnly:
            return String(localized: "This removes untagged intermediate layers in the selected Dockhand environment.")
        case .allUnused:
            return String(localized: "This removes every image not used by any container in the selected Dockhand environment.")
        }
    }
}

private struct ImageDetailView: View {
    let image: Components.Schemas.ImageSummary
    let scope: DockhandConnectionScope
    let appModel: AppModel
    let store: ImagesStore

    @State private var scanResult: ImageScanDocument?
    @State private var pullSheetPresented = false
    @State private var tagSheetPresented = false
    @State private var deleteConfirmationPresented = false
    @State private var deleteTagConfirmation: ImageTagDeletionTarget?

    private var liveImage: Components.Schemas.ImageSummary {
        isCurrentScope ? (store.image(id: image.id) ?? image) : image
    }

    private var isCurrentScope: Bool {
        appModel.isCurrentScope(scope)
    }

    private var relatedImages: [Components.Schemas.ImageSummary] {
        let matches = store.images
            .filter { $0.repositoryKey == liveImage.repositoryKey }
            .sorted { first, second in
                if first.id == liveImage.id { return true }
                if second.id == liveImage.id { return false }
                if first.isUnused != second.isUnused {
                    return !first.isUnused
                }
                return first.created > second.created
            }

        return matches.isEmpty ? [liveImage] : matches
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !isCurrentScope {
                    staleScopeWarning
                }
                statusCard
                summaryCard
                actionsCard
                imageVariantsCard
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
            PullImageSheet(
                appModel: appModel,
                scope: scope,
                store: store,
                suggestedName: liveImage.displayName,
                actionScope: .image(liveImage.id)
            )
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $tagSheetPresented) {
            TagImageSheet(image: liveImage, scope: scope, appModel: appModel, store: store)
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

    private var staleScopeWarning: some View {
        Text("Server or environment changed. Go back and reopen this image before running actions.")
            .font(.footnote)
            .foregroundStyle(.orange)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(.orange.opacity(0.08)), in: .rect(cornerRadius: 18))
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
                metric(String(localized: "Size"), liveImage.size.dockhandByteCount)
                metric(String(localized: "Virtual"), liveImage.virtualSize.dockhandByteCount)
                metric(String(localized: "Created"), liveImage.createdAtText)
                metric(String(localized: "Used by"), liveImage.containers.localizedContainersCountText)
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
                    title: String(localized: "Scan"),
                    systemImage: "shield.checkered",
                    isRunning: store.isRunning("scan", reference: liveImage.id)
                ) {
                    guard isCurrentScope else { return }
                    Task {
                        do {
                            scanResult = try await store.scanImage(liveImage, appModel: appModel)
                        } catch {
                            guard !error.isDockhandCancellation else { return }
                            store.error = error.dockhandUserFacingMessage
                        }
                    }
                }

                actionButton(title: String(localized: "Tag"), systemImage: "tag") {
                    guard isCurrentScope else { return }
                    tagSheetPresented = true
                }

                actionButton(title: String(localized: "Pull"), systemImage: "arrow.down.circle") {
                    guard isCurrentScope else { return }
                    pullSheetPresented = true
                }

                actionButton(title: String(localized: "Delete"), systemImage: "trash", role: .destructive) {
                    guard isCurrentScope else { return }
                    deleteConfirmationPresented = true
                }
                .disabled(!isCurrentScope || liveImage.containers > 0)
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

    @ViewBuilder
    private var imageVariantsCard: some View {
        if relatedImages.count > 1 || liveImage.isUnused {
            VStack(alignment: .leading, spacing: 12) {
                Text("Image variants")
                    .font(.headline)

                ForEach(relatedImages, id: \.id) { image in
                    ImageVariantRow(image: image, isCurrent: image.id == liveImage.id)

                    if image.id != relatedImages.last?.id {
                        Divider()
                    }
                }
            }
            .padding(20)
            .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 24))
        }
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
                            guard isCurrentScope else { return }
                            deleteTagConfirmation = .init(reference: tag)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.glass)
                        .disabled(!isCurrentScope || store.isRunning("delete-tag", reference: tag))
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
        .disabled(!isCurrentScope)
    }
}

private struct ImageVariantRow: View {
    let image: Components.Schemas.ImageSummary
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: image.isUnused ? "circle.dashed" : "cube.box")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(image.isUnused ? .orange : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 6) {
                Text(image.variantTagText)
                    .font(.footnote.monospaced())
                    .lineLimit(2)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    if isCurrent {
                        Text("Current")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.secondary.opacity(0.10), in: Capsule())
                    }

                    if image.isUnused {
                        Text("Unused")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.orange.opacity(0.12), in: Capsule())
                    }
                }

                Text(image.shortID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    Text(image.size.dockhandByteCount)
                    Text(image.createdAtText)
                    Text(image.containers.localizedContainersCountText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension Components.Schemas.ImageSummary {
    var variantTagText: String {
        allTags.first ?? "<none>"
    }
}

private struct ImageTagDeletionTarget: Equatable {
    let reference: String

    var message: String {
        String(
            format: String(localized: "Remove tag %@?"),
            locale: Locale.current,
            reference
        )
    }
}

private struct PullImageSheet: View {
    let appModel: AppModel
    let scope: DockhandConnectionScope
    let store: ImagesStore
    var suggestedName: String = ""
    var actionScope: ImageActionScope = .list

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
                            guard appModel.isCurrentScope(scope) else { return }
                            await store.pullImage(named: imageName.isEmpty ? suggestedName : imageName, scope: actionScope, appModel: appModel)
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
    let scope: DockhandConnectionScope
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
                            guard appModel.isCurrentScope(scope) else { return }
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
