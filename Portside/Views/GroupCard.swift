import SwiftUI

/// A project, container, or lone process with its ports.
struct GroupCard: View {
    @Environment(AppState.self) private var state
    let group: DashboardGroup

    @State private var hovering = false

    static func rowID(_ group: DashboardGroup, _ port: ListeningPort) -> String {
        "\(group.id)|\(port.id)"
    }

    static func reservedID(_ lease: PortLease) -> String {
        "reserved:\(lease.id)"
    }

    private var isBusy: Bool {
        group.container.map { state.pendingDockerActions.contains($0.id) } ?? false
    }

    private var uptime: String? {
        guard let pid = group.primaryPID, pid != 0 else { return nil }
        return state.meta[pid]?.uptimeLabel
    }

    /// Memory of the whole process tree, shown once it's worth knowing about.
    private var memory: String? {
        guard let lineage = group.lineage, lineage.treeMemory >= 64 * 1024 * 1024 else { return nil }
        return lineage.treeMemoryLabel
    }

    private var memoryHelp: String {
        guard let lineage = group.lineage else { return "" }
        let count = lineage.treePIDs.count
        return "\(lineage.treeMemoryLabel) across \(count) process\(count == 1 ? "" : "es") in the \(lineage.rootCommand) tree"
    }

    @ViewBuilder
    private func originChip(_ lineage: ProcessLineage) -> some View {
        if lineage.directoryMissing {
            Chip(text: "folder gone", tint: .orange)
                .help("The directory this was started from no longer exists")
        } else if lineage.origin.isNotable {
            HStack(spacing: 3) {
                Image(systemName: lineage.origin.symbol)
                    .font(.system(size: 8.5, weight: .bold))
                Text(lineage.origin.label)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(lineage.origin.tint.opacity(0.14), in: Capsule())
            .foregroundStyle(lineage.origin.tint)
            .fixedSize()
            .help(originHelp(lineage))
        }
    }

    private func originHelp(_ lineage: ProcessLineage) -> String {
        switch lineage.origin {
        case .orphaned:
            return "Whatever started this has exited — it was reparented to launchd. Started as “\(lineage.rootCommand)”."
        case .cursorAgent:
            return "Started by a Cursor agent terminal (“\(lineage.rootCommand)”)"
        case .claudeCode, .codex, .geminiCLI, .aider, .openCode:
            return "Started by \(lineage.origin.label) (“\(lineage.rootCommand)”)"
        default:
            return "Started from \(lineage.origin.label) as “\(lineage.rootCommand)”"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !group.ports.isEmpty || !group.reserved.isEmpty {
                Divider()
                    .opacity(0.5)
                    .padding(.leading, 14)
                VStack(spacing: 1) {
                    ForEach(group.ports) { port in
                        PortLine(group: group, port: port)
                    }
                    ForEach(group.reserved) { lease in
                        ReservedLine(group: group, lease: lease)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.055 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .id(group.ports.isEmpty ? group.id : "\(group.id)#card")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            icon

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 6) {
                    Text(group.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let project = group.project {
                        // The folder tile already says "generic project"; the chip adds nothing.
                        if project.kind != .generic {
                            Chip(text: project.kind.label, tint: project.kind.badgeTint)
                        }
                    } else if let container = group.container {
                        Chip(text: container.isRunning ? "running" : container.state, tint: container.isRunning ? .green : .secondary)
                    }
                    if let lineage = group.lineage {
                        originChip(lineage)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            if isBusy {
                ProgressView().controlSize(.small)
            } else if hovering {
                headerActions
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if uptime != nil || memory != nil {
                HStack(spacing: 6) {
                    if let memory {
                        Text(memory)
                            .foregroundStyle(group.isLeftBehind ? Color.orange : Color.secondary.opacity(0.9))
                            .help(memoryHelp)
                    }
                    if let uptime {
                        Text("up \(uptime)")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .fixedSize()
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if let project = group.project { state.openInEditor(project) }
        }
        .contextMenu { headerMenu }
    }

    @ViewBuilder
    private var icon: some View {
        switch group.kind {
        case .project(let project):
            IconTile(symbol: project.kind.symbol, tint: project.kind.tint)
        case .container:
            IconTile(symbol: "shippingbox.fill", tint: Color(red: 0.11, green: 0.56, blue: 0.93))
        case .process:
            IconTile(symbol: "terminal.fill", tint: Color(red: 0.42, green: 0.45, blue: 0.52))
        }
    }

    private var subtitle: String {
        switch group.kind {
        case .project(let project):
            return project.abbreviatedPath
        case .container(let container):
            return "\(container.image) · \(container.status)"
        case .process(_, let pid):
            let meta = state.meta[pid]
            // Where it was started from says more than which interpreter runs it.
            if let cwd = meta?.cwd, cwd != "/", cwd != FileManager.default.homeDirectoryForCurrentUser.path {
                let path = (cwd as NSString).abbreviatingWithTildeInPath
                if let root = meta?.lineage?.rootCommand, root.lowercased() != group.title.lowercased() {
                    return "\(root) · \(path)"
                }
                return path
            }
            if let exe = meta?.executable, exe.contains("/") {
                return (exe as NSString).abbreviatingWithTildeInPath
            }
            return "pid \(pid)"
        }
    }

    @ViewBuilder
    private var headerActions: some View {
        HStack(spacing: 2) {
            switch group.kind {
            case .project(let project):
                RowButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Open in editor") { state.openInEditor(project) }
                RowButton(symbol: "terminal", help: "Open in terminal") { state.openInTerminal(project) }
                RowButton(symbol: "folder", help: "Reveal in Finder") { state.reveal(project) }
            case .container(let container):
                if container.isRunning {
                    if let first = container.publishedPorts.first {
                        RowButton(symbol: "safari", help: "Open localhost:\(first)") { state.open(.containerPort(container, first)) }
                    }
                    RowButton(symbol: "arrow.clockwise", help: "Restart") { state.perform(.restart, on: container) }
                    ArmedStopButton(isArmed: state.pendingStopID == group.id, idleSymbol: "stop.circle", idleHelp: "Stop container") {
                        state.requestContainerStop(container, rowID: group.id)
                    }
                } else {
                    RowButton(symbol: "play.circle", help: "Start container", tint: .green) { state.perform(.start, on: container) }
                }
            case .process(_, let pid):
                RowButton(symbol: "number", help: "Copy PID") { state.copyText("\(pid)", label: "pid \(pid)") }
            }
        }
    }

    @ViewBuilder
    private var headerMenu: some View {
        switch group.kind {
        case .project(let project):
            Button("Open in Editor") { state.openInEditor(project) }
            Button("Open in Terminal") { state.openInTerminal(project) }
            Button("Reveal in Finder") { state.reveal(project) }
            Divider()
            Button("Copy Path") { state.copyText(project.directory.path, label: "path") }
        case .container(let container):
            if container.isRunning {
                Button("Restart") { state.perform(.restart, on: container) }
                Button("Stop") { state.perform(.stop, on: container) }
            } else {
                Button("Start") { state.perform(.start, on: container) }
            }
            Divider()
            Button("Copy Container ID") { state.copyText(container.shortID, label: "container ID") }
            if !container.ports.isEmpty {
                Text(container.ports)
            }
        case .process(let command, let pid):
            Button("Copy PID") { state.copyText("\(pid)", label: "pid \(pid)") }
            if let exe = state.meta[pid]?.executable, !exe.isEmpty {
                Button("Copy Executable Path") { state.copyText(exe, label: "path") }
            }
            Divider()
            Text("\(command) · pid \(pid)")
        }
    }
}

// MARK: - Port line

struct PortLine: View {
    @Environment(AppState.self) private var state
    let group: DashboardGroup
    let port: ListeningPort

    @State private var hovering = false

    private var rowID: String { GroupCard.rowID(group, port) }
    private var isSelected: Bool { state.selectedRowID == rowID }
    private var isArmed: Bool { state.pendingStopID == rowID || state.pendingStopID == port.id }
    private var isSynthetic: Bool { port.pid == 0 }

    private var ref: RowRef {
        if let container = group.container { return .containerPort(container, port.port) }
        return .port(port)
    }

    private var detail: String? {
        switch group.kind {
        case .project: return "\(port.command) · \(port.pid)"
        case .process(let command, let pid):
            // A merged tree (bun + cloudflared) needs per-line identification.
            return (port.command != command || port.pid != pid) ? "\(port.command) · \(port.pid)" : nil
        case .container: return port.addresses.first.map { $0 == "*" ? "all interfaces" : $0 }
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(":\(String(port.port))")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
                .frame(minWidth: 52, alignment: .leading)
                .fixedSize()

            if state.settings.probeHealth {
                HealthPill(result: state.health(for: port.port))
            }

            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }

            Spacer(minLength: 4)

            if !port.isLocalOnly {
                Chip(text: "LAN", tint: .orange)
                    .help("Bound to all interfaces — reachable from other devices on your network")
            }

            if hovering || isSelected || isArmed {
                actions
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.13) : hovering ? Color.primary.opacity(0.05) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { state.open(ref) }
        .onTapGesture { state.selectedRowID = rowID }
        .contextMenu { menu }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.snappy(duration: 0.18), value: isSelected)
        .id(rowID)
    }

    private var actions: some View {
        HStack(spacing: 2) {
            RowButton(symbol: "safari", help: "Open in browser (⏎)") { state.open(ref) }
            RowButton(symbol: "doc.on.doc", help: "Copy URL (⌘C)") { state.copyURL(of: ref) }
            if !isSynthetic && group.container == nil {
                let verdict = state.verdict(for: port)
                if verdict.isDenied {
                    RowButton(symbol: "lock.fill", help: verdict.message ?? "Protected by policy") {
                        state.requestStop(port, rowID: rowID)
                    }
                } else {
                    ArmedStopButton(
                        isArmed: isArmed,
                        idleHelp: verdict.needsConfirm ? (verdict.message ?? "Confirm stop") : "Stop process (⌘⌫)",
                        armedLabel: verdict.needsConfirm ? "LAN?" : "Stop?"
                    ) {
                        state.requestStop(port, rowID: rowID)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Open http://localhost:\(String(port.port))") { state.open(ref) }
        Button("Copy URL") { state.copyURL(of: ref) }
        Button("Copy Port") { state.copyText(String(port.port), label: "port") }
        if !isSynthetic && group.container == nil {
            Divider()
            if let lineage = state.meta[port.pid]?.lineage, lineage.treePIDs.count > 1 {
                Button("Stop \(lineage.rootCommand) · \(lineage.treePIDs.count) processes") { state.requestStop(port, rowID: rowID, immediate: true) }
                Button("Stop only \(port.command) (pid \(port.pid))") { state.stopOnly(port) }
            } else {
                Button("Stop \(port.command) (SIGTERM)") { state.requestStop(port, rowID: rowID, immediate: true) }
            }
            Button("Force Kill (SIGKILL)") { state.stopOnly(port, force: true) }
        }
        Divider()
        Text("Bound to \(port.addresses.joined(separator: ", "))")
        if !isSynthetic {
            Text("pid \(port.pid) · \(port.command)")
            if let lineage = state.meta[port.pid]?.lineage, lineage.origin.isNotable {
                Text("Started by \(lineage.origin.label) · \(lineage.treeMemoryLabel)")
            }
        }
    }
}

/// A port reserved for this worktree that nothing is listening on yet.
struct ReservedLine: View {
    @Environment(AppState.self) private var state
    let group: DashboardGroup
    let lease: PortLease

    @State private var hovering = false

    private var rowID: String { GroupCard.reservedID(lease) }
    private var isSelected: Bool { state.selectedRowID == rowID }

    var body: some View {
        HStack(spacing: 8) {
            Text(":\(String(lease.port))")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .leading)
                .fixedSize()

            Chip(text: "reserved", tint: .secondary)
            Text(lease.name)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            if let worktree = lease.worktreeName {
                Text(worktree)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if hovering || isSelected {
                HStack(spacing: 2) {
                    RowButton(symbol: "doc.on.doc", help: "Copy URL") { state.copyURL(of: .reserved(lease)) }
                    RowButton(symbol: "bookmark.slash", help: "Release reservation") { state.release(lease) }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.13) : hovering ? Color.primary.opacity(0.05) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { state.selectedRowID = rowID }
        .contextMenu {
            Button("Copy URL") { state.copyURL(of: .reserved(lease)) }
            Button("Copy portkeep env") { state.copyText("export PORT=\(lease.port)", label: "env") }
            Divider()
            Button("Release :\(lease.port)") { state.release(lease) }
        }
        .help("Agents call `portkeep alloc \(lease.name)` in this folder to get :\(lease.port) every time")
        .id(rowID)
    }
}
