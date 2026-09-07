import AppKit
import Foundation
import Observation

/// What a keyboard-selectable row in the panel refers to.
enum RowRef: Hashable, Sendable {
    case port(ListeningPort)
    case containerPort(DockerContainer, Int)
    case container(DockerContainer)

    var url: URL? {
        switch self {
        case .port(let port): port.url
        case .containerPort(_, let port): URL(string: "http://localhost:\(port)")
        case .container(let container): container.publishedPorts.first.flatMap { URL(string: "http://localhost:\($0)") }
        }
    }
}

@MainActor
@Observable
final class AppState {
    // Scan results
    private(set) var ports: [ListeningPort] = []
    private(set) var meta: [Int32: ProcessMeta] = [:]
    private(set) var projects: [Int32: ProjectInfo] = [:]
    private(set) var containers: [DockerContainer] = []
    private(set) var dockerAvailability: DockerAvailability = .unknown
    private(set) var health: [Int: ProbeResult] = [:]
    private(set) var lastRefreshed: Date?
    private(set) var isRefreshing = false
    private(set) var hasLoadedOnce = false

    // Derived
    private(set) var sections = DashboardSections()

    // UI state
    var query = ""
    var errorMessage: String?
    var showPaywall = false
    var isPinned = false
    var selectedRowID: String?
    var pendingStopID: String?
    var toast: Toast?
    var pendingDockerActions: Set<String> = []
    var showWelcome = false

    /// Rows currently rendered, in visual order. The view keeps this in sync.
    private(set) var rows: [(id: String, ref: RowRef)] = []

    let settings = AppSettings()
    let license = LicenseManager()

    /// Set by the status bar controller so views can ask to close the panel.
    @ObservationIgnored var dismissPanel: (() -> Void)?
    @ObservationIgnored var openSettingsWindow: (() -> Void)?

    @ObservationIgnored private let prober = HealthProber()
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?
    @ObservationIgnored private var isPanelVisible = false
    @ObservationIgnored private var projectCache: [String: ProjectInfo?] = [:]
    @ObservationIgnored private var stopConfirmTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    struct Toast: Equatable {
        let text: String
        let symbol: String
    }

    init() {
        showWelcome = !settings.hasSeenWelcome
        restartRefreshLoop()
        Task { await refresh() }
    }

    // MARK: - Derived

    var visiblePorts: [ListeningPort] {
        guard settings.hideSystemProcesses else { return ports }
        return ports.filter { !AppSettings.isSystemProcess($0.command) }
    }

    /// Count shown in the menu bar: things a developer started.
    var menuBarCount: Int {
        sections.projects.reduce(0) { $0 + $1.ports.count }
            + sections.other.reduce(0) { $0 + $1.ports.count }
            + sections.containers.count
    }

    func health(for port: Int) -> ProbeResult? { health[port] }

    // MARK: - Lifecycle

    func panelDidAppear() {
        isPanelVisible = true
        restartRefreshLoop()
        Task { await refresh() }
    }

    func panelDidDisappear() {
        isPanelVisible = false
        pendingStopID = nil
        showPaywall = false
        restartRefreshLoop()
    }

    func settingsDidChange() {
        restartRefreshLoop()
        Task { await refresh() }
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
        defer { isRefreshing = false; hasLoadedOnce = true }

        let wantDocker = settings.showDocker

        async let portsResult: Result<[ListeningPort], Error> = {
            do { return .success(try await PortScanner.scan()) } catch { return .failure(error) }
        }()
        async let dockerSnapshot: DockerService.Snapshot? = wantDocker ? DockerService.snapshot() : nil

        switch await portsResult {
        case .success(let scanned):
            ports = scanned
            errorMessage = nil
            await resolveMetadata(for: scanned)
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

        rebuildSections()

        if settings.probeHealth {
            let candidates = sections.all.flatMap { $0.ports.map(\.port) }
            health = await prober.results(for: candidates)
        } else {
            health = [:]
        }

        lastRefreshed = Date()
    }

    private func resolveMetadata(for ports: [ListeningPort]) async {
        let pids = Array(Set(ports.filter { !$0.isDockerProxy && !AppSettings.isSystemProcess($0.command) }.map(\.pid)))
        let fetched = await ProcessInspector.metadata(for: pids)
        meta = fetched

        var resolved: [Int32: ProjectInfo] = [:]
        for (pid, info) in fetched {
            guard let cwd = info.cwd else { continue }
            if let cached = projectCache[cwd] {
                if let project = cached { resolved[pid] = project }
                continue
            }
            let project = ProcessInspector.project(at: cwd)
            projectCache[cwd] = project
            if let project { resolved[pid] = project }
        }
        projects = resolved
    }

    private func rebuildSections() {
        sections = DashboardSections.build(
            ports: visiblePorts,
            containers: settings.showDocker ? containers : [],
            meta: meta,
            projects: projects
        )
    }

    // MARK: - Rows & keyboard selection

    func updateRows(_ newRows: [(id: String, ref: RowRef)]) {
        rows = newRows
        if let selected = selectedRowID, !newRows.contains(where: { $0.id == selected }) {
            selectedRowID = nil
        }
    }

    var selectedRow: RowRef? {
        rows.first { $0.id == selectedRowID }?.ref
    }

    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        guard let current = selectedRowID, let index = rows.firstIndex(where: { $0.id == current }) else {
            selectedRowID = delta >= 0 ? rows.first?.id : rows.last?.id
            return
        }
        let next = (index + delta + rows.count) % rows.count
        selectedRowID = rows[next].id
    }

