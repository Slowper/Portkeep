import Foundation

@main
struct PortkeepCLI {
    static func main() async {
        await CLI.run()
    }
}

/// Command-line interface for agents and humans. Prints a port number on its
/// own line for `alloc` so shells can `PORT=$(portkeep alloc web)`.
enum CLI {
    static func run() async {
        await Audit.$source.withValue(.cli) {
            await runInner()
        }
    }

    private static func runInner() async {
        let parsed = Arguments.parse(CommandLine.arguments.dropFirst())
        do {
            switch parsed.command {
            case .help, .none:
                print(helpText)
            case .list, .ls:
                try await list(json: parsed.json, query: parsed.positional)
            case .who:
                guard let token = parsed.positional, let port = Int(token) else {
                    fail("usage: portkeep who <port>", code: 3)
                }
                try await who(port: port, json: parsed.json)
            case .alloc:
                try await alloc(parsed)
            case .free:
                try await free(parsed)
            case .leases:
                try await leases(json: parsed.json, cwd: parsed.cwd)
            case .env:
                try await env(parsed)
            case .stop:
                guard let token = parsed.positional, let port = Int(token) else {
                    fail("usage: portkeep stop <port>", code: 3)
                }
                try await stop(port: port, force: parsed.force, json: parsed.json, confirmLAN: parsed.lan, peer: parsed.peer)
            case .mcp:
                await MCPServer.run()
            case .install:
                try runInstall(parsed)
            case .uninstall:
                try runUninstall(parsed)
            case .snippet:
                try runSnippet(parsed)
            case .mdm:
                showMDM(json: parsed.json)
            case .peers:
                await showPeers(json: parsed.json)
            case .audit:
                try showAudit(json: parsed.json, limit: parsed.positional.flatMap(Int.init) ?? 50)
            case .settings:
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name("com.sajidpalagiri.portkeep.openSettings"),
                    object: nil,
                    userInfo: nil,
                    deliverImmediately: true
                )
                print("Asked Portkeep to open Settings.")
            }
        } catch let error as PortAllocatorError {
            fail(error.localizedDescription, code: exitCode(for: error))
        } catch {
            fail(error.localizedDescription, code: 1)
        }
    }

    // MARK: - Commands

    private static func list(json: Bool, query: String?) async throws {
        let snapshot = try await RuntimeSnapshot.capture()
        let records = snapshot.records.filter { record in
            guard let query, !query.isEmpty else { return true }
            let q = query.lowercased()
            return String(record.port.port).contains(q)
                || record.port.command.lowercased().contains(q)
                || (record.project?.name.lowercased().contains(q) ?? false)
                || (record.lineage?.origin.label.lowercased().contains(q) ?? false)
        }
        if json {
            printJSON(records.map(DTO.listener))
            return
        }
        if records.isEmpty {
            print("Nothing listening.")
            return
        }
        for record in records {
            print(human(record))
        }
    }

    private static func who(port: Int, json: Bool) async throws {
        let snapshot = try await RuntimeSnapshot.capture()
        if let record = snapshot.record(forPort: port) {
            if json { printJSON(DTO.listener(record)); return }
            print(human(record))
            return
        }
        if let lease = snapshot.leases.first(where: { $0.port == port }) {
            if json { printJSON(DTO.lease(lease, listening: false)); return }
            print(":\(port) reserved for \(lease.projectName)/\(lease.name) at \(lease.abbreviatedPath) — nothing listening")
            return
        }
        fail("Nothing on :\(port).", code: 1)
    }

    private static func alloc(_ parsed: Arguments) async throws {
        let name = parsed.positional ?? "web"
        let cwd = parsed.cwd ?? FileManager.default.currentDirectoryPath
        let snapshot = try? await RuntimeSnapshot.capture()
        let lease = try await PortAllocator.allocate(
            name: name,
            at: cwd,
            preferred: parsed.port,
            range: parsed.range,
            taken: snapshot?.takenPorts ?? []
        )
        if parsed.json {
            printJSON(DTO.lease(lease, listening: snapshot?.takenPorts.contains(lease.port) ?? false))
            return
        }
        print(lease.port)
    }

    private static func free(_ parsed: Arguments) async throws {
        let token = parsed.positional
        let port = token.flatMap(Int.init)
        let name = port == nil ? token : nil
        let cwd = parsed.cwd ?? FileManager.default.currentDirectoryPath
        let lease = try PortAllocator.release(name: name, port: port, at: cwd)
        if parsed.json { printJSON(DTO.lease(lease, listening: false)); return }
        print("Released :\(lease.port) (\(lease.name))")
    }

    private static func leases(json: Bool, cwd: String?) async throws {
        let directory = cwd ?? FileManager.default.currentDirectoryPath
        let identity = await WorkspaceIdentity.detect(at: directory)
        let all = try PortAllocator.allLeases()
        let rows = cwd == nil ? all : all.filter { $0.directory == identity.directory }
        if json { printJSON(rows.map { DTO.lease($0, listening: false) }); return }
        if rows.isEmpty {
            print("No reserved ports.")
            return
        }
        for lease in rows {
            let extra = lease.worktreeName.map { " · \($0)" } ?? ""
            print(":\(lease.port)  \(lease.projectName)/\(lease.name)\(extra)  \(lease.abbreviatedPath)")
        }
    }

    private static func env(_ parsed: Arguments) async throws {
        let name = parsed.positional ?? "web"
        let cwd = parsed.cwd ?? FileManager.default.currentDirectoryPath
        let snapshot = try? await RuntimeSnapshot.capture()
        let lease = try await PortAllocator.allocate(
            name: name,
            at: cwd,
            preferred: parsed.port,
            range: parsed.range,
            taken: snapshot?.takenPorts ?? []
        )
        let key = name.uppercased().replacingOccurrences(of: "-", with: "_")
        print("export PORT=\(lease.port)")
        print("export PORTKEEP_PORT=\(lease.port)")
        print("export PORTKEEP_\(key)_PORT=\(lease.port)")
    }

    private static func stop(port: Int, force: Bool, json: Bool, confirmLAN: Bool, peer: String?) async throws {
        if let peer {
            try await stopRemote(port: port, peer: peer, confirmLAN: confirmLAN, json: json)
            return
        }
        let snapshot = try await RuntimeSnapshot.capture()
        guard let record = snapshot.record(forPort: port) else {
            fail("Nothing on :\(port).", code: 1)
        }
        let verdict = Policy.evaluate(
            command: record.port.command,
            executable: nil,
            cwd: record.project?.directory.path,
            addresses: record.port.addresses,
            origin: record.lineage?.origin,
            extraCommands: [record.lineage?.rootCommand].compactMap { $0 }
        )
        switch verdict {
        case .deny(let reason):
            Audit.record(action: "policy_deny", ok: false, port: port, command: record.port.command, detail: reason)
            fail(reason, code: 4)
        case .confirm(let reason):
            if !confirmLAN {
                Audit.record(action: "policy_deny", ok: false, port: port, command: record.port.command, detail: reason)
                fail("\(reason) Re-run with --lan to confirm.", code: 5)
            }
        case .allow:
            break
        }
        let pids = ProcessKiller.pids(lineage: record.lineage, fallback: record.port.pid)
        let outcome = ProcessKiller.stop(pids: pids, force: force)
        if !force {
            await ProcessKiller.escalate(pids)
        }
        let label = record.lineage?.rootCommand ?? record.port.command
        Audit.record(
            action: "stop",
            ok: outcome.succeeded,
            port: port,
            command: label,
            pids: pids,
            project: record.project?.name,
            path: record.project?.directory.path,
            detail: force ? "SIGKILL" : "SIGTERM"
        )
        if json {
            printJSON([
                "port": port,
                "pids": pids.map(Int.init),
                "signalled": outcome.signalled.map(Int.init),
                "failed": outcome.failed.map(Int.init),
            ] as [String: Any])
            return
        }
        guard outcome.succeeded else {
            fail("Couldn't stop :\(port).", code: 1)
        }
        print("Stopped \(label) on :\(port) · \(pids.count) process\(pids.count == 1 ? "" : "es")")
    }

    private static func showAudit(json: Bool, limit: Int) throws {
        let events = Audit.recent(limit: max(1, limit))
        if json {
            printJSON(events.map(\.dictionary))
            return
        }
        if events.isEmpty {
            print("No audit events. Log: \(Audit.url.path)")
            return
        }
        for event in events {
            print(event.line)
        }
        print("  \(Audit.url.path)")
    }

    private static func runInstall(_ parsed: Arguments) throws {
        let hosts = hosts(from: parsed)
        if hosts.isEmpty && !parsed.mcp {
            let url = try CLIInstall.install()
            print("Installed \(url.path)")
            remindPATH(url)
            return
        }
        let cli = try MCPInstall.ensureCLI()
        print("CLI \(cli.path)")
        remindPATH(cli)
        let targets: [MCPHost]
        if parsed.mcp && hosts.isEmpty {
            targets = try MCPInstall.installDetected()
        } else {
            targets = hosts.isEmpty ? MCPHost.allCases.filter(\.isAvailable) : hosts
            for host in targets {
                try MCPInstall.install(into: host)
            }
        }
        if targets.isEmpty {
            print("No Cursor or Claude Code config found.")
            return
        }
        for host in targets {
            print("MCP \(host.title) → \(host.configURL.path)")
        }
        print("Restart \(targets.map(\.title).joined(separator: " / ")) to load the server.")
    }

    private static func runUninstall(_ parsed: Arguments) throws {
        let hosts = hosts(from: parsed)
        if parsed.mcp || !hosts.isEmpty {
            let targets = hosts.isEmpty ? MCPHost.allCases : hosts
            for host in targets {
                try MCPInstall.remove(from: host)
                print("Removed MCP from \(host.title).")
            }
            if !parsed.mcp && !hosts.isEmpty { return }
            if parsed.mcp { return }
        }
        try CLIInstall.uninstall()
        print("Removed the portkeep CLI from PATH.")
    }

    private static func runSnippet(_ parsed: Arguments) throws {
        if parsed.write {
            let directory = URL(fileURLWithPath: parsed.cwd ?? FileManager.default.currentDirectoryPath)
            let url = try MCPInstall.writeSnippet(to: directory)
            print(url.path)
            return
        }
        print(MCPInstall.snippet)
    }

    private static func showMDM(json: Bool) {
        let defaults = PortkeepDefaults.suite
        if json {
            let rows: [[String: Any]] = ManagedKey.all.map { item in
                var row: [String: Any] = [
                    "key": item.key,
                    "meaning": item.meaning,
                    "managed": defaults.objectIsForced(forKey: item.key),
                    "present": defaults.object(forKey: item.key) != nil,
                ]
                if let value = defaults.object(forKey: item.key) {
                    row["value"] = value
                }
                return row
            }
            printJSON([
                "domain": PortkeepDefaults.domain,
                "keys": rows,
            ] as [String: Any])
            return
        }
        print("Domain  \(PortkeepDefaults.domain)")
        print("The CLI and the app both read this domain. Forced keys are locked in Settings.")
        print("")
        for item in ManagedKey.all {
            let forced = defaults.objectIsForced(forKey: item.key)
            let value = defaults.object(forKey: item.key).map { "\($0)" } ?? "—"
            let lock = forced ? "locked" : "open  "
            print("  \(item.key.padding(toLength: 30, withPad: " ", startingAt: 0)) \(lock)  \(value)")
            print("    \(item.meaning)")
        }
    }

    private static func showPeers(json: Bool) async {
        guard let pin = RemotePIN.load() else {
            fail("Turn on Settings → Devices and set a PIN first.", code: 1)
        }
        let peers = await RemoteClient.discover(pin: pin)
        if json {
            printJSON(peers.map { peer -> [String: Any] in
                var dict: [String: Any] = [
                    "name": peer.name,
                    "host": peer.host,
                    "endpoint": peer.endpoint,
                    "leftovers": peer.leftoverCount,
                ]
                if let snap = peer.snapshot {
                    dict["listeners"] = snap.listeners.map { ["port": $0.port, "command": $0.command, "leftBehind": $0.leftBehind] }
                }
                if let error = peer.lastError { dict["error"] = error }
                return dict
            })
            return
        }
        if peers.isEmpty {
            print("No other Portkeep Macs on this network. Enable sharing on both, same PIN.")
            return
        }
        for peer in peers {
            print("\(peer.name)  \(peer.host)  \(peer.leftoverCount) left behind")
            for row in peer.snapshot?.leftovers ?? [] {
                print("  :\(row.port)  \(row.project ?? row.command)")
            }
        }
    }

    private static func stopRemote(port: Int, peer name: String, confirmLAN: Bool, json: Bool) async throws {
        guard let pin = RemotePIN.load() else {
            fail("Turn on Settings → Devices and set a PIN first.", code: 1)
        }
        let peers = await RemoteClient.discover(pin: pin)
        guard let peer = peers.first(where: {
            $0.name.lowercased() == name.lowercased()
                || $0.host.lowercased().hasPrefix(name.lowercased())
        }) else {
            fail("No peer named \(name). Run `portkeep peers`.", code: 1)
        }
        try await RemoteClient.stop(peer: peer, port: port, pin: pin, confirmLAN: confirmLAN)
        if json {
            printJSON(["ok": true, "port": port, "peer": peer.name] as [String: Any])
        } else {
            print("Stopped :\(port) on \(peer.name)")
        }
    }

    private static func hosts(from parsed: Arguments) -> [MCPHost] {
        var list: [MCPHost] = []
        if parsed.cursor { list.append(.cursor) }
        if parsed.claude { list.append(.claudeCode) }
        return list
    }

    // MARK: - Output

    private static func human(_ record: ListenerRecord) -> String {
        let port = record.port
        var line = ":\(port.port)  \(record.project?.name ?? port.command)"
        if let kind = record.project?.kind, kind != .generic { line += "  \(kind.label)" }
        if let origin = record.lineage?.origin, origin.isNotable { line += "  \(origin.label)" }
        if let path = record.project?.abbreviatedPath { line += "  \(path)" }
        var detail = "\(port.command) · \(port.pid)"
        if let mem = record.lineage, mem.treeMemory >= 16 * 1024 * 1024 {
            detail += "  \(mem.treeMemoryLabel)"
        }
        if let uptime = record.meta?.uptimeLabel { detail += "  up \(uptime)" }
        if let lease = record.lease { detail += "  reserved as \(lease.name)" }
        return "\(line)\n  \(detail)"
    }

    private static func printJSON(_ value: Any) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private static func remindPATH(_ url: URL) {
        let bin = url.deletingLastPathComponent().path
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        if !path.split(separator: ":").contains(where: { $0 == bin }) {
            print("Add \(bin) to PATH if `portkeep` isn't found:")
            print("  echo 'export PATH=\"\(bin):$PATH\"' >> ~/.zshrc")
        }
    }

    private static func exitCode(for error: PortAllocatorError) -> Int32 {
        switch error {
        case .notFound: 1
        case .noFreePort: 2
        case .invalidName, .invalidPort: 3
        case .io: 1
        }
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(code)
    }

    static let helpText = """
    portkeep — local runtimes, for humans and agents

    Usage:
      portkeep list [query]          what's listening
      portkeep who <port>            who owns a port
      portkeep alloc [name]          reserve a stable port for this worktree
      portkeep env [name]            print export PORT=… for the shell
      portkeep leases                reserved ports
      portkeep free [name|port]      release a reservation
      portkeep stop <port>           stop the process tree on that port
      portkeep mcp                   MCP server (stdio) for Cursor / Claude Code
      portkeep install               put portkeep on your PATH
      portkeep install --mcp         CLI + Cursor / Claude Code MCP
      portkeep uninstall
      portkeep snippet               print an AGENTS.md block
      portkeep snippet --write       create or append AGENTS.md in this folder
      portkeep settings              open the Settings window
      portkeep audit [n]             last n local audit events (default 50)
      portkeep mdm                   show MDM domain and which keys are locked
      portkeep peers                 other Portkeep Macs on this LAN

    Options:
      --json           machine-readable output
      --cwd <path>     project / worktree (default: current directory)
      --port <n>       preferred port for alloc
      --from <n> --to <n>
                       allocation range (default 3000–4999)
      --force          SIGKILL immediately on stop
      --lan            confirm stopping a process bound on 0.0.0.0 / LAN
      --mcp            with install/uninstall: Cursor + Claude Code
      --cursor         only Cursor
      --claude         only Claude Code
      --write          with snippet: write AGENTS.md
      --peer <name>    stop a port on another Mac (`portkeep peers`)

    Agents: call `alloc` before starting a dev server. Same worktree + name
    always gets the same port back. `who 3000` tells you who already has it.
    """
}

