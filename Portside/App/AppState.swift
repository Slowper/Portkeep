import AppKit
import Foundation
import Observation

/// What a keyboard-selectable row in the panel refers to.
enum RowRef: Hashable, Sendable {
    case port(ListeningPort)
    case containerPort(DockerContainer, Int)
    case container(DockerContainer)
    case reserved(PortLease)

    var url: URL? {
        switch self {
        case .port(let port): port.url
        case .containerPort(_, let port): URL(string: "http://localhost:\(port)")
        case .container(let container): container.publishedPorts.first.flatMap { URL(string: "http://localhost:\($0)") }
        case .reserved(let lease): URL(string: "http://localhost:\(lease.port)")
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
    private(set) var leases: [PortLease] = []
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
    let remote = RemoteHub()

    /// Set by the status bar controller so views can ask to close the panel.
    @ObservationIgnored var dismissPanel: (() -> Void)?
    @ObservationIgnored var openSettingsWindow: (() -> Void)?

    @ObservationIgnored private let prober = HealthProber()
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?
    @ObservationIgnored private var isPanelVisible = false
    @ObservationIgnored private var projectCache: [String: ProjectInfo?] = [:]
    @ObservationIgnored private var processTree = ProcessTree(entries: [])
    @ObservationIgnored private var stopConfirmTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    struct Toast: Equatable {
        let text: String
        let symbol: String
    }

    init() {
        showWelcome = !settings.hasSeenWelcome
        restartRefreshLoop()
        remote.setSharing(settings.remoteSharingEnabled)
        Task { await refresh() }
    }

    // MARK: - Derived

    var visiblePorts: [ListeningPort] {
        guard settings.hideSystemProcesses else { return ports }
        return ports.filter { !AppSettings.isSystemProcess($0.command) }
    }

    /// Count shown in the menu bar: things a developer started.
    var menuBarCount: Int {
        sections.leftBehind.reduce(0) { $0 + $1.ports.count }
            + sections.projects.reduce(0) { $0 + $1.ports.count }
            + sections.other.reduce(0) { $0 + $1.ports.count }
            + sections.containers.count
    }

    func health(for port: Int) -> ProbeResult? { health[port] }

    // MARK: - Lifecycle

    func panelDidAppear() {
        isPanelVisible = true
        restartRefreshLoop()
        Task { await refresh() }
        if settings.remoteSharingEnabled {
            Task { await remote.refreshPeers() }
        }
    }

    func panelDidDisappear() {
        isPanelVisible = false
        pendingStopID = nil
        showPaywall = false
        restartRefreshLoop()
    }

    func settingsDidChange() {
        restartRefreshLoop()
        remote.setSharing(settings.remoteSharingEnabled)
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

        leases = (try? PortAllocator.allLeases()) ?? []
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
        let snapshot = await ProcessInspector.metadata(for: pids)
        var fetched = snapshot.meta

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

        for pid in pids {
            fetched[pid, default: ProcessMeta()].lineage = snapshot.tree.lineage(for: pid, cwd: fetched[pid]?.cwd, project: resolved[pid])
        }
        meta = fetched
        projects = resolved
        processTree = snapshot.tree
    }

    private func rebuildSections() {
        sections = DashboardSections.build(
            ports: visiblePorts,
            containers: settings.showDocker ? containers : [],
            meta: meta,
            projects: projects,
            leases: leases
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
        case .reserved(let lease):
            release(lease)
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

    func verdict(for port: ListeningPort) -> PolicyVerdict {
        let info = meta[port.pid]
        return Policy.evaluate(
            command: port.command,
            executable: info?.executable,
            cwd: info?.cwd,
            addresses: port.addresses,
            origin: info?.lineage?.origin,
            extraCommands: [info?.lineage?.rootCommand].compactMap { $0 }
        )
    }

    func verdict(for container: DockerContainer) -> PolicyVerdict {
        Policy.evaluateDocker(name: container.name, ports: container.ports)
    }

    func requestRemoteStop(peer: RemotePeer, listener: RemoteListenerDTO) {
        let id = "remote:\(peer.deviceID):\(listener.port)"
        requirePro {
            if pendingStopID == id {
                pendingStopID = nil
                Task {
                    do {
                        try await remote.stop(peer: peer, port: listener.port, confirmLAN: listener.lan)
                        showToast("Stopped :\(listener.port) on \(peer.name)", symbol: "stop.circle.fill")
                    } catch {
                        showToast(error.localizedDescription, symbol: "lock.fill")
                    }
                }
            } else {
                arm(id)
                if listener.lan {
                    showToast("LAN bind on \(peer.name) — click again to stop", symbol: "exclamationmark.triangle.fill")
                }
            }
        }
    }

    /// Two-step stop: first call arms, second call within 3s fires.
    /// Context-menu items pass `immediate` since choosing them is deliberate.
    /// Policy can still deny, or force a confirm for LAN / protected break-glass.
    func requestStop(_ port: ListeningPort, rowID: String? = nil, force: Bool = false, immediate: Bool = false) {
        let id = rowID ?? port.id
        requirePro {
            switch verdict(for: port) {
            case .deny(let reason):
                pendingStopID = nil
                Audit.record(action: "policy_deny", ok: false, port: port.port, command: port.command, detail: reason)
                showToast(reason, symbol: "lock.fill")
            case .confirm(let reason):
                if pendingStopID == id {
                    pendingStopID = nil
                    terminate(port, force: force)
                } else {
                    arm(id)
                    showToast(reason, symbol: "exclamationmark.triangle.fill")
                }
            case .allow:
                if pendingStopID == id || immediate || force {
                    pendingStopID = nil
                    terminate(port, force: force)
                } else {
                    arm(id)
                }
            }
        }
    }

    func requestContainerStop(_ container: DockerContainer, rowID: String) {
        if !container.isRunning {
            perform(.start, on: container)
            return
        }
        requirePro {
            switch verdict(for: container) {
            case .deny(let reason):
                pendingStopID = nil
                Audit.record(action: "policy_deny", ok: false, command: container.name, detail: reason)
                showToast(reason, symbol: "lock.fill")
            case .confirm(let reason):
                if pendingStopID == rowID {
                    pendingStopID = nil
                    perform(.stop, on: container)
                } else {
                    arm(rowID)
                    showToast(reason, symbol: "exclamationmark.triangle.fill")
                }
            case .allow:
                if pendingStopID == rowID {
                    pendingStopID = nil
                    perform(.stop, on: container)
                } else {
                    arm(rowID)
                }
            }
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

    /// Stops the whole tree the listener belongs to (`npm run dev` → `node` →
    /// `next-server`), not just the pid on the port. Killing only the leaf
    /// leaves wrappers and siblings holding memory and, often, other ports.
    private func terminate(_ port: ListeningPort, force: Bool) {
        let lineage = meta[port.pid]?.lineage
        var pids = lineage?.treePIDs ?? []
        if !pids.contains(port.pid) { pids.append(port.pid) }
        let label = lineage?.rootCommand ?? port.command
        let outcome = ProcessKiller.stop(pids: pids, force: force)
        finishStop(outcome: outcome, pids: pids, label: label, port: port.port, force: force)
    }

    func release(_ lease: PortLease) {
        do {
            _ = try PortAllocator.release(name: nil, port: lease.port, at: nil)
            leases.removeAll { $0.id == lease.id }
            rebuildSections()
            showToast("Released :\(lease.port) (\(lease.name))", symbol: "bookmark.slash")
        } catch {
            showToast("Couldn't release :\(lease.port)", symbol: "exclamationmark.triangle.fill")
        }
    }

    /// Stops only the process on the port, leaving its parents and siblings alone.
    func stopOnly(_ port: ListeningPort, force: Bool = false) {
        requirePro {
            switch verdict(for: port) {
            case .deny(let reason):
                Audit.record(action: "policy_deny", ok: false, port: port.port, command: port.command, detail: reason)
                showToast(reason, symbol: "lock.fill")
            case .confirm(let reason):
                if pendingStopID == port.id {
                    pendingStopID = nil
                    stop(pids: [port.pid], label: port.command, port: port.port, force: force)
                } else {
                    arm(port.id)
                    showToast(reason, symbol: "exclamationmark.triangle.fill")
                }
            case .allow:
                stop(pids: [port.pid], label: port.command, port: port.port, force: force)
            }
        }
    }

    /// Stops every left-behind tree. Two-step like a single stop.
    static let leftBehindStopID = "leftBehind:all"

    func requestStopAllLeftBehind() {
        if pendingStopID == Self.leftBehindStopID {
            pendingStopID = nil
            requirePro {
                var pids = Set<Int32>()
                var skipped = 0
                for group in sections.leftBehind {
                    let blocked = group.ports.contains { verdict(for: $0).isDenied }
                    if blocked {
                        skipped += 1
                        if let port = group.ports.first {
                            Audit.record(action: "policy_deny", ok: false, port: port.port, command: port.command, detail: "left-behind stop")
                        }
                        continue
                    }
                    if let lineage = group.lineage { pids.formUnion(lineage.treePIDs) }
                    pids.formUnion(group.ports.map(\.pid))
                }
                pids.remove(0)
                let count = sections.leftBehind.count - skipped
                if count == 0 {
                    showToast("Policy blocked every left-behind stop", symbol: "lock.fill")
                    return
                }
                stop(pids: Array(pids), label: "\(count) left-behind server\(count == 1 ? "" : "s")", port: nil, force: false)
            }
        } else {
            requirePro { arm(Self.leftBehindStopID) }
        }
    }

    private func stop(pids: [Int32], label: String, port: Int?, force: Bool) {
        let outcome = ProcessKiller.stop(pids: pids, force: force)
        finishStop(outcome: outcome, pids: pids, label: label, port: port, force: force)
    }

    private func finishStop(outcome: ProcessKiller.Outcome, pids: [Int32], label: String, port: Int?, force: Bool) {
        guard !pids.isEmpty else { return }
        let where_ = port.map { " on :\($0)" } ?? ""
        let ok = !(outcome.failed.count == pids.count && outcome.signalled.isEmpty)
        Audit.record(
            action: "stop",
            ok: ok,
            port: port,
            command: label,
            pids: pids,
            detail: force ? "SIGKILL" : "SIGTERM"
        )
        if !ok {
            errorMessage = "Couldn't stop \(label)"
            showToast("Couldn't stop \(label)", symbol: "exclamationmark.triangle.fill")
        } else {
            let detail = pids.count > 1 ? " · \(pids.count) processes" : ""
            showToast("Stopped \(label)\(where_)\(detail)", symbol: "stop.circle.fill")
        }

        if !force {
            Task {
                await ProcessKiller.escalate(pids)
                await refresh()
            }
        }
        scheduleRefresh(after: 0.6)
    }

    func perform(_ action: DockerAction, on container: DockerContainer) {
        if action == .stop || action == .restart {
            switch verdict(for: container) {
            case .deny(let reason):
                Audit.record(action: "policy_deny", ok: false, command: container.name, detail: reason)
                showToast(reason, symbol: "lock.fill")
                return
            case .confirm(let reason):
                if pendingStopID != container.id {
                    arm(container.id)
                    showToast(reason, symbol: "exclamationmark.triangle.fill")
                    return
                }
                pendingStopID = nil
            case .allow:
                break
            }
        }
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
                    Audit.record(action: "docker_\(action.rawValue)", command: container.name, detail: container.image)
                    showToast("\(verb) \(container.name)", symbol: "shippingbox.fill")
                } catch {
                    errorMessage = error.localizedDescription
                    Audit.record(action: "docker_\(action.rawValue)", ok: false, command: container.name, detail: error.localizedDescription)
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
