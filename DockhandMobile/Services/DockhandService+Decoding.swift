import DockhandAPI
import Foundation

extension DockhandService {
    static func decodeEnvironment(_ object: [String: Any]) throws -> Components.Schemas.Environment {
        guard let id = intValue(object["id"]),
              let name = object["name"] as? String,
              let port = intValue(object["port"]),
              let protocolValue = object["protocol"] as? String,
              let icon = object["icon"] as? String,
              let collectActivity = object["collectActivity"] as? Bool,
              let collectMetrics = object["collectMetrics"] as? Bool,
              let highlightChanges = object["highlightChanges"] as? Bool,
              let connectionType = object["connectionType"] as? String,
              let socketPath = object["socketPath"] as? String,
              let createdAt = object["createdAt"] as? String else {
            throw DockhandServiceError.invalidResponse
        }

        return .init(
            id: id,
            name: name,
            host: object["host"] as? String,
            port: port,
            _protocol: protocolValue,
            icon: icon,
            collectActivity: collectActivity,
            collectMetrics: collectMetrics,
            highlightChanges: highlightChanges,
            labels: [],
            connectionType: connectionType,
            socketPath: socketPath,
            publicIp: object["publicIp"] as? String,
            timezone: object["timezone"] as? String,
            updateCheckEnabled: object["updateCheckEnabled"] as? Bool,
            updateCheckAutoUpdate: object["updateCheckAutoUpdate"] as? Bool,
            imagePruneEnabled: object["imagePruneEnabled"] as? Bool,
            createdAt: createdAt,
            updatedAt: object["updatedAt"] as? String
        )
    }

    static func decodeDashboardStats(_ object: [String: Any]) throws -> DashboardEnvironmentSnapshot {
        guard let id = intValue(object["id"]),
              let name = object["name"] as? String else {
            throw DockhandServiceError.invalidResponse
        }

        let containersObject = object["containers"] as? [String: Any] ?? [:]
        let imagesObject = object["images"] as? [String: Any] ?? [:]
        let volumesObject = object["volumes"] as? [String: Any] ?? [:]
        let networksObject = object["networks"] as? [String: Any] ?? [:]
        let stacksObject = object["stacks"] as? [String: Any] ?? [:]
        let metricsObject = object["metrics"] as? [String: Any] ?? [:]
        let eventsObject = object["events"] as? [String: Any] ?? [:]

        return DashboardEnvironmentSnapshot(
            id: id,
            name: name,
            port: intValue(object["port"]) ?? 0,
            icon: object["icon"] as? String ?? "globe",
            socketPath: object["socketPath"] as? String ?? "",
            collectActivity: object["collectActivity"] as? Bool ?? false,
            collectMetrics: object["collectMetrics"] as? Bool ?? false,
            scannerEnabled: object["scannerEnabled"] as? Bool ?? false,
            updateCheckEnabled: object["updateCheckEnabled"] as? Bool ?? false,
            updateCheckAutoUpdate: object["updateCheckAutoUpdate"] as? Bool ?? false,
            connectionType: object["connectionType"] as? String ?? "unknown",
            online: object["online"] as? Bool ?? false,
            containers: .init(
                total: intValue(containersObject["total"]) ?? 0,
                running: intValue(containersObject["running"]) ?? 0,
                stopped: intValue(containersObject["stopped"]) ?? 0,
                paused: intValue(containersObject["paused"]) ?? 0,
                restarting: intValue(containersObject["restarting"]) ?? 0,
                unhealthy: intValue(containersObject["unhealthy"]) ?? 0,
                pendingUpdates: intValue(containersObject["pendingUpdates"]) ?? 0
            ),
            images: .init(total: intValue(imagesObject["total"]) ?? 0, totalSize: intValue(imagesObject["totalSize"]) ?? 0),
            volumes: .init(total: intValue(volumesObject["total"]) ?? 0, totalSize: intValue(volumesObject["totalSize"]) ?? 0),
            containersSize: intValue(object["containersSize"]) ?? 0,
            buildCacheSize: intValue(object["buildCacheSize"]) ?? 0,
            networks: .init(total: intValue(networksObject["total"]) ?? 0),
            stacks: .init(
                total: intValue(stacksObject["total"]) ?? 0,
                running: intValue(stacksObject["running"]) ?? 0,
                partial: intValue(stacksObject["partial"]) ?? 0,
                stopped: intValue(stacksObject["stopped"]) ?? 0
            ),
            metrics: .init(
                cpuPercent: doubleValue(metricsObject["cpuPercent"]) ?? 0,
                memoryPercent: doubleValue(metricsObject["memoryPercent"]) ?? 0,
                memoryUsed: intValue(metricsObject["memoryUsed"]) ?? 0,
                memoryTotal: intValue(metricsObject["memoryTotal"]) ?? 0
            ),
            events: .init(total: intValue(eventsObject["total"]) ?? 0, today: intValue(eventsObject["today"]) ?? 0)
        )
    }

