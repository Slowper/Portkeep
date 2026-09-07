import Foundation

struct ProcessMeta: Sendable, Hashable {
    var cwd: String?
    var executable: String?
    /// Seconds since the process started.
    var uptime: TimeInterval?

    var uptimeLabel: String? {
        guard let uptime else { return nil }
        let s = Int(uptime)
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return h < 10 ? "\(h)h \(m % 60)m" : "\(h)h" }
        let d = h / 24
        return d < 7 ? "\(d)d \(h % 24)h" : "\(d)d"
    }
}

/// Resolves what a listening process *is*: where it was started, which binary
/// it runs, how long it's been alive, and which project it belongs to.
enum ProcessInspector {
    static func metadata(for pids: [Int32]) async -> [Int32: ProcessMeta] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")

        async let cwds = workingDirectories(list: list)
        async let psInfo = processInfo(list: list)

        var result: [Int32: ProcessMeta] = [:]
        for (pid, cwd) in await cwds {
            result[pid, default: ProcessMeta()].cwd = cwd
        }
        for (pid, info) in await psInfo {
            result[pid, default: ProcessMeta()].executable = info.executable
            result[pid, default: ProcessMeta()].uptime = info.uptime
        }
        return result
    }

    private static func workingDirectories(list: String) async -> [Int32: String] {
        guard let result = try? await ShellRunner.run(
            PortScanner.lsofPath,
            ["-a", "-p", list, "-d", "cwd", "-F", "pn"]
        ) else { return [:] }

        var map: [Int32: String] = [:]
        var current: Int32?
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p": current = Int32(value)
            case "n": if let pid = current { map[pid] = value }
            default: break
            }
        }
        return map
    }

    private static func processInfo(list: String) async -> [Int32: (executable: String, uptime: TimeInterval?)] {
        // etime: [[dd-]hh:]mm:ss   comm: full executable path
        guard let result = try? await ShellRunner.run("/bin/ps", ["-o", "pid=,etime=,comm=", "-p", list]) else { return [:] }
        var map: [Int32: (String, TimeInterval?)] = [:]
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = Int32(parts[0]) else { continue }
            let etime = String(parts[1])
            let comm = parts.count > 2 ? String(parts[2]).trimmingCharacters(in: .whitespaces) : ""
            map[pid] = (comm, parseElapsed(etime))
        }
        return map
    }

    static func parseElapsed(_ etime: String) -> TimeInterval? {
        var days = 0
        var rest = etime
        if let dash = rest.firstIndex(of: "-") {
            days = Int(rest[..<dash]) ?? 0
            rest = String(rest[rest.index(after: dash)...])
        }
        let parts = rest.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        var seconds = 0
        for part in parts { seconds = seconds * 60 + part }
        return TimeInterval(days * 86_400 + seconds)
    }

    // MARK: - Project detection

    /// Walks up from `path` looking for a project marker (package.json, Cargo.toml, ...).
    static func project(at path: String) -> ProjectInfo? {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var dir = URL(fileURLWithPath: path).standardizedFileURL
        for _ in 0..<6 {
            if dir.path == home || dir.path == "/" { return nil }
            if let info = detect(in: dir) { return info }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    /// Should this process be presented as part of `project`? Being started
    /// from a folder isn't enough: `ollama serve` run from a Next.js repo is
    /// not that app. We require a matching runtime, a binary inside the repo,
    /// or a name match.
    static func belongs(command: String, meta: ProcessMeta?, to project: ProjectInfo) -> Bool {
        if let exe = meta?.executable, exe.hasPrefix(project.directory.path + "/") { return true }
        let cmd = command.lowercased()
        if cmd == project.name.lowercased() || cmd == project.directory.lastPathComponent.lowercased() { return true }
        let runtimes = project.kind == .generic ? ProjectKind.allRuntimeNames : Set(project.kind.runtimeNames)
        return runtimes.contains { cmd == $0 || cmd.hasPrefix($0 + " ") || cmd.hasPrefix($0 + "-") }
    }

    private static func detect(in dir: URL) -> ProjectInfo? {
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(name).path) }
        func info(_ kind: ProjectKind, name: String? = nil) -> ProjectInfo {
            ProjectInfo(directory: dir, name: name ?? dir.lastPathComponent, kind: kind)
        }

        if has("package.json") {
            return detectNode(in: dir) ?? info(.node)
        }
        if has("Cargo.toml") { return info(.rust) }
        if has("go.mod") { return info(.go) }
        if has("mix.exs") { return info(.elixir) }
        if has("Package.swift") { return info(.swift) }
        if has("Gemfile") { return info(.ruby) }
        if has("composer.json") || has("artisan") { return info(.php) }
        if has("pyproject.toml") || has("manage.py") || has("requirements.txt") || has("Pipfile") {
            return info(.python)
        }
        if has("pom.xml") || has("build.gradle") || has("build.gradle.kts") { return info(.java) }
        if has("global.json") || (try? fm.contentsOfDirectory(atPath: dir.path))?.contains(where: { $0.hasSuffix(".csproj") || $0.hasSuffix(".sln") }) == true {
            return info(.dotnet)
        }
        if has(".git") { return info(.generic) }
        return nil
    }

    private static func detectNode(in dir: URL) -> ProjectInfo? {
        let url = dir.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var name = dir.lastPathComponent
        if let declared = json["name"] as? String, !declared.isEmpty {
            name = declared.split(separator: "/").last.map(String.init) ?? declared
        }

        var deps: [String: Any] = json["dependencies"] as? [String: Any] ?? [:]
        for (key, value) in json["devDependencies"] as? [String: Any] ?? [:] {
            deps[key] = value
        }

        let kind: ProjectKind
        if deps["next"] != nil { kind = .next }
        else if deps["nuxt"] != nil { kind = .nuxt }
        else if deps["astro"] != nil { kind = .astro }
        else if deps["@sveltejs/kit"] != nil { kind = .sveltekit }
        else if deps["@remix-run/react"] != nil { kind = .remix }
        else if deps["vite"] != nil { kind = .vite }
        else { kind = .node }

        return ProjectInfo(directory: dir, name: name, kind: kind)
    }
}