struct Arguments {
    enum Command: String {
        case list, ls, who, alloc, free, leases, env, stop, mcp, install, uninstall, snippet, settings, audit, mdm, peers, help
    }

    var command: Command?
    var positional: String?
    var tokens: [String] = []
    var json = false
    var force = false
    var lan = false
    var mcp = false
    var cursor = false
    var claude = false
    var write = false
    var peer: String?
    var cwd: String?
    var port: Int?
    var from: Int?
    var to: Int?

    var range: ClosedRange<Int> {
        let lower = from ?? PortAllocator.defaultRange.lowerBound
        let upper = to ?? PortAllocator.defaultRange.upperBound
        return min(lower, upper)...max(lower, upper)
    }

    static func parse(_ args: ArraySlice<String>) -> Arguments {
        var parsed = Arguments()
        var rest: [String] = []
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--json": parsed.json = true
            case "--force": parsed.force = true
            case "--lan": parsed.lan = true
            case "--mcp": parsed.mcp = true
            case "--cursor": parsed.cursor = true
            case "--claude": parsed.claude = true
            case "--write": parsed.write = true
            case "--peer": parsed.peer = iterator.next()
            case "--cwd": parsed.cwd = iterator.next()
            case "--port": parsed.port = iterator.next().flatMap(Int.init)
            case "--from": parsed.from = iterator.next().flatMap(Int.init)
            case "--to": parsed.to = iterator.next().flatMap(Int.init)
            case "-h", "--help": parsed.command = .help
            case let value where value.hasPrefix("-"):
                FileHandle.standardError.write(Data("Unknown option: \(value)\n".utf8))
                exit(3)
            default:
                rest.append(arg)
            }
        }
        if let first = rest.first {
            if let command = Command(rawValue: first) {
                parsed.command = command == .ls ? .list : command
                parsed.tokens = Array(rest.dropFirst())
                parsed.positional = parsed.tokens.first
            } else if Int(first) != nil {
                parsed.command = .who
                parsed.positional = first
            } else {
                parsed.command = .list
                parsed.positional = first
            }
        }
        return parsed
    }
}