    static func decodeDashboardHost(_ object: [String: Any]) throws -> DashboardHostSnapshot {
        guard let dockerObject = object["docker"] as? [String: Any],
              let hostObject = object["host"] as? [String: Any] else {
            throw DockhandServiceError.invalidResponse
        }

        let dockerConnection = dockerObject["connection"] as? [String: Any] ?? [:]
        let dockhandObject = (object["dockhand"] as? [String: Any])
            ?? (object["app"] as? [String: Any])
            ?? (object["server"] as? [String: Any])
        let runtime = object["runtime"] as? [String: Any]
        let ownContainer = runtime?["ownContainer"] as? [String: Any]
        let labels = ownContainer?["labels"] as? [String: Any]
        let legacyVersion = stringValue(dockhandObject?["version"]) ?? stringValue(object["dockhandVersion"]) ?? stringValue(object["version"])
        let legacyCommit = stringValue(dockhandObject?["commit"]) ?? stringValue(dockhandObject?["gitCommit"]) ?? stringValue(object["commit"])
        let dockhand = DashboardHostSnapshot.Dockhand(
            version: stringValue(labels?["version"]) ?? legacyVersion,
            build: stringValue(dockhandObject?["build"]) ?? stringValue(object["build"]),
            commit: stringValue(labels?["revision"]) ?? legacyCommit,
            runtime: stringValue(dockhandObject?["runtime"]) ?? stringValue(runtime?["runtimeName"]),
            database: stringValue(dockhandObject?["database"]) ?? stringValue(object["database"])
        )

        return DashboardHostSnapshot(
            dockhand: dockhand,
            docker: .init(
                version: dockerObject["version"] as? String ?? String(localized: "Unknown"),
                apiVersion: dockerObject["apiVersion"] as? String ?? String(localized: "Unknown"),
                os: dockerObject["os"] as? String ?? String(localized: "Unknown"),
                arch: dockerObject["arch"] as? String ?? String(localized: "Unknown"),
                kernelVersion: dockerObject["kernelVersion"] as? String ?? String(localized: "Unknown"),
                serverVersion: dockerObject["serverVersion"] as? String ?? String(localized: "Unknown"),
                connectionType: dockerConnection["type"] as? String ?? "unknown",
                socketPath: dockerConnection["socketPath"] as? String
            ),
            host: .init(
                name: hostObject["name"] as? String ?? String(localized: "Unknown"),
                cpus: intValue(hostObject["cpus"]) ?? 0,
                memory: intValue(hostObject["memory"]) ?? 0,
                storageDriver: hostObject["storageDriver"] as? String ?? String(localized: "Unknown")
            )
        )
    }

    static func decodePendingContainerUpdates(_ object: [String: Any]) -> [PendingContainerUpdate] {
        let updates = object["pendingUpdates"] as? [[String: Any]] ?? []
        return updates.compactMap { update in
            guard let containerID = update["containerId"] as? String,
                  let containerName = update["containerName"] as? String else {
                return nil
            }
            let newer = update["newerVersion"] as? [String: Any]
            var tags = newer?["skipped"] as? [String] ?? []
            if let target = newer?["tag"] as? String, tags.last != target { tags.append(target) }
            return PendingContainerUpdate(
                containerID: containerID,
                containerName: containerName,
                currentImage: update["currentImage"] as? String ?? String(localized: "Unknown image"),
                checkedAt: update["checkedAt"] as? String,
                newerTags: tags
            )
        }
    }

