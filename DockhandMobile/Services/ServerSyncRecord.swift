import Foundation

/// One independently merged record per server. Tombstones prevent offline resurrection.
struct ServerSyncRecord: Codable, Equatable, Sendable {
    var profile: DockhandServerProfile
    var modified: Date
    var mutation: String
    var credentialID: String
    var position: Int
    var deleted: Bool
    var orderModified: Date = .distantPast
    var orderMutation: String = ""

    static func merged(_ local: Self, _ remote: Self) -> Self {
        var result = local.supersedes(remote) ? local : remote
        let localOrderWins = local.orderModified == remote.orderModified
            ? local.orderMutation > remote.orderMutation : local.orderModified > remote.orderModified
        let order = localOrderWins ? local : remote
        result.position = order.position
        result.orderModified = order.orderModified
        result.orderMutation = order.orderMutation
        return result
    }

    func supersedes(_ other: Self) -> Bool {
        modified == other.modified ? mutation > other.mutation : modified > other.modified
    }
}