enum DTO {
    static func listener(_ record: ListenerRecord) -> [String: Any] {
        var dict: [String: Any] = [
            "port": record.port.port,
            "pid": record.port.pid,
            "command": record.port.command,
            "addresses": record.port.addresses,
            "url": "http://localhost:\(record.port.port)",
            "lan": !record.port.isLocalOnly,
        ]
        if let project = record.project {
            dict["project"] = project.name
            dict["kind"] = project.kind.label
            dict["path"] = project.directory.path
        }
        if let lineage = record.lineage {
            dict["origin"] = lineage.origin.label
            dict["tree"] = lineage.rootCommand
            dict["pids"] = lineage.treePIDs.map(Int.init)
            dict["memoryBytes"] = lineage.treeMemory
            dict["leftBehind"] = lineage.isLeftBehind
        }
        if let uptime = record.meta?.uptime {
            dict["uptimeSeconds"] = Int(uptime)
        }
        if let lease = record.lease {
            dict["lease"] = lease.name
        }
        return dict
    }

    static func lease(_ lease: PortLease, listening: Bool) -> [String: Any] {
        var dict: [String: Any] = [
            "name": lease.name,
            "port": lease.port,
            "project": lease.projectName,
            "path": lease.directory,
            "listening": listening,
        ]
        if let repo = lease.repoRoot { dict["repo"] = repo }
        if let worktree = lease.worktreeName { dict["worktree"] = worktree }
        if let branch = lease.branch { dict["branch"] = branch }
        return dict
    }
}