    static func decodeBackupConfigs(_ objects: [[String: Any]]) -> [BackupConfigSnapshot] {
        objects.compactMap { object in
            guard let id = object["id"] as? Int,
                  let targetName = object["targetName"] as? String,
                  let destinationID = object["destinationId"] as? Int else {
                return nil
            }
            return BackupConfigSnapshot(
                id: id,
                type: object["type"] as? String ?? "container",
                targetName: targetName,
                environmentID: object["environmentId"] as? Int,
                destinationID: destinationID,
                enabled: object["enabled"] as? Bool ?? true,
                stopBeforeBackup: object["stopBeforeBackup"] as? Bool ?? false,
                schedule: (object["schedule"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                lastBackupAt: object["lastBackupAt"] as? String,
                lastBackupStatus: object["lastBackupStatus"] as? String,
                allVolumes: object["allVolumes"] as? Bool ?? true,
                selectedVolumes: decodeEmbeddedJSON(object["selectedVolumes"]) as? [String] ?? [],
                retention: retentionPolicy(decodeEmbeddedJSON(object["retention"]) as? [String: Any]),
                tags: decodeEmbeddedJSON(object["tags"]) as? [String] ?? []
            )
        }
    }

    static func decodeBackupDestinations(_ objects: [[String: Any]]) -> [BackupDestinationSnapshot] {
        objects.compactMap { object in
            guard let id = object["id"] as? Int, let name = object["name"] as? String else { return nil }
            return BackupDestinationSnapshot(
                id: id,
                name: name,
                repository: object["repository"] as? String ?? "",
                hostPath: object["hostPath"] as? String,
                lastTestAt: object["lastTestAt"] as? String,
                lastTestStatus: object["lastTestStatus"] as? String,
                lastTestError: object["lastTestError"] as? String
            )
        }
    }

    static func decodeBackupExecutions(_ object: [String: Any]) -> [BackupExecutionSnapshot] {
        let executions = object["executions"] as? [[String: Any]] ?? []
        return executions.compactMap { execution in
            guard let id = execution["id"] as? Int else { return nil }
            let details = execution["details"] as? [String: Any]
            let snapshotID = details?["snapshotId"] as? String
            return BackupExecutionSnapshot(
                id: id,
                triggeredBy: execution["triggeredBy"] as? String,
                startedAt: (execution["startedAt"] as? String) ?? (execution["triggeredAt"] as? String),
                durationMilliseconds: execution["duration"] as? Int,
                status: execution["status"] as? String,
                errorMessage: execution["errorMessage"] as? String,
                snapshotShortID: snapshotID.map { String($0.prefix(8)) },
                dataAdded: details?["dataAdded"] as? Int
            )
        }
    }

    static func decodeBackupSnapshots(_ result: Any?) -> [BackupSnapshotSummary] {
        let snapshots = result as? [[String: Any]] ?? []
        return snapshots.compactMap { snapshot in
            guard let id = snapshot["id"] as? String else { return nil }
            return BackupSnapshotSummary(
                id: id,
                shortID: snapshot["shortId"] as? String ?? String(id.prefix(8)),
                time: snapshot["time"] as? String
            )
        }
        .sorted { ($0.time ?? "") > ($1.time ?? "") }
    }

    /// Dockhand stores some config columns as JSON text; accept either form.
    private static func decodeEmbeddedJSON(_ value: Any?) -> Any? {
        guard let text = value as? String else { return value }
        return try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    private static func retentionPolicy(_ object: [String: Any]?) -> [BackupRetentionRule] {
        let order = ["keepLast", "keepHourly", "keepDaily", "keepWeekly", "keepMonthly", "keepYearly"]
        return order.compactMap { key in
            guard let value = object?[key] as? Int, value > 0 else { return nil }
            return BackupRetentionRule(key: key, value: value)
        }
    }

    /// Progress lines carry `{ status, message }`; the final `result` follows
    /// Dockhand's BackupResult (`success`/`warning`/`skipped`/`error`).
    static func decodeBackupRunJob(_ object: [String: Any]) -> BackupRunJobSnapshot {
        let lines = object["lines"] as? [[String: Any]] ?? []
        let messages = lines.compactMap { line -> String? in
            guard (line["event"] as? String) != "result",
                  let data = line["data"] as? [String: Any] else { return nil }
            let text = (data["message"] as? String) ?? (data["status"] as? String)
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
        let result = object["result"] as? [String: Any]
            ?? lines.last(where: { ($0["event"] as? String) == "result" })?["data"] as? [String: Any]
        let detail = (result?["error"] as? String)
            ?? (result?["reason"] as? String)
            ?? (result?["warning"] as? String)
        return BackupRunJobSnapshot(
            status: object["status"] as? String ?? "running",
            messages: messages,
            resultStatus: result?["status"] as? String,
            resultDetail: detail
        )
    }

    static func decodeStackEnvVariables(_ object: [String: Any]) -> [StackEnvVariable] {
        let variables = object["variables"] as? [[String: Any]] ?? []
        return variables.compactMap { variable in
            guard let key = variable["key"] as? String else { return nil }
            return StackEnvVariable(
                key: key,
                value: variable["value"] as? String ?? "",
                isSecret: variable["isSecret"] as? Bool ?? false
            )
        }
    }

    static func decodeVolumes(_ objects: [[String: Any]]) -> [VolumeSnapshot] {
        objects.compactMap { volume in
            guard let name = volume["name"] as? String else { return nil }
            let usageObjects = volume["usedBy"] as? [[String: Any]] ?? []
            let usedBy = usageObjects.compactMap { usage -> VolumeUsageSnapshot? in
                guard let containerID = usage["containerId"] as? String,
                      let containerName = usage["containerName"] as? String else {
                    return nil
                }
                return VolumeUsageSnapshot(containerID: containerID, containerName: containerName)
            }
            return VolumeSnapshot(
                name: name,
                driver: volume["driver"] as? String ?? String(localized: "Unknown"),
                scope: volume["scope"] as? String ?? String(localized: "Unknown"),
                usedBy: usedBy
            )
        }
    }

    static func decodeNetworks(_ objects: [[String: Any]]) -> [NetworkSnapshot] {
        objects.compactMap { network in
            guard let id = network["id"] as? String,
                  let name = network["name"] as? String else {
                return nil
            }

            let containerObjects = network["containers"] as? [String: [String: Any]] ?? [:]
            let containers = containerObjects.map { containerID, container in
                NetworkUsageSnapshot(
                    containerID: containerID,
                    containerName: container["name"] as? String ?? String(localized: "Unknown container"),
                    ipv4Address: container["ipv4Address"] as? String ?? ""
                )
            }
            .sorted { $0.containerName.localizedCaseInsensitiveCompare($1.containerName) == .orderedAscending }

            let ipam = network["ipam"] as? [String: Any]
            let configurations = ipam?["config"] as? [[String: Any]] ?? []
            let subnets = configurations.compactMap { $0["subnet"] as? String }

            return NetworkSnapshot(
                id: id,
                name: name,
                driver: network["driver"] as? String ?? String(localized: "Unknown"),
                scope: network["scope"] as? String ?? String(localized: "Unknown"),
                isInternal: network["internal"] as? Bool ?? false,
                subnets: subnets,
                containers: containers
            )
        }
    }

    static func decodeContainerActivity(_ object: [String: Any]) -> ContainerActivitySnapshot {
        let eventObjects = object["events"] as? [[String: Any]] ?? []
        let events = eventObjects.compactMap { event -> ContainerEventSnapshot? in
            guard let id = intValue(event["id"]),
                  let containerID = event["containerId"] as? String,
                  let action = event["action"] as? String,
                  let timestamp = event["timestamp"] as? String else {
                return nil
            }
            return ContainerEventSnapshot(
                id: id,
                containerID: containerID,
                containerName: event["containerName"] as? String,
                image: event["image"] as? String,
                action: action,
                timestamp: timestamp
            )
        }
        return ContainerActivitySnapshot(
            events: events,
            total: intValue(object["total"]) ?? events.count
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        return nil
    }
}
