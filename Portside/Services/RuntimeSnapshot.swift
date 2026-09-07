import Foundation

/// One listener plus everything we know about it. Shared by the panel, CLI and MCP.
struct ListenerRecord: Sendable {
    var port: ListeningPort
    var project: ProjectInfo?
    var meta: ProcessMeta?
    var lease: PortLease?

    var lineage: ProcessLineage? { meta?.lineage }
}

/// Point-in-time view of listening ports, lineage and reserved leases.
/// Used by the CLI and MCP so they don't go through AppKit/`AppState`.
struct RuntimeSnapshot: Sendable {
    var ports: [ListeningPort]
    var meta: [Int32: ProcessMeta]
    var projects: [Int32: ProjectInfo]
    var leases: [PortLease]
    var records: [ListenerRecord]

    static func capture(includeSystem: Bool = false) async throws -> RuntimeSnapshot {
        let scanned = try await PortScanner.scan()
        let visible = includeSystem ? scanned : scanned.filter { !AppSettings.isSystemProcess($0.command) }
        let pids = Array(Set(visible.filter { !$0.isDockerProxy }.map(\.pid)))
        let snapshot = await ProcessInspector.metadata(for: pids)

        var resolved: [Int32: ProjectInfo] = [:]
        var fetched = snapshot.meta
        for (pid, info) in fetched {
            guard let cwd = info.cwd else { continue }
            if let project = ProcessInspector.project(at: cwd) {
                resolved[pid] = project
            }
        }
        for pid in pids {
            fetched[pid, default: ProcessMeta()].lineage = snapshot.tree.lineage(
                for: pid,
                cwd: fetched[pid]?.cwd,
                project: resolved[pid]
            )
        }

        let leases = (try? PortAllocator.allLeases()) ?? []
        let byPort = Dictionary(uniqueKeysWithValues: leases.map { ($0.port, $0) })
        let records = visible.map { port in
            let project = resolved[port.pid].flatMap { candidate in
                ProcessInspector.belongs(command: port.command, meta: fetched[port.pid], to: candidate) ? candidate : nil
            }
            return ListenerRecord(
                port: port,
                project: project,
                meta: fetched[port.pid],
                lease: byPort[port.port]
            )
        }

        return RuntimeSnapshot(ports: visible, meta: fetched, projects: resolved, leases: leases, records: records)
    }

    func record(forPort port: Int) -> ListenerRecord? {
        records.first { $0.port.port == port }
    }

    var takenPorts: Set<Int> {
        Set(ports.map(\.port))
    }
}
