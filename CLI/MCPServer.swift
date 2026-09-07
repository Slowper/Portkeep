import Foundation

/// MCP server over stdio. Agents call these instead of guessing at :3000.
enum MCPServer {
    static func run() async {
        await Audit.$source.withValue(.mcp) {
            await runInner()
        }
    }

    private static func runInner() async {
        while let message = readMessage() {
            guard let request = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
                  let method = request["method"] as? String else { continue }
            let id = request["id"]
            if id == nil { continue } // notification
            let params = request["params"] as? [String: Any] ?? [:]
            do {
                let result = try await handle(method: method, params: params)
                write(response: ["jsonrpc": "2.0", "id": id as Any, "result": result])
            } catch {
                write(response: [
                    "jsonrpc": "2.0",
                    "id": id as Any,
                    "error": ["code": -32000, "message": error.localizedDescription],
                ])
            }
        }
    }

    private static func handle(method: String, params: [String: Any]) async throws -> Any {
        switch method {
        case "initialize":
            return [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "portkeep", "version": "1.0.0"],
                "instructions": """
                Portkeep is the control plane for local dev servers on this Mac.
                Before starting a server, call allocate_port so worktrees and agent
                sessions don't race for :3000. Call who_owns_port instead of guessing
                at EADDRINUSE. Call stop_listener to kill the whole process tree,
                not just the pid on the port.
                """,
            ]
        case "ping":
            return [:] as [String: Any]
        case "tools/list":
            return ["tools": toolList()]
        case "tools/call":
            guard let name = params["name"] as? String else {
                throw PortAllocatorError.io("Missing tool name.")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            return try await call(name, args)
        default:
            throw PortAllocatorError.io("Unknown method \(method).")
        }
    }

