import Darwin
import Foundation

enum AuditSource: String, Sendable {
    case app, cli, mcp, remote
}

struct AuditEvent: Sendable, Identifiable {
    var id: String { "\(timestamp)-\(action)-\(port.map(String.init) ?? "")-\(command ?? "")" }
    var timestamp: Date
    var host: String
    var user: String
    var source: AuditSource
    var action: String
    var ok: Bool
    var port: Int?
    var command: String?
    var pids: [Int32]
    var project: String?
    var path: String?
    var detail: String?

    var dictionary: [String: Any] {
        var dict: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: timestamp),
            "host": host,
            "user": user,
            "source": source.rawValue,
            "action": action,
            "ok": ok,
        ]
        if let port { dict["port"] = port }
        if let command { dict["command"] = command }
        if !pids.isEmpty { dict["pids"] = pids.map(Int.init) }
        if let project { dict["project"] = project }
        if let path { dict["path"] = path }
        if let detail { dict["detail"] = detail }
        return dict
    }

    static func parse(_ dict: [String: Any]) -> AuditEvent? {
        guard let action = dict["action"] as? String else { return nil }
        let ts: Date
        if let raw = dict["ts"] as? String, let parsed = ISO8601DateFormatter().date(from: raw) {
            ts = parsed
        } else {
            ts = Date()
        }
        let pids = (dict["pids"] as? [Int])?.map(Int32.init) ?? []
        return AuditEvent(
            timestamp: ts,
            host: dict["host"] as? String ?? "",
            user: dict["user"] as? String ?? "",
            source: AuditSource(rawValue: dict["source"] as? String ?? "") ?? .app,
            action: action,
            ok: dict["ok"] as? Bool ?? true,
            port: dict["port"] as? Int,
            command: dict["command"] as? String,
            pids: pids,
            project: dict["project"] as? String,
            path: dict["path"] as? String,
            detail: dict["detail"] as? String
        )
    }

    var line: String {
        let projectBit = project.map { " \($0)" } ?? ""
        let portBit = port.map { " :\($0)" } ?? ""
        let detailBit = detail.map { " — \($0)" } ?? ""
        let mark = ok ? "" : " FAIL"
        return "\(Self.clock.string(from: timestamp))  \(action)\(portBit)\(projectBit)\(detailBit)\(mark)"
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

/// Append-only JSONL log at `~/.portkeep/audit.jsonl`. Local only.
enum Audit {
    @TaskLocal static var source: AuditSource = .app

    static let fileName = "audit.jsonl"
    static let maxBytes = 8 * 1024 * 1024
    static let keepLines = 4000

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(PortAllocator.directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static func record(
        action: String,
        ok: Bool = true,
        port: Int? = nil,
        command: String? = nil,
        pids: [Int32] = [],
        project: String? = nil,
        path: String? = nil,
        detail: String? = nil
    ) {
        let event = AuditEvent(
            timestamp: Date(),
            host: ProcessInfo.processInfo.hostName,
            user: NSUserName(),
            source: source,
            action: action,
            ok: ok,
            port: port,
            command: command,
            pids: pids,
            project: project,
            path: path,
            detail: detail
        )
        append(event)
    }

    static func recent(limit: Int = 50) -> [AuditEvent] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .compactMap { line -> AuditEvent? in
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let dict = object as? [String: Any]
                else { return nil }
                return AuditEvent.parse(dict)
            }
            .suffix(limit)
            .reversed()
    }

    static func export(to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        if fm.fileExists(atPath: url.path) {
            try fm.copyItem(at: url, to: destination)
        } else {
            try Data().write(to: destination)
        }
    }

    private static func append(_ event: AuditEvent) {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: event.dictionary, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        let path = url.path
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        _ = line.withCString { ptr in
            write(fd, ptr, strlen(ptr))
        }
        pruneIfNeeded(fd: fd)
        flock(fd, LOCK_UN)
    }

    private static func pruneIfNeeded(fd: Int32) {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > maxBytes else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let kept = lines.suffix(keepLines).joined(separator: "\n") + "\n"
        guard let rewritten = kept.data(using: .utf8) else { return }
        ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        rewritten.withUnsafeBytes { raw in
            if let base = raw.baseAddress { _ = write(fd, base, raw.count) }
        }
    }
}