    func activateSelection() {
        guard let ref = selectedRow else { return }
        open(ref)
    }

    func copySelection() {
        guard let ref = selectedRow else { return }
        copyURL(of: ref)
    }

    func stopSelection() {
        guard let id = selectedRowID, let ref = selectedRow else { return }
        switch ref {
        case .port(let port): requestStop(port, rowID: id)
        case .container(let container), .containerPort(let container, _):
            requestContainerStop(container, rowID: id)
        }
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

    func open(_ ref: RowRef) {
        guard let url = ref.url else { return }
        NSWorkspace.shared.open(url)
        if !isPinned { dismissPanel?() }
    }

    func open(_ port: ListeningPort) { open(.port(port)) }

    func copyURL(of ref: RowRef) {
        guard let url = ref.url else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
        showToast("Copied \(url.absoluteString)", symbol: "doc.on.clipboard.fill")
    }

    func copyURL(of port: ListeningPort) { copyURL(of: .port(port)) }

    func copyText(_ text: String, label: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showToast("Copied \(label)", symbol: "doc.on.clipboard.fill")
    }

    func reveal(_ project: ProjectInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([project.directory])
    }

    func openInEditor(_ project: ProjectInfo) {
        guard let editor = EditorLauncher.resolve(preferred: settings.preferredEditor, among: EditorLauncher.knownEditors) else {
            showToast("No editor found", symbol: "exclamationmark.triangle.fill")
            return
        }
        EditorLauncher.open(project.directory, with: editor)
        if !isPinned { dismissPanel?() }
    }

    func openInTerminal(_ project: ProjectInfo) {
        guard let terminal = EditorLauncher.resolve(preferred: settings.preferredTerminal, among: EditorLauncher.knownTerminals) else { return }
        EditorLauncher.open(project.directory, with: terminal)
        if !isPinned { dismissPanel?() }
    }

    /// Two-step stop: first call arms, second call within 3s fires.
    func requestStop(_ port: ListeningPort, rowID: String? = nil, force: Bool = false) {
        let id = rowID ?? port.id
        if pendingStopID == id || force {
            pendingStopID = nil
            terminate(port, force: force)
        } else {
            requirePro { arm(id) }
        }
    }

    func requestContainerStop(_ container: DockerContainer, rowID: String) {
        if pendingStopID == rowID {
            pendingStopID = nil
            perform(container.isRunning ? .stop : .start, on: container)
        } else if container.isRunning {
            requirePro { arm(rowID) }
        } else {
            perform(.start, on: container)
        }
    }

    private func arm(_ id: String) {
        pendingStopID = id
        stopConfirmTask?.cancel()
        stopConfirmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            if self?.pendingStopID == id { self?.pendingStopID = nil }
        }
    }

    func cancelPendingStop() {
        pendingStopID = nil
        stopConfirmTask?.cancel()
    }

    private func terminate(_ port: ListeningPort, force: Bool) {
        requirePro {
            let signal = force ? SIGKILL : SIGTERM
            if kill(port.pid, signal) == 0 {
                showToast("Stopped \(port.command) on :\(port.port)", symbol: "stop.circle.fill")
            } else {
                errorMessage = "Couldn't stop \(port.command) (pid \(port.pid)): \(String(cString: strerror(errno)))"
                showToast("Couldn't stop \(port.command)", symbol: "exclamationmark.triangle.fill")
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
                    let verb = switch action {
                    case .start: "Started"
                    case .stop: "Stopped"
                    case .restart: "Restarted"
                    }
                    showToast("\(verb) \(container.name)", symbol: "shippingbox.fill")
                } catch {
                    errorMessage = error.localizedDescription
                    showToast("Docker: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
                }
                await refresh()
            }
        }
    }

    func showToast(_ text: String, symbol: String) {
        toast = Toast(text: text, symbol: symbol)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func dismissWelcome() {
        showWelcome = false
        settings.hasSeenWelcome = true
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
