import Foundation

/// A card in the panel: a project, a Docker container, or a lone process,
/// together with the ports it owns.
struct DashboardGroup: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case project(ProjectInfo)
        case container(DockerContainer)
        case process(command: String, pid: Int32)
    }

    let id: String
    let kind: Kind
    var ports: [ListeningPort]
    /// Lineage of the group's primary process (who started it, its tree).
    var lineage: ProcessLineage?
    /// Reserved ports for this project that nothing is listening on yet.
    var reserved: [PortLease] = []

    init(id: String, kind: Kind, ports: [ListeningPort], lineage: ProcessLineage? = nil, reserved: [PortLease] = []) {
        self.id = id
        self.kind = kind
        self.ports = ports
        self.lineage = lineage
        self.reserved = reserved
    }

    var origin: ProcessOrigin? { lineage?.origin }
    var isLeftBehind: Bool { lineage?.isLeftBehind ?? false }

    var title: String {
        switch kind {
        case .project(let project): project.name
        case .container(let container): container.name
        case .process(let command, _): command
        }
    }

    var subtitle: String {
        switch kind {
        case .project(let project): project.abbreviatedPath
        case .container(let container): container.image
        case .process(_, let pid): "pid \(pid)"
        }
    }

    var project: ProjectInfo? {
        if case .project(let p) = kind { return p }
        return nil
    }

    var container: DockerContainer? {
        if case .container(let c) = kind { return c }
        return nil
    }

    var primaryPID: Int32? {
        switch kind {
        case .process(_, let pid): pid
        default: ports.first?.pid
        }
    }
}

struct DashboardSections: Sendable {
    /// Dev servers whose parent has exited or whose folder was deleted.
    var leftBehind: [DashboardGroup] = []
    var projects: [DashboardGroup] = []
    var containers: [DashboardGroup] = []
    var other: [DashboardGroup] = []
    var stopped: [DockerContainer] = []
    /// Leases whose project isn't currently in the list.
    var reserved: [PortLease] = []

    var isEmpty: Bool { leftBehind.isEmpty && projects.isEmpty && containers.isEmpty && other.isEmpty && stopped.isEmpty && reserved.isEmpty }
    var all: [DashboardGroup] { leftBehind + projects + containers + other }

    /// Total memory held by everything in the left-behind section.
    var leftBehindMemory: UInt64 {
        var seen = Set<Int32>()
        var total: UInt64 = 0
        for group in leftBehind {
            guard let lineage = group.lineage, !seen.contains(lineage.treeRoot) else { continue }
            seen.insert(lineage.treeRoot)
            total += lineage.treeMemory
        }
        return total
    }

    /// Builds the sections from raw scan data.
    static func build(
        ports: [ListeningPort],
        containers: [DockerContainer],
        meta: [Int32: ProcessMeta],
        projects: [Int32: ProjectInfo],
        leases: [PortLease] = []
    ) -> DashboardSections {
        var sections = DashboardSections()

        // Docker: one card per running container, ports matched by published port.
        var dockerPortNumbers = Set<Int>()
        for container in containers where container.isRunning {
            let published = Set(container.publishedPorts)
            var owned = ports.filter { $0.isDockerProxy && published.contains($0.port) }
            // The VM proxy doesn't always show in lsof; synthesise rows from the mapping.
            for port in container.publishedPorts where !owned.contains(where: { $0.port == port }) {
                owned.append(ListeningPort(pid: 0, command: "docker", port: port, addresses: ["0.0.0.0"]))
            }
            owned.sort { $0.port < $1.port }
            dockerPortNumbers.formUnion(owned.map(\.port))
            sections.containers.append(DashboardGroup(id: "docker:\(container.id)", kind: .container(container), ports: owned))
        }
        sections.stopped = containers.filter { !$0.isRunning }

        // Projects: group by directory when the process plausibly belongs to it.
        var projectGroups: [String: DashboardGroup] = [:]
        var projectOrder: [String] = []
        var processGroups: [Int32: DashboardGroup] = [:]
        var processOrder: [Int32] = []

        let candidates = ports.filter { !($0.isDockerProxy && dockerPortNumbers.contains($0.port)) }

        func projectKey(_ project: ProjectInfo, _ lineage: ProcessLineage?) -> String {
            // One project can have a live server and a leftover one side by
            // side; keep them apart so the leftover lands in its own section.
            project.directory.path + (lineage?.isLeftBehind == true ? "#left" : "")
        }

        // Pass 1: ports that plausibly belong to the project they were started in.
        // Remember which process trees those are, so siblings can join below.
        var treeToProjectKey: [Int32: String] = [:]
        var deferred: [ListeningPort] = []
        for port in candidates {
            let lineage = meta[port.pid]?.lineage
            if let project = projects[port.pid],
               ProcessInspector.belongs(command: port.command, meta: meta[port.pid], to: project) {
                let key = projectKey(project, lineage)
                if projectGroups[key] == nil {
                    projectGroups[key] = DashboardGroup(id: "project:\(key)", kind: .project(project), ports: [], lineage: lineage)
                    projectOrder.append(key)
                }
                projectGroups[key]?.ports.append(port)
                if let root = lineage?.treeRoot { treeToProjectKey[root] = key }
            } else {
                deferred.append(port)
            }
        }

        // Pass 2: anything else. A `cloudflared` spawned by a project's dev
        // server shares its tree root, so it belongs on that project's card.
        // Otherwise processes in the same tree share one card, keyed by root.
        for port in deferred {
            let lineage = meta[port.pid]?.lineage
            if let root = lineage?.treeRoot, let key = treeToProjectKey[root] {
                projectGroups[key]?.ports.append(port)
                continue
            }
            let key = lineage?.treeRoot ?? port.pid
            if processGroups[key] == nil {
                processGroups[key] = DashboardGroup(id: "process:\(key)", kind: .process(command: port.command, pid: port.pid), ports: [], lineage: lineage)
                processOrder.append(key)
            }
            processGroups[key]?.ports.append(port)
        }
        for key in projectGroups.keys { projectGroups[key]?.ports.sort { $0.port < $1.port } }

        let projectList = projectOrder.compactMap { projectGroups[$0] }
        let processList = processOrder.compactMap { processGroups[$0] }

        sections.leftBehind = (projectList + processList).filter(\.isLeftBehind)
            .sorted { ($0.lineage?.treeMemory ?? 0) > ($1.lineage?.treeMemory ?? 0) }
        sections.projects = projectList.filter { !$0.isLeftBehind }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        sections.other = processList.filter { !$0.isLeftBehind }
            .sorted { ($0.ports.first?.port ?? 0) < ($1.ports.first?.port ?? 0) }

        let listening = Set(ports.map(\.port))
        var attached = Set<String>()
        func attach(_ groups: inout [DashboardGroup]) {
            for index in groups.indices {
                guard let path = groups[index].project?.directory.path else { continue }
                let unused = leases.filter { $0.directory == path && !listening.contains($0.port) }
                groups[index].reserved = unused.sorted { $0.port < $1.port }
                unused.forEach { attached.insert($0.id) }
            }
        }
        attach(&sections.projects)
        attach(&sections.leftBehind)
        sections.reserved = leases
            .filter { !attached.contains($0.id) && !listening.contains($0.port) }
            .sorted { $0.projectName.localizedCaseInsensitiveCompare($1.projectName) == .orderedAscending }

        return sections
    }
}
