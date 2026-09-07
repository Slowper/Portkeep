import Foundation

/// The project + git worktree a command was run from. This is the unit a
/// reserved port belongs to: the same worktree always gets the same port.
struct WorkspaceIdentity: Hashable, Sendable {
    var directory: String
    var projectName: String
    var projectKind: String
    var repoRoot: String?
    /// Last path component of the worktree, when this isn't the primary checkout.
    var worktreeName: String?
    var branch: String?

    var abbreviatedPath: String {
        (directory as NSString).abbreviatingWithTildeInPath
    }

    /// Stable key for the lease registry. Same worktree + service name → same lease.
    func leaseKey(name: String) -> String {
        "\(repoRoot ?? directory)|\(directory)|\(name)"
    }

    static func detect(at path: String) async -> WorkspaceIdentity {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let project = ProcessInspector.project(at: url.path)
        let directory = project?.directory.path ?? gitRoot(from: url)?.path ?? url.path
        let git = gitInfo(from: URL(fileURLWithPath: directory))
        let branch = await currentBranch(in: git.repoRoot ?? directory)
        return WorkspaceIdentity(
            directory: directory,
            projectName: project?.name ?? URL(fileURLWithPath: directory).lastPathComponent,
            projectKind: project?.kind.rawValue ?? "generic",
            repoRoot: git.repoRoot,
            worktreeName: git.worktreeName,
            branch: branch
        )
    }

    /// Walks up looking for `.git` as a directory (primary) or a file (linked worktree).
    private static func gitRoot(from url: URL) -> URL? {
        var dir = url
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    private static func gitInfo(from directory: URL) -> (repoRoot: String?, worktreeName: String?) {
        let git = directory.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir) else {
            return (nil, nil)
        }
        if isDir.boolValue {
            return (directory.path, nil)
        }
        // Linked worktree: `.git` is a file containing `gitdir: <path>`.
        guard let text = try? String(contentsOf: git, encoding: .utf8) else {
            return (directory.path, directory.lastPathComponent)
        }
        let gitdir = text
            .split(separator: "\n")
            .first { $0.lowercased().hasPrefix("gitdir:") }
            .map { $0.dropFirst(7).trimmingCharacters(in: .whitespaces) }
        guard let gitdir, !gitdir.isEmpty else {
            return (directory.path, directory.lastPathComponent)
        }
        // `.../repo/.git/worktrees/feat-auth` → repo is two levels up from `worktrees`.
        let gitdirURL = URL(fileURLWithPath: gitdir).standardizedFileURL
        var repoRoot: String?
        if gitdirURL.path.contains("/worktrees/") {
            repoRoot = gitdirURL
                .deletingLastPathComponent() // worktree name
                .deletingLastPathComponent() // worktrees
                .deletingLastPathComponent() // .git
                .path
        }
        return (repoRoot ?? directory.path, directory.lastPathComponent)
    }

    private static func currentBranch(in directory: String) async -> String? {
        guard let result = try? await ShellRunner.run("/usr/bin/git", ["-C", directory, "rev-parse", "--abbrev-ref", "HEAD"], timeout: 3),
              result.succeeded else { return nil }
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "HEAD" ? nil : name
    }
}
