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
            actionMessage = String(
                format: String(localized: "%@ pulled"),
                locale: Locale.current,
                name
            )
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
            actionMessage = danglingOnly
                ? String(localized: "Dangling images pruned")
                : String(localized: "Unused images pruned")
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
            actionMessage = String(
                format: String(localized: "%@:%@ created"),
                locale: Locale.current,
                repo,
                tag
            )
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
            actionMessage = String(
                format: String(localized: "%@ deleted"),
                locale: Locale.current,
                reference
            )
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
            actionMessage = String(
                format: String(localized: "%@ removed"),
                locale: Locale.current,
                tag
            )
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
