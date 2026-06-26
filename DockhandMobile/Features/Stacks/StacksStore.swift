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
            self.error = error.localizedDescription
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
            self.error = error.localizedDescription
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
            actionMessage = "\(stack.name) redeployed"
            actionMessageOwner = stack.name
            await load(appModel: appModel)
        } catch {
            self.error = error.localizedDescription
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

            self.error = "Dockhand reported success, but the stack is still present."
            return false
        } catch {
            self.error = error.localizedDescription
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
            actionMessage = "\(container.name) \(action.rawValue)d"
            actionMessageOwner = stackName
            await load(appModel: appModel)
        } catch {
            self.error = error.localizedDescription
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
            return "\(stackName) started"
        case .stop:
            return "\(stackName) stopped"
        case .restart:
            return "\(stackName) restarted"
        case .down:
            return "\(stackName) brought down"
        case .redeploy:
            return "\(stackName) redeployed"
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
                actionMessage = deleteVolumes ? "\(stackName) removed with volumes" : "\(stackName) removed"
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
