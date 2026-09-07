import Foundation

enum MCPInstallError: LocalizedError {
    case invalidConfig(URL)

    var errorDescription: String? {
        switch self {
        case .invalidConfig(let url):
            "\(url.path) is not a JSON object. Fix or move that file, then try again."
        }
    }
}

enum MCPHost: String, CaseIterable, Identifiable, Sendable {
    case cursor
    case claudeCode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cursor: "Cursor"
        case .claudeCode: "Claude Code"
        }
    }

    var configURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .cursor:
            return home.appendingPathComponent(".cursor/mcp.json")
        case .claudeCode:
            return home.appendingPathComponent(".claude.json")
        }
    }

    var isAvailable: Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        switch self {
        case .cursor:
            return fm.fileExists(atPath: home.appendingPathComponent(".cursor").path)
        case .claudeCode:
            return fm.fileExists(atPath: configURL.path)
                || fm.fileExists(atPath: home.appendingPathComponent(".claude").path)
        }
    }
}

/// Writes the Portkeep stdio MCP server into Cursor / Claude Code config.
/// Merges `mcpServers.portkeep` only — never replaces the rest of the file.
enum MCPInstall {
    static let serverName = "portkeep"

    static var snippet: String {
        """
        ## Local ports

        Use Portkeep so agents and worktrees don't fight over :3000.

        - Before starting a dev server: `PORT=$(portkeep alloc web)` then bind to `$PORT`.
        - On EADDRINUSE: `portkeep who <port>` — do not rewrite application code to "fix" a busy port.
        - To free a port: `portkeep stop <port>` (kills the process tree, not just the leaf pid).
        - Do not stop postgres, redis, docker, ollama, or anything bound on 0.0.0.0 without an explicit confirm.

        If the Portkeep MCP server is available, call `allocate_port`, `who_owns_port`, and `stop_listener` instead of shelling out.
        """
    }

    static func isInstalled(in host: MCPHost) -> Bool {
        guard let root = try? readObject(host.configURL) else { return false }
        let servers = root["mcpServers"] as? [String: Any] ?? [:]
        return servers[serverName] != nil
    }

    @discardableResult
    static func install(into host: MCPHost) throws -> URL {
        let command = try ensureCLI().path
        try mutate(host.configURL) { root in
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            servers[serverName] = entry(for: host, command: command)
            root["mcpServers"] = servers
        }
        Audit.record(action: "mcp_install", command: host.rawValue, path: host.configURL.path)
        return host.configURL
    }

    static func remove(from host: MCPHost) throws {
        guard FileManager.default.fileExists(atPath: host.configURL.path) else { return }
        try mutate(host.configURL) { root in
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            servers.removeValue(forKey: serverName)
            root["mcpServers"] = servers
        }
        Audit.record(action: "mcp_remove", command: host.rawValue, path: host.configURL.path)
    }

    @discardableResult
    static func installDetected() throws -> [MCPHost] {
        let hosts = MCPHost.allCases.filter(\.isAvailable)
        for host in hosts {
            try install(into: host)
        }
        return hosts
    }

    @discardableResult
    static func writeSnippet(to directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("AGENTS.md")
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let existing = try String(contentsOf: url, encoding: .utf8)
            if existing.localizedCaseInsensitiveContains("portkeep alloc") {
                return url
            }
            let merged = existing.trimmingCharacters(in: .newlines) + "\n\n" + snippet + "\n"
            try merged.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try (snippet + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        Audit.record(action: "agents_snippet", path: url.path)
        return url
    }

    @discardableResult
    static func ensureCLI() throws -> URL {
        try CLIInstall.install()
    }

    private static func entry(for host: MCPHost, command: String) -> [String: Any] {
        switch host {
        case .cursor:
            return ["command": command, "args": ["mcp"]]
        case .claudeCode:
            return ["type": "stdio", "command": command, "args": ["mcp"]]
        }
    }

    private static func readObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPInstallError.invalidConfig(url)
        }
        return object
    }

    private static func mutate(_ url: URL, _ body: (inout [String: Any]) throws -> Void) throws {
        let fm = FileManager.default
        var root: [String: Any] = [:]
        if fm.fileExists(atPath: url.path) {
            root = try readObject(url)
        }
        try body(&root)
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        data.append(contentsOf: [0x0A])
        try data.write(to: url, options: .atomic)
    }
}
