import Foundation

/// A reserved localhost port for one service in one worktree.
struct PortLease: Identifiable, Hashable, Sendable, Codable {
    var name: String
    var port: Int
    var directory: String
    var repoRoot: String?
    var worktreeName: String?
    var projectName: String
    var branch: String?
    var createdAt: Date
    var lastUsedAt: Date

    var id: String { "\(repoRoot ?? directory)|\(directory)|\(name)" }

    var abbreviatedPath: String {
        (directory as NSString).abbreviatingWithTildeInPath
    }

    var contextLabel: String {
        if let worktreeName, let branch {
            return "\(worktreeName) · \(branch)"
        }
        if let worktreeName { return worktreeName }
        if let branch { return branch }
        return name
    }
}

struct LeaseStore: Codable, Sendable {
    var version: Int = 1
    var leases: [PortLease] = []
}
