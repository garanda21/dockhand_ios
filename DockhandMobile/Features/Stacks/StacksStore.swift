import DockhandAPI
import Observation
import SwiftUI

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
        defer { activeStackActionID = nil }

        do {
            let service = DockhandService(baseURL: baseURL, token: appModel.token)
            try await service.redeployStack(
                stackName: stack.name,
                environmentID: environmentID,
                options: options
            )
            actionMessage = String(
                format: String(localized: "%@ redeployed"),
                locale: Locale.current,
                stack.name
            )
            actionMessageOwner = stack.name
            await load(appModel: appModel)
        } catch {
            guard !error.isDockhandCancellation else { return }
            self.error = error.dockhandUserFacingMessage
        }
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
