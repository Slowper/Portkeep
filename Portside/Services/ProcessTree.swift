import Foundation

/// A snapshot of every process on the machine, used to attribute listeners to
/// whoever started them and to find the full tree a dev server lives in.
struct ProcessTree: Sendable {
    struct Entry: Sendable {
        let pid: Int32
        let ppid: Int32
        /// `ps comm`: the executable path, or the title Electron helpers set
        /// ("Cursor Helper (Plugin): extension-host (agent-exec) …").
        let comm: String
        /// Full command line.
        let args: String
        /// Resident set size in bytes.
        let rss: UInt64
        let cpu: Double

        var name: String { (comm as NSString).lastPathComponent }
        var lowerComm: String { comm.lowercased() }
        var lowerArgs: String { args.lowercased() }
    }

    private let entries: [Int32: Entry]
    private let children: [Int32: [Int32]]
    /// PIDs launchd started deliberately (LaunchAgents, `brew services`).
    /// A dev server reparented to launchd after its terminal died is *not* here.
    private let launchdManaged: Set<Int32>

    init(entries: [Entry], launchdManaged: Set<Int32> = []) {
        var byPID: [Int32: Entry] = [:]
        var kids: [Int32: [Int32]] = [:]
        for entry in entries {
            byPID[entry.pid] = entry
            kids[entry.ppid, default: []].append(entry.pid)
        }
        self.entries = byPID
        self.children = kids
        self.launchdManaged = launchdManaged
    }

    subscript(pid: Int32) -> Entry? { entries[pid] }

    // MARK: - Snapshot

    static func snapshot() async -> ProcessTree {
        // comm can contain spaces, so it goes last and we split the four
        // numeric columns off the front. args likewise in a second call.
        async let commResult = try? ShellRunner.run("/bin/ps", ["-axo", "pid=,ppid=,pcpu=,rss=,comm="])
        async let argsResult = try? ShellRunner.run("/bin/ps", ["-axo", "pid=,args="])
        async let launchctlResult = try? ShellRunner.run("/bin/launchctl", ["list"])

        var managed = Set<Int32>()
        if let out = await launchctlResult?.stdout {
            // "PID\tStatus\tLabel" — a dash in the PID column means not running.
            for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
                if let first = line.split(separator: "\t", maxSplits: 1).first, let pid = Int32(first) {
                    managed.insert(pid)
                }
            }
        }

