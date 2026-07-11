import DockhandAPI
import Observation
import SwiftUI

enum ImagePullStatus: Equatable {
    case idle
    case pulling
    case complete
    case failed
    case cancelled
}

struct ImagePullLayer: Identifiable, Equatable {
    let id: String
    var status: String
    var progress: String?
    var current: Int64?
    var total: Int64?
    let order: Int
    var isComplete: Bool

    var percentage: Double? {
        guard let current, let total, total > 0 else { return nil }
        return min(max(Double(current) / Double(total), 0), 1)
    }

    var isAlreadyPresent: Bool {
        status.localizedCaseInsensitiveCompare("Already exists") == .orderedSame
    }
}

@MainActor
@Observable
final class ImagesStore {
    var images: [Components.Schemas.ImageSummary] = []
    var isLoading = false
    var error: String?
    var actionMessage: String?
    var actionMessageScope: ImageActionScope?
    var activeActionID: String?
    var pullStatus = ImagePullStatus.idle
    var pullLayers: [ImagePullLayer] = []
    var pullOutput: [String] = []
    var pullStatusMessage: String?
    var pullError: String?

    var completedPullLayerCount: Int {
        pullLayers.count(where: \.isComplete)
    }

    var pullProgress: Double {
        guard !pullLayers.isEmpty else { return 0 }
        return Double(completedPullLayerCount) / Double(pullLayers.count)
    }

    var pullDownloadedBytes: Int64 {
        pullLayers.reduce(0) { $0 + ($1.current ?? 0) }
    }

    var pullTotalBytes: Int64 {
        pullLayers.reduce(0) { $0 + ($1.total ?? 0) }
    }

    var isPulledImageUpToDate: Bool {
        !pullLayers.isEmpty && pullLayers.allSatisfy(\.isAlreadyPresent)
    }

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
            guard !error.isDockhandCancellation else { return }
            self.error = error.dockhandUserFacingMessage
        }
    }

    func pullImage(named name: String, scope: ImageActionScope = .list, appModel: AppModel) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else { return }

        resetPullProgress()
        activeActionID = "pull"
        pullStatus = .pulling
        actionMessage = nil
        actionMessageScope = nil
        error = nil
        defer { activeActionID = nil }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            pullOutput.append(String(format: String(localized: "Starting pull for %@"), locale: .current, name))

            switch try await service.startImagePull(imageName: name, environmentID: environmentID) {
            case .completed(let event):
                applyPullEvent(event)
            case .job(let jobID):
                try await watchImagePullJob(jobID, service: service)
            }

            try Task.checkCancellation()
            pullStatus = .complete
            let completionMessage = isPulledImageUpToDate
                ? String(localized: "Image is already up to date")
                : String(localized: "Pull completed")
            pullOutput.append(completionMessage)
            actionMessage = completionMessage
            actionMessageScope = scope
            await load(appModel: appModel)
        } catch {
            if error.isDockhandCancellation {
                pullStatus = .cancelled
                pullOutput.append(String(localized: "Progress monitoring cancelled"))
                return
            }
            pullStatus = .failed
            pullError = error.dockhandUserFacingMessage
            pullOutput.append(String(format: String(localized: "Error: %@"), locale: .current, pullError ?? ""))
        }
    }

    func resetPullProgress() {
        pullStatus = .idle
        pullLayers = []
        pullOutput = []
        pullStatusMessage = nil
        pullError = nil
    }

    private func watchImagePullJob(_ jobID: String, service: DockhandService) async throws {
        var cursor = 0

        while true {
            try Task.checkCancellation()
            let snapshot = try await service.fetchImagePullJob(id: jobID)

            if cursor < snapshot.lines.count {
                for line in snapshot.lines[cursor...] where line.event != "result" {
                    applyPullEvent(line.data)
                }
                cursor = snapshot.lines.count
            }

            if snapshot.status != "running" {
                if snapshot.status == "error" {
                    throw DockhandServiceError.message(snapshot.result?.error ?? String(localized: "Image pull failed"))
                }
                if let error = snapshot.result?.error, !error.isEmpty {
                    throw DockhandServiceError.message(error)
                }
                return
            }

            try await Task.sleep(for: .milliseconds(500))
        }
    }

    private func applyPullEvent(_ event: ImagePullProgressEvent) {
        if event.status == "error" {
            pullError = event.error ?? String(localized: "Image pull failed")
            return
        }
        guard event.status != "complete" else { return }

        if let id = event.id, id.range(of: #"^[a-fA-F0-9]{12}$"#, options: .regularExpression) != nil {
            let normalizedStatus = event.status ?? String(localized: "Processing")
            let statusLower = normalizedStatus.lowercased()
            let isComplete = statusLower == "pull complete" || statusLower == "already exists"

            if let index = pullLayers.firstIndex(where: { $0.id == id }) {
                let wasComplete = pullLayers[index].isComplete
                pullLayers[index].status = normalizedStatus
                pullLayers[index].progress = event.progress ?? pullLayers[index].progress
                pullLayers[index].current = event.progressDetail?.current ?? pullLayers[index].current
                pullLayers[index].total = event.progressDetail?.total ?? pullLayers[index].total
                pullLayers[index].isComplete = wasComplete || isComplete
                if isComplete && !wasComplete {
                    pullOutput.append("\(id): \(normalizedStatus)")
                }
            } else {
                pullLayers.append(ImagePullLayer(
                    id: id,
                    status: normalizedStatus,
                    progress: event.progress,
                    current: event.progressDetail?.current,
                    total: event.progressDetail?.total,
                    order: pullLayers.count,
                    isComplete: isComplete
                ))
                if isComplete {
                    pullOutput.append("\(id): \(normalizedStatus)")
                }
            }
            return
        }

        if let status = event.status, !status.isEmpty {
            pullStatusMessage = event.id.map { "\($0): \(status)" } ?? status
            pullOutput.append(pullStatusMessage ?? status)
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
            guard !error.isDockhandCancellation else { return }
            self.error = error.dockhandUserFacingMessage
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
            guard !error.isDockhandCancellation else { return }
            self.error = error.dockhandUserFacingMessage
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
            guard !error.isDockhandCancellation else { return }
            self.error = error.dockhandUserFacingMessage
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
            guard !error.isDockhandCancellation else { return }
            self.error = error.dockhandUserFacingMessage
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
