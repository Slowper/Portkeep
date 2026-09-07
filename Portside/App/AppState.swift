import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    // Data
    private(set) var ports: [ListeningPort] = []
    private(set) var projects: [Int32: ProjectInfo] = [:]
    private(set) var containers: [DockerContainer] = []
    private(set) var dockerAvailability: DockerAvailability = .unknown
    private(set) var lastRefreshed: Date?
    private(set) var isRefreshing = false

    // UI
    var errorMessage: String?
    var showPaywall = false
    var pendingDockerActions: Set<String> = []

    let settings = AppSettings()
    let license = LicenseManager()

    @ObservationIgnored private var refreshLoop: Task<Void, Never>?
    @ObservationIgnored private var isPanelVisible = false
    @ObservationIgnored private var projectCache: [String: ProjectInfo?] = [:]

    init() {
        restartRefreshLoop()
        Task { await refresh() }
    }

    // MARK: - Derived

    var visiblePorts: [ListeningPort] {
        guard settings.hideSystemProcesses else { return ports }
        return ports.filter { !AppSettings.isSystemProcess($0.command) }
    }

    func container(publishing port: Int) -> DockerContainer? {
        containers.first { $0.isRunning && $0.publishedPorts.contains(port) }
    }

    // MARK: - Lifecycle

    func panelDidAppear() {
        isPanelVisible = true
        restartRefreshLoop()
        Task { await refresh() }
    }

    func panelDidDisappear() {
        isPanelVisible = false
        restartRefreshLoop()
    }

    func settingsDidChange() {
        restartRefreshLoop()
    }

    private func restartRefreshLoop() {
        refreshLoop?.cancel()
        let interval: Double = isPanelVisible ? max(settings.refreshInterval, 1) : 30
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let wantDocker = settings.showDocker

        async let portsResult: Result<[ListeningPort], Error> = {
            do { return .success(try await PortScanner.scan()) } catch { return .failure(error) }
        }()
        async let dockerSnapshot: DockerService.Snapshot? = wantDocker ? DockerService.snapshot() : nil

        switch await portsResult {
        case .success(let scanned):
            ports = scanned
            errorMessage = nil
            await resolveProjects(for: scanned)
        case .failure(let error):
            errorMessage = error.localizedDescription
        }

        if let snapshot = await dockerSnapshot {
            containers = snapshot.containers
            dockerAvailability = snapshot.availability
        } else {
            containers = []
            dockerAvailability = .unknown
        }

        lastRefreshed = Date()
    }

    private func resolveProjects(for ports: [ListeningPort]) async {
        let pids = Array(Set(ports.filter { !$0.isDockerProxy && !AppSettings.isSystemProcess($0.command) }.map(\.pid)))
        let cwds = await ProcessInspector.workingDirectories(for: pids)

        var resolved: [Int32: ProjectInfo] = [:]
        for (pid, cwd) in cwds {
            if let cached = projectCache[cwd] {
                if let info = cached { resolved[pid] = info }
                continue
            }
            let info = ProcessInspector.project(at: cwd)
            projectCache[cwd] = info
            if let info { resolved[pid] = info }
        }
        projects = resolved
    }

    // MARK: - Actions

    /// Runs `action` if Pro is active, otherwise routes to the paywall.
    func requirePro(_ action: () -> Void) {
        if license.isPro {
            action()
        } else {
            showPaywall = true
        }
    }

    func open(_ port: ListeningPort) {
        guard let url = port.url else { return }
        NSWorkspace.shared.open(url)
    }

    func copyURL(of port: ListeningPort) {
        guard let url = port.url else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
    }

    func revealProject(for port: ListeningPort) {
        guard let project = projects[port.pid] else { return }
        NSWorkspace.shared.activateFileViewerSelecting([project.directory])
    }

    func terminate(_ port: ListeningPort, force: Bool = false) {
        requirePro {
            let signal = force ? SIGKILL : SIGTERM
            if kill(port.pid, signal) != 0 {
                errorMessage = "Couldn't stop \(port.command) (pid \(port.pid)): \(String(cString: strerror(errno)))"
            }
            scheduleRefresh(after: 0.6)
        }
    }

    func perform(_ action: DockerAction, on container: DockerContainer) {
        requirePro {
            pendingDockerActions.insert(container.id)
            Task {
                defer { pendingDockerActions.remove(container.id) }
                do {
                    try await DockerService.perform(action, on: container)
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
                await refresh()
            }
        }
    }

    private func scheduleRefresh(after seconds: Double) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            await refresh()
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}