        var args: [Int32: String] = [:]
        if let out = await argsResult?.stdout {
            for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
                let trimmed = line.drop(while: { $0 == " " })
                guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { continue }
                args[pid] = String(trimmed[trimmed.index(after: space)...])
            }
        }

        var entries: [Entry] = []
        if let out = await commResult?.stdout {
            for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
                let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
                guard parts.count == 5,
                      let pid = Int32(parts[0]), let ppid = Int32(parts[1]),
                      let cpu = Double(parts[2]), let rssKB = UInt64(parts[3]) else { continue }
                let comm = String(parts[4])
                entries.append(Entry(pid: pid, ppid: ppid, comm: comm, args: args[pid] ?? comm, rss: rssKB * 1024, cpu: cpu))
            }
        }
        return ProcessTree(entries: entries, launchdManaged: managed)
    }

    // MARK: - Lineage

    /// Attributes `pid` to its origin and finds the process tree it belongs to.
    func lineage(for pid: Int32, cwd: String?, project: ProjectInfo?) -> ProcessLineage? {
        guard let start = entries[pid] else { return nil }

        // Walk up until we hit a boundary: a host app, an agent, an interactive
        // shell owned by a host, or launchd. Remember the last non-boundary pid
        // — that's the tree root (e.g. `npm run dev`).
        var root = start
        var current = start
        var boundary: Entry?
        var steps = 0
        while current.ppid > 1, let parent = entries[current.ppid], steps < 32 {
            steps += 1
            if isBoundary(parent) {
                boundary = parent
                break
            }
            root = parent
            current = parent
        }
        // Continue past the boundary purely to classify (an agent inside an editor).
        var ancestors: [Entry] = []
        if let boundary {
            ancestors.append(boundary)
            var p = boundary
            var hops = 0
            while p.ppid > 1, let parent = entries[p.ppid], hops < 16 {
                ancestors.append(parent)
                p = parent
                hops += 1
            }
        }

        let directoryMissing: Bool = {
            guard let cwd, cwd != "/" else { return false }
            return !FileManager.default.fileExists(atPath: cwd)
        }()

        let origin: ProcessOrigin
        if let agent = ancestors.compactMap(Self.agentOrigin).first {
            origin = agent
        } else if let host = ancestors.compactMap(Self.hostOrigin).first {
            origin = host
        } else if boundary == nil {
            // Reached launchd without any host: leftover, user LaunchAgent, or infra.
            // A project gateway (AgentX, Vite as a Login Item) is in `launchctl list`
            // but is still something the user started — do not treat it as postgres.
            if Self.isKnownService(root) {
                origin = .service
            } else if Self.looksLikeDevProcess(root, cwd: cwd, project: project) {
                origin = .orphaned
            } else if launchdManaged.contains(root.pid) {
                origin = .service
            } else {
                origin = .service
            }
        } else {
            origin = .unknown
        }

        let tree = descendants(of: root.pid)
        let memory = tree.reduce(UInt64(0)) { $0 + (entries[$1]?.rss ?? 0) }
        let cpu = tree.reduce(0.0) { $0 + (entries[$1]?.cpu ?? 0) }

        return ProcessLineage(
            origin: origin,
            treeRoot: root.pid,
            rootCommand: Self.displayCommand(root),
            treePIDs: tree,
            treeMemory: memory,
            treeCPU: cpu,
            directoryMissing: directoryMissing
        )
    }

    /// `pid` plus every descendant.
    func descendants(of pid: Int32) -> [Int32] {
        var result: [Int32] = []
        var queue = [pid]
        var seen = Set<Int32>()
        while let next = queue.first {
            queue.removeFirst()
            guard !seen.contains(next) else { continue }
            seen.insert(next)
            result.append(next)
            queue.append(contentsOf: children[next] ?? [])
        }
        return result
    }

    // MARK: - Classification

    private static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "nu", "tcsh", "ksh", "dash", "login"]

    private static let terminalNames: [(needle: String, label: String)] = [
        ("iterm2", "iTerm"), ("terminal", "Terminal"), ("warp", "Warp"), ("ghostty", "Ghostty"),
        ("kitty", "kitty"), ("alacritty", "Alacritty"), ("wezterm", "WezTerm"), ("hyper", "Hyper"),
        ("tabby", "Tabby"), ("rio", "Rio"),
    ]

    private static func isHostApp(_ e: Entry) -> Bool {
        hostOrigin(e) != nil || agentOrigin(e) != nil
    }

    /// A process that owns whatever runs beneath it, and must never be part of a tree kill.
    private func isBoundary(_ e: Entry) -> Bool {
        if Self.isHostApp(e) { return true }
        let name = e.name.lowercased()
        if name == "tmux" || name.hasPrefix("tmux:") || name == "sshd" || name == "launchd" || name == "login" { return true }
        // A shell is a boundary when it's the user's (or agent's) interactive
        // shell, i.e. its own parent is a host. `sh -c "next dev"` under npm is
        // part of the tree, not a boundary.
        if Self.shells.contains(name) {
            guard let parent = entries[e.ppid] else { return e.ppid <= 1 }
            let parentName = parent.name.lowercased()
            if Self.isHostApp(parent) || parentName == "login" || parentName == "tmux" || parentName == "sshd" {
                return true
            }
        }
        return false
    }

    private static func agentOrigin(_ e: Entry) -> ProcessOrigin? {
        let name = e.name.lowercased()
        let comm = e.lowerComm
        let args = e.lowerArgs
        if name == "claude" || comm.contains("@anthropic-ai/claude-code") || args.contains("claude-code/cli.js") { return .claudeCode }
        if name == "codex" || comm.contains("codex.app/") || args.hasPrefix("codex ") || args == "codex" { return .codex }
        if name == "cursor-agent" || args.hasPrefix("cursor-agent") { return .cursorAgent }
        if comm.contains("cursor helper (plugin)") && comm.contains("(agent-exec)") { return .cursorAgent }
        if name == "gemini" || args.contains("@google/gemini-cli") { return .geminiCLI }
        if name == "aider" || args.contains("aider/main.py") { return .aider }
        if name == "opencode" || args.hasPrefix("opencode ") { return .openCode }
        return nil
    }

    private static func hostOrigin(_ e: Entry) -> ProcessOrigin? {
        let comm = e.lowerComm
        let name = e.name.lowercased()
        if comm.contains("cursor.app/") || comm.hasPrefix("cursor helper") || name == "cursor" { return .cursor }
        if comm.contains("visual studio code.app/") || comm.hasPrefix("code helper") || name == "electron" && comm.contains("vscode") { return .vscode }
        if comm.contains("windsurf.app/") || comm.hasPrefix("windsurf helper") { return .windsurf }
        if comm.contains("zed.app/") || name == "zed" { return .zed }
        if name == "tmux" || name.hasPrefix("tmux:") { return .tmux }
        if name == "sshd" { return .ssh }
        for (needle, label) in terminalNames {
            if comm.contains("/\(needle).app/") || comm.contains("/\(needle)2.app/") || name == needle {
                return .terminal(label)
            }
        }
        return nil
    }

    private static let devRuntimes: Set<String> = ProjectKind.allRuntimeNames
        .union(["cloudflared", "ngrok", "storybook", "vitest", "jest", "playwright", "chromium", "chrome", "uvicorn", "gunicorn", "flask", "rails", "puma", "php", "beam.smp", "dotnet", "java", "bun"])

    private static let systemPrefixes = ["/system/", "/usr/", "/bin/", "/sbin/", "/library/", "/applications/", "/opt/homebrew/", "/usr/local/"]

    static func isKnownService(_ e: Entry) -> Bool {
        if Policy.isProtectedName(e.name) { return true }
        // App-bundled binaries are managed by their app, not by a terminal.
        return e.lowerComm.hasPrefix("/applications/") && e.lowerComm.contains(".app/")
    }

    /// Distinguishes a leftover dev server from a Homebrew/launchd service.
    private static func looksLikeDevProcess(_ root: Entry, cwd: String?, project: ProjectInfo?) -> Bool {
        if project != nil { return true }
        let comm = root.lowerComm
        let home = FileManager.default.homeDirectoryForCurrentUser.path.lowercased()
        if comm.contains("/node_modules/") || comm.contains("/.bun/") || comm.contains("/.nvm/") || comm.contains("/.volta/") || comm.contains("/.cargo/") || comm.contains("/.local/share/") { return true }
        if systemPrefixes.contains(where: { comm.hasPrefix($0) }) && !comm.contains("/node_modules/") {
            // Installed binary (e.g. /opt/homebrew/bin/node) — dev if it was launched from a project-ish folder.
            if let cwd, cwd.lowercased().hasPrefix(home + "/"), cwd.lowercased() != home { return devRuntimes.contains(root.name.lowercased()) }
            return false
        }
        if comm.hasPrefix(home) { return devRuntimes.contains(root.name.lowercased()) || cwd.map { $0 != "/" } ?? false }
        return devRuntimes.contains(root.name.lowercased())
    }

    private static func displayCommand(_ e: Entry) -> String {
        let args = e.args.trimmingCharacters(in: .whitespaces)
        if args.isEmpty { return e.name }
        // "/opt/homebrew/bin/npm run dev" → "npm run dev"
        var parts = args.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if let first = parts.first, first.contains("/") { parts[0] = (first as NSString).lastPathComponent }
        // Electron helpers: keep the readable title instead of a flag soup.
        if parts.first?.lowercased().contains("helper") == true || args.contains("--type=") { return e.name }
        let joined = parts.prefix(4).joined(separator: " ")
        return joined.count > 48 ? String(joined.prefix(46)) + "…" : joined
    }
}
