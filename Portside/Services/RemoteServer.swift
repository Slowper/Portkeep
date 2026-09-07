import Foundation
import Network

/// LAN HTTP + Bonjour. Only started when the user turns sharing on.
final class RemoteServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.sajidpalagiri.portkeep.remote.server")
    private var listener: NWListener?
    private let token: String

    init(pin: String) {
        self.token = RemoteLink.token(for: pin)
    }

    func start() throws {
        stop()
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: RemoteLink.port)!)
        var txt = NWTXTRecord()
        txt["host"] = ProcessInfo.processInfo.hostName
        txt["id"] = DeviceIdentity.uuid
        listener.service = NWListener.Service(
            name: RemoteLink.displayName,
            type: RemoteLink.serviceType,
            txtRecord: txt
        )
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            if let request = HTTPRequest.parse(next) {
                Task { await self.respond(to: request, on: connection) }
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: next)
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) async {
        let headerToken = request.headers[RemoteLink.tokenHeader.lowercased()]
            ?? request.headers["authorization"]?.replacingOccurrences(of: "Bearer ", with: "")
        guard headerToken == token else {
            reply(connection, status: 401, json: ["error": "Wrong PIN. Use the same code on both Macs."])
            return
        }
        switch (request.method, request.path) {
            case ("GET", "/v1/hello"), ("GET", "/v1/snapshot"):
                let snap = await RemoteSnapshotDTO.current()
                reply(connection, status: 200, json: snap.dictionary)
            case ("POST", "/v1/stop"):
                let body = request.bodyObject
                let port = (body["port"] as? Int) ?? (body["port"] as? NSNumber)?.intValue
                guard let port else {
                    reply(connection, status: 400, json: ["error": "Missing port."])
                    return
                }
                let confirmLAN = body["confirm_lan"] as? Bool ?? false
                let result = await RemoteActions.stop(port: port, confirmLAN: confirmLAN)
                reply(connection, status: result.status, json: result.json)
            default:
                reply(connection, status: 404, json: ["error": "Unknown path."])
            }
    }

    private func reply(_ connection: NWConnection, status: Int, json: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
        let reason = status == 200 ? "OK" : "Error"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(data)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

enum RemoteActions {
    struct Result {
        var status: Int
        var json: [String: Any]
    }

    static func stop(port: Int, confirmLAN: Bool) async -> Result {
        await Audit.$source.withValue(.remote) {
            do {
                let snapshot = try await RuntimeSnapshot.capture()
                guard let record = snapshot.record(forPort: port) else {
                    return Result(status: 404, json: ["error": "Nothing on :\(port)."])
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
                    return Result(status: 403, json: ["error": reason])
                case .confirm(let reason):
                    if !confirmLAN {
                        return Result(status: 409, json: ["error": reason, "needs_lan": true])
                    }
                case .allow:
                    break
                }
                let pids = ProcessKiller.pids(lineage: record.lineage, fallback: record.port.pid)
                let outcome = ProcessKiller.stop(pids: pids, force: false)
                await ProcessKiller.escalate(pids)
                Audit.record(
                    action: "stop",
                    ok: outcome.succeeded,
                    port: port,
                    command: record.lineage?.rootCommand ?? record.port.command,
                    pids: pids,
                    project: record.project?.name,
                    path: record.project?.directory.path,
                    detail: "remote"
                )
                return Result(status: 200, json: ["ok": outcome.succeeded, "port": port])
            } catch {
                return Result(status: 500, json: ["error": error.localizedDescription])
            }
        }
    }
}

private struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    var bodyObject: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    static func parse(_ data: Data) -> HTTPRequest? {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data.subdata(in: data.startIndex..<range.lowerBound), as: UTF8.self)
        let lines = head.split(whereSeparator: \.isNewline).map(String.init)
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        let bodyStart = range.upperBound
        let available = data.count - bodyStart
        guard available >= length else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + length))
        let path = String(parts[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? String(parts[1])
        return HTTPRequest(method: String(parts[0]), path: path, headers: headers, body: body)
    }
}

private extension RemoteSnapshotDTO {
    var dictionary: [String: Any] {
        let data = try! JSONEncoder().encode(self)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
