import DockhandAPI
import Observation
import SwiftUI

enum StackRedeployStatus: Equatable {
    case idle
    case deploying
    case complete
    case failed
    case cancelled
}

@MainActor
@Observable
final class StacksStore {
    var stacks: [Components.Schemas.StackSummary] = []
    var isLoading = false
    var error: String?
    var actionMessage: String?
    var actionMessageOwner: String?
    var activeStackActionID: String?
    var activeContainerActionID: String?
    var redeployStatus = StackRedeployStatus.idle
    var redeploySteps: [String] = []
    var redeployOutput: [String] = []
    var redeployError: String?

    func load(appModel: AppModel) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else {
            stacks = []
            return
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            stacks = try await service.fetchStacks(environmentID: environmentID)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            guard !error.isDockhandCancellation else { return }
            self.error = error.dockhandUserFacingMessage
        }
    }

    func run(_ action: StackAction, stack: Components.Schemas.StackSummary, appModel: AppModel) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else { return }

        activeStackActionID = stackActionID(for: action, stackName: stack.name)
        error = nil
        defer { activeStackActionID = nil }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            try await service.stackAction(action, stackName: stack.name, environmentID: environmentID)
            actionMessage = actionMessage(for: action, stackName: stack.name)
            actionMessageOwner = stack.name
            appModel.requestDashboardRefresh()
            await load(appModel: appModel)
        } catch {
            guard !error.isDockhandCancellation else { return }
            self.error = error.dockhandUserFacingMessage
        }
    }

    func redeploy(stack: Components.Schemas.StackSummary, appModel: AppModel, options: StackDeployOptions) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else { return }

        activeStackActionID = stackActionID(for: .redeploy, stackName: stack.name)
        error = nil
        resetRedeployProgress()
        if options.pull {
            redeployStatus = .deploying
            redeploySteps.append(String(localized: "Starting redeploy…"))
        }
        defer { activeStackActionID = nil }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            if options.pull {
                let result: StackRedeployResult
                switch try await service.startStackRedeploy(
                    stackName: stack.name,
                    environmentID: environmentID,
                    options: options
                ) {
                case .completed(let completed):
                    result = completed
                case .job(let jobID):
                    result = try await watchStackRedeployJob(jobID, service: service)
                }
                try Task.checkCancellation()
                applyRedeployResult(result)
                redeployStatus = .complete
                redeploySteps.append(String(localized: "Redeploy completed"))
            } else {
                try await service.redeployStack(
                    stackName: stack.name,
                    environmentID: environmentID,
                    options: options
                )
            }
            actionMessage = String(
                format: String(localized: "%@ redeployed"),
                locale: Locale.current,
                stack.name
            )
            actionMessageOwner = stack.name
            if options.pull {
                for containerID in stack.containerDetails.map(\.id) {
                    try? await service.clearPendingContainerUpdate(
                        containerID: containerID,
                        environmentID: environmentID
                    )
                }
            }
            appModel.requestDashboardRefresh()
            await load(appModel: appModel)
        } catch {
            if error.isDockhandCancellation {
                if options.pull {
                    redeployStatus = .cancelled
                    redeploySteps.append(String(localized: "Progress monitoring cancelled"))
                }
                return
            }
            if options.pull {
                redeployStatus = .failed
                redeployError = error.dockhandUserFacingMessage
            }
            self.error = error.dockhandUserFacingMessage
        }
    }

    func resetRedeployProgress() {
        redeployStatus = .idle
        redeploySteps = []
        redeployOutput = []
        redeployError = nil
    }

    private func watchStackRedeployJob(
        _ jobID: String,
        service: DockhandService
    ) async throws -> StackRedeployResult {
        var cursor = 0

        while true {
            try Task.checkCancellation()
            let snapshot = try await service.fetchStackRedeployJob(id: jobID)

            if cursor < snapshot.lines.count {
                for line in snapshot.lines[cursor...] where line.event != "result" {
                    if let status = line.data.status, !status.isEmpty,
                       redeploySteps.last != status {
                        redeploySteps.append(status)
                    }
                }
                cursor = snapshot.lines.count
            }

            if snapshot.status != "running" {
                guard let result = snapshot.result else {
                    throw DockhandServiceError.invalidResponse
                }
                if snapshot.status == "error" || result.success == false || result.error != nil {
                    throw DockhandServiceError.message(result.error ?? String(localized: "Stack redeploy failed"))
                }
                return result
            }

            try await Task.sleep(for: .milliseconds(500))
        }
    }

    private func applyRedeployResult(_ result: StackRedeployResult) {
        guard let output = result.output, !output.isEmpty else { return }
        let ansiPattern = "\u{001B}\\[[0-?]*[ -/]*[@-~]"
        redeployOutput = output
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: ansiPattern, with: "", options: .regularExpression) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func deleteStack(
        _ stack: Components.Schemas.StackSummary,
        appModel: AppModel,
        deleteVolumes: Bool
    ) async -> Bool {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else { return false }

        activeStackActionID = stackActionID(for: .down, stackName: stack.name) + ":delete"
        error = nil
        defer { activeStackActionID = nil }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            try await service.deleteStack(
                stackName: stack.name,
                environmentID: environmentID,
                deleteVolumes: deleteVolumes
            )

            if await confirmStackDeletion(
                named: stack.name,
                appModel: appModel,
                deleteVolumes: deleteVolumes
            ) {
                appModel.requestDashboardRefresh()
                return true
            }

            self.error = String(localized: "Dockhand reported success, but the stack is still present.")
            return false
        } catch {
            guard !error.isDockhandCancellation else { return false }
            self.error = error.dockhandUserFacingMessage
            return false
        }
    }

    func run(_ action: ContainerAction, container: Components.Schemas.StackContainerDetail, stackName: String, appModel: AppModel) async {
        guard let baseURL = appModel.normalizedBaseURL,
              let environmentID = appModel.selectedEnvironment?.id else { return }

        activeContainerActionID = containerActionID(for: action, containerID: container.id)
        error = nil
        defer { activeContainerActionID = nil }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            try await service.containerAction(action, containerID: container.id, environmentID: environmentID)
            actionMessage = String(
                format: String(localized: "%@ %@"),
                locale: Locale.current,
                container.name,
                action.completedLabel
            )
            actionMessageOwner = stackName
            appModel.requestDashboardRefresh()
            await load(appModel: appModel)
        } catch {
            guard !error.isDockhandCancellation else { return }
            self.error = error.dockhandUserFacingMessage
        }
    }

    func actionMessage(for stackName: String) -> String? {
        guard actionMessageOwner == stackName else { return nil }
        return actionMessage
    }

    func stack(named name: String) -> Components.Schemas.StackSummary? {
        stacks.first(where: { $0.name == name })
    }

    func isRunning(_ action: StackAction, stackName: String) -> Bool {
        activeStackActionID == stackActionID(for: action, stackName: stackName)
    }

    func isRunning(_ action: ContainerAction, containerID: String) -> Bool {
        activeContainerActionID == containerActionID(for: action, containerID: containerID)
    }

    var hasPendingAction: Bool {
        activeStackActionID != nil || activeContainerActionID != nil
    }

    func isDeletingStack(_ stackName: String) -> Bool {
        activeStackActionID == stackActionID(for: .down, stackName: stackName) + ":delete"
    }

    private func stackActionID(for action: StackAction, stackName: String) -> String {
        "\(stackName):\(action.rawValue)"
    }

    private func containerActionID(for action: ContainerAction, containerID: String) -> String {
        "\(containerID):\(action.rawValue)"
    }

    private func actionMessage(for action: StackAction, stackName: String) -> String {
        switch action {
        case .start:
            return String(format: String(localized: "%@ started"), locale: Locale.current, stackName)
        case .stop:
            return String(format: String(localized: "%@ stopped"), locale: Locale.current, stackName)
        case .restart:
            return String(format: String(localized: "%@ restarted"), locale: Locale.current, stackName)
        case .down:
            return String(format: String(localized: "%@ brought down"), locale: Locale.current, stackName)
        case .redeploy:
            return String(format: String(localized: "%@ redeployed"), locale: Locale.current, stackName)
        }
    }

    private func confirmStackDeletion(
        named stackName: String,
        appModel: AppModel,
        deleteVolumes: Bool
    ) async -> Bool {
        for attempt in 0..<6 {
            await load(appModel: appModel)
            if self.stack(named: stackName) == nil {
                actionMessage = deleteVolumes
                    ? String(format: String(localized: "%@ removed with volumes"), locale: Locale.current, stackName)
                    : String(format: String(localized: "%@ removed"), locale: Locale.current, stackName)
                actionMessageOwner = stackName
                return true
            }

            if attempt < 5 {
                try? await Task.sleep(for: .milliseconds(450))
            }
        }

        return false
    }
}
