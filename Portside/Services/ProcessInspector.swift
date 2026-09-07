import Foundation

/// Maps a listening process back to the project directory it was started from,
/// so the UI can show "my-shop (Next.js)" instead of "node".
enum ProcessInspector {
    /// Returns the current working directory for each PID we can inspect.
    static func workingDirectories(for pids: [Int32]) async -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
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

    /// Walks up from `path` looking for a project marker (package.json, Cargo.toml, ...).
    static func project(at path: String) -> ProjectInfo? {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var dir = URL(fileURLWithPath: path).standardizedFileURL
        for _ in 0..<6 {
            // Don't identify the home folder or root as a "project".
            if dir.path == home || dir.path == "/" { return nil }
            if let info = detect(in: dir) { return info }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
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
            // Strip npm scope: "@acme/web" -> "web"
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
        else if deps["@remix-run/react"] != nil { kind = .remix }
        else if deps["vite"] != nil { kind = .vite }
        else { kind = .node }

        return ProjectInfo(directory: dir, name: name, kind: kind)
    }
}
