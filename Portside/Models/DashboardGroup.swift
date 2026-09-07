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
    var projects: [DashboardGroup] = []
    var containers: [DashboardGroup] = []
    var other: [DashboardGroup] = []
    var stopped: [DockerContainer] = []

    var isEmpty: Bool { projects.isEmpty && containers.isEmpty && other.isEmpty && stopped.isEmpty }
    var all: [DashboardGroup] { projects + containers + other }

    /// Builds the sections from raw scan data.
    static func build(
        ports: [ListeningPort],
        containers: [DockerContainer],
        meta: [Int32: ProcessMeta],
        projects: [Int32: ProjectInfo]
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

        for port in ports {
            if port.isDockerProxy {
                // Proxy ports for containers we already listed are covered above.
                if dockerPortNumbers.contains(port.port) { continue }
            }
            if let project = projects[port.pid],
               ProcessInspector.belongs(command: port.command, meta: meta[port.pid], to: project) {
                let key = project.directory.path
                if projectGroups[key] == nil {
                    projectGroups[key] = DashboardGroup(id: "project:\(key)", kind: .project(project), ports: [])
                    projectOrder.append(key)
                }
                projectGroups[key]?.ports.append(port)
            } else {
                if processGroups[port.pid] == nil {
                    processGroups[port.pid] = DashboardGroup(id: "process:\(port.pid)", kind: .process(command: port.command, pid: port.pid), ports: [])
                    processOrder.append(port.pid)
                }
                processGroups[port.pid]?.ports.append(port)
            }
        }

        sections.projects = projectOrder.compactMap { projectGroups[$0] }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        sections.other = processOrder.compactMap { processGroups[$0] }
            .sorted { ($0.ports.first?.port ?? 0) < ($1.ports.first?.port ?? 0) }

        return sections
    }
}