    private static func call(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
        switch name {
        case "list_listeners":
            let snapshot = try await RuntimeSnapshot.capture()
            let query = (args["query"] as? String)?.lowercased() ?? ""
            let rows = snapshot.records.filter { record in
                guard !query.isEmpty else { return true }
                return String(record.port.port).contains(query)
                    || record.port.command.lowercased().contains(query)
                    || (record.project?.name.lowercased().contains(query) ?? false)
                    || (record.lineage?.origin.label.lowercased().contains(query) ?? false)
            }
            return ok(rows.map(DTO.listener))

        case "who_owns_port":
            guard let port = int(args["port"]) else { throw PortAllocatorError.invalidPort }
            let snapshot = try await RuntimeSnapshot.capture()
            if let record = snapshot.record(forPort: port) {
                return ok(DTO.listener(record))
            }
            if let lease = snapshot.leases.first(where: { $0.port == port }) {
                return ok(DTO.lease(lease, listening: false))
            }
            return ok(["port": port, "listening": false, "message": "Nothing on :\(port)."])

        case "allocate_port":
            let service = (args["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "web"
            let cwd = (args["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? FileManager.default.currentDirectoryPath
            let preferred = int(args["port"])
            let snapshot = try? await RuntimeSnapshot.capture()
            let lease = try await PortAllocator.allocate(
                name: service,
                at: cwd,
                preferred: preferred,
                taken: snapshot?.takenPorts ?? []
            )
            return ok(DTO.lease(lease, listening: snapshot?.takenPorts.contains(lease.port) ?? false))

        case "release_port":
            let cwd = args["cwd"] as? String ?? FileManager.default.currentDirectoryPath
            let lease = try PortAllocator.release(
                name: args["name"] as? String,
                port: int(args["port"]),
                at: cwd
            )
            return ok(DTO.lease(lease, listening: false))

        case "list_leases":
            let cwd = args["cwd"] as? String
            let all = try PortAllocator.allLeases()
            if let cwd {
                let identity = await WorkspaceIdentity.detect(at: cwd)
                return ok(all.filter { $0.directory == identity.directory }.map { DTO.lease($0, listening: false) })
            }
            return ok(all.map { DTO.lease($0, listening: false) })

        case "stop_listener":
            guard let port = int(args["port"]) else { throw PortAllocatorError.invalidPort }
            let force = args["force"] as? Bool ?? false
            let confirmLAN = args["confirm_lan"] as? Bool ?? false
            let snapshot = try await RuntimeSnapshot.capture()
            guard let record = snapshot.record(forPort: port) else {
                throw PortAllocatorError.notFound
            }
            switch Policy.evaluate(
                command: record.port.command,
                executable: nil,
                cwd: record.project?.directory.path,
                addresses: record.port.addresses,
                origin: record.lineage?.origin,
                extraCommands: [record.lineage?.rootCommand].compactMap { $0 }
            ) {
            case .deny(let reason):
                Audit.record(action: "policy_deny", ok: false, port: port, command: record.port.command, detail: reason)
                throw PortAllocatorError.io(reason)
            case .confirm(let reason):
                if !confirmLAN {
                    Audit.record(action: "policy_deny", ok: false, port: port, command: record.port.command, detail: reason)
                    throw PortAllocatorError.io("\(reason) Pass confirm_lan=true.")
                }
            case .allow:
                break
            }
            let pids = ProcessKiller.pids(lineage: record.lineage, fallback: record.port.pid)
            let outcome = ProcessKiller.stop(pids: pids, force: force)
            if !force { await ProcessKiller.escalate(pids) }
            Audit.record(
                action: "stop",
                ok: outcome.succeeded,
                port: port,
                command: record.lineage?.rootCommand ?? record.port.command,
                pids: pids,
                project: record.project?.name,
                path: record.project?.directory.path,
                detail: force ? "SIGKILL" : "SIGTERM"
            )
            var payload = DTO.listener(record)
            payload["signalled"] = outcome.signalled.map(Int.init)
            payload["failed"] = outcome.failed.map(Int.init)
            return ok(payload)

        default:
            throw PortAllocatorError.io("Unknown tool \(name).")
        }
    }

    private static func ok(_ value: Any) -> [String: Any] {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let text = String(decoding: data, as: UTF8.self)
        return [
            "content": [["type": "text", "text": text]],
            "isError": false,
        ]
    }

    private static func int(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? Double { return Int(n) }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func toolList() -> [[String: Any]] { [
        tool(
            "list_listeners",
            "List every local dev server and listening port on this Mac, with project, origin (Cursor Agent, Claude Code, …), and process tree.",
            ["query": string("Optional filter: port, project name, command, or origin.")]
        ),
        tool(
            "who_owns_port",
            "Identify who is using a localhost port. Call this on EADDRINUSE instead of rewriting application code.",
            ["port": number("TCP port, e.g. 3000.")]
        ),
        tool(
            "allocate_port",
            "Reserve a stable localhost port for a named service in the current git worktree. Same worktree + name always returns the same port. Call this before starting a dev server.",
            [
                "name": string("Service name, e.g. web, api, vite. Default web."),
                "cwd": string("Project or worktree path. Defaults to the current directory."),
                "port": number("Preferred port if free."),
            ]
        ),
        tool(
            "release_port",
            "Release a reserved port so another worktree can take it.",
            [
                "name": string("Service name to release."),
                "port": number("Or the port number."),
                "cwd": string("Project or worktree path."),
            ]
        ),
        tool(
            "list_leases",
            "List reserved (allocated) ports, optionally for one worktree.",
            ["cwd": string("Limit to this project or worktree.")]
        ),
        tool(
            "stop_listener",
            "Stop the process tree listening on a port (the npm/pnpm wrapper and children, not just the leaf pid). Does not touch Docker daemons or databases.",
            [
                "port": number("TCP port to free."),
                "force": ["type": "boolean", "description": "Send SIGKILL immediately."],
                "confirm_lan": ["type": "boolean", "description": "Required to stop a process bound on 0.0.0.0 / LAN."],
            ]
        ),
    ] }

    private static func tool(_ name: String, _ description: String, _ props: [String: Any]) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": props,
            ],
        ]
    }

    private static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func number(_ description: String) -> [String: Any] {
        ["type": "integer", "description": description]
    }

    // MARK: - Framing

    private static func readMessage() -> Data? {
        let stdin = FileHandle.standardInput
        var headers: [String: String] = [:]
        var lineData = Data()
        while true {
            let chunk = stdin.readData(ofLength: 1)
            if chunk.isEmpty { return nil }
            lineData.append(chunk)
            if lineData.count >= 2, lineData.suffix(2) == Data("\r\n".utf8) {
                let line = String(decoding: lineData.dropLast(2), as: UTF8.self)
                lineData = Data()
                if line.isEmpty { break }
                if line.hasPrefix("{") {
                    return Data(line.utf8)
                }
                if let colon = line.firstIndex(of: ":") {
                    let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    headers[key] = value
                }
            }
        }
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        guard length > 0 else { return nil }
        return stdin.readData(ofLength: length)
    }

    private static func write(response: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: response, options: [])
        let header = "Content-Length: \(data.count)\r\n\r\n"
        FileHandle.standardOutput.write(Data(header.utf8))
        FileHandle.standardOutput.write(data)
    }
}
