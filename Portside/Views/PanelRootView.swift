import SwiftUI

struct PanelRootView: View {
    @Environment(AppState.self) private var state
    @FocusState private var searchFocused: Bool
    @State private var listContentHeight: CGFloat = 0

    private let maxListHeight: CGFloat = 470

    /// Transparent margin around the visible panel that hosts the drop shadow.
    static let shadowMargin: CGFloat = 30

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            SearchBar(focused: $searchFocused)
            Divider().opacity(0.6)

            list

            Divider().opacity(0.6)
            FooterBar()
        }
        .frame(width: StatusBarController.panelWidth)
        .panelChrome()
        .overlay(alignment: .bottom) {
            if let toast = state.toast {
                ToastView(toast: toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: state.toast)
        .reportHeight { height in
            NotificationCenter.default.post(name: .panelPreferredHeightDidChange, object: nil, userInfo: ["height": height])
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { searchFocused = true }
    }

    // MARK: - List

    private var list: some View {
        let isScrollable = listContentHeight > maxListHeight
        return ScrollViewReader { proxy in
            ScrollView {
                ListContent()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .reportHeight { listContentHeight = $0 }
                    .background { ScrollerHider().frame(width: 0, height: 0) }
            }
            .scrollIndicators(.hidden)
            .frame(height: min(max(listContentHeight, 96), maxListHeight))
            // Fade the bottom edge instead of showing a scrollbar track over glass.
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(isScrollable ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 26)
                }
            }
            .animation(.snappy(duration: 0.22), value: min(max(listContentHeight, 96), maxListHeight))
            .onChange(of: state.selectedRowID) { _, id in
                guard let id else { return }
                withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(id, anchor: nil) }
            }
        }
    }
}

// MARK: - Header

private struct HeaderBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 10) {
            BrandMarkView(size: 22)
            Text("Portkeep")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            LiveIndicator()

            Button {
                state.isPinned.toggle()
                state.showToast(state.isPinned ? "Pinned — stays open" : "Unpinned", symbol: state.isPinned ? "pin.fill" : "pin")
            } label: {
                Image(systemName: state.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(state.isPinned ? Color.accentColor : .secondary)
                    .frame(width: 22, height: 22)
                    .background(state.isPinned ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(state.isPinned ? "Unpin (⌘P)" : "Keep the panel open (⌘P)")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

private struct LiveIndicator: View {
    @Environment(AppState.self) private var state

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 5) {
                PulsingDot(color: state.errorMessage == nil ? .green : .orange)
                Text(label(now: context.date))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .help(state.errorMessage ?? "Refreshing every \(Int(state.settings.refreshInterval))s while open")
    }

    private func label(now: Date) -> String {
        guard let last = state.lastRefreshed else { return "Scanning…" }
        let seconds = Int(now.timeIntervalSince(last))
        return seconds < 2 ? "Live" : "Live · \(seconds)s"
    }
}

// MARK: - Search

private struct SearchBar: View {
    @Environment(AppState.self) private var state
    var focused: FocusState<Bool>.Binding

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Filter ports, projects, containers…", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(focused)
            if !state.query.isEmpty {
                Button { state.query = "" } label: {
                    Keycap(text: "esc")
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .animation(.snappy(duration: 0.15), value: state.query.isEmpty)
    }
}

// MARK: - Content

private struct ListContent: View {
    @Environment(AppState.self) private var state
    @State private var stoppedExpanded = false

    var body: some View {
        let filtered = filteredSections
        let rows = buildRows(filtered)

        LazyVStack(alignment: .leading, spacing: 8) {
            if state.showWelcome {
                WelcomeCard()
            }

            if !state.hasLoadedOnce {
                EmptyState(symbol: "antenna.radiowaves.left.and.right", title: "Scanning…", message: "")
            } else if filtered.isEmpty && state.remote.peers.isEmpty && !state.showWelcome {
                emptyState
            } else {
                if !state.remote.peers.isEmpty {
                    RemoteMacsSection(peers: state.remote.peers)
                }
                if !filtered.leftBehind.isEmpty {
                    LeftBehindHeader(groups: filtered.leftBehind, memory: filtered.leftBehindMemory)
                    ForEach(filtered.leftBehind) { GroupCard(group: $0) }
                }
                if !filtered.projects.isEmpty {
                    SectionHeader(title: "Projects", count: filtered.projects.count)
                    ForEach(filtered.projects) { GroupCard(group: $0) }
                }
                if !filtered.containers.isEmpty || dockerHint != nil {
                    SectionHeader(title: "Containers", count: filtered.containers.isEmpty ? nil : filtered.containers.count)
                    ForEach(filtered.containers) { GroupCard(group: $0) }
                    if let dockerHint {
                        HStack(spacing: 8) {
                            Image(systemName: "shippingbox")
                                .foregroundStyle(.tertiary)
                            Text(dockerHint)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                if !filtered.other.isEmpty {
                    SectionHeader(title: "Other processes", count: filtered.other.count)
                    ForEach(filtered.other) { GroupCard(group: $0) }
                }
                if !filtered.reserved.isEmpty {
                    SectionHeader(title: "Reserved", count: filtered.reserved.count)
                    ForEach(filtered.reserved) { lease in
                        ReservedLeaseCard(lease: lease)
                    }
                }
                if !filtered.stopped.isEmpty {
                    stoppedSection(filtered.stopped)
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: rows.map(\.id))
        .onChange(of: rows.map(\.id), initial: true) { _, _ in
            state.updateRows(rows)
        }
    }

    private var emptyState: some View {
        Group {
            if state.query.isEmpty {
                EmptyState(
                    symbol: "moon.zzz",
                    title: "Nothing's listening",
                    message: "Run `npm run dev`, start a database or a container and it'll appear here within a few seconds."
                )
            } else {
                EmptyState(symbol: "magnifyingglass", title: "No matches", message: "Nothing matches “\(state.query)”.")
            }
        }
    }

    private var dockerHint: String? {
        guard state.settings.showDocker, state.query.isEmpty else { return nil }
        switch state.dockerAvailability {
        case .daemonNotRunning: return "Docker isn't running"
        case .failed(let message): return "Docker: \(message)"
        case .available where state.containers.isEmpty: return "No containers"
        default: return nil
        }
    }

    private func stoppedSection(_ stopped: [DockerContainer]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { stoppedExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(stoppedExpanded ? 90 : 0))
                    Text("\(stopped.count) stopped container\(stopped.count == 1 ? "" : "s")")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if stoppedExpanded {
                ForEach(stopped) { container in
                    GroupCard(group: DashboardGroup(id: "docker:\(container.id)", kind: .container(container), ports: []))
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: Filtering

    private var filteredSections: DashboardSections {
        let q = state.query.trimmingCharacters(in: .whitespaces).lowercased()
        var sections = state.sections
        guard !q.isEmpty else { return sections }

        func filter(_ groups: [DashboardGroup]) -> [DashboardGroup] {
            groups.compactMap { group in
                let headerMatch = group.title.lowercased().contains(q)
                    || group.subtitle.lowercased().contains(q)
                    || (group.project?.kind.label.lowercased().contains(q) ?? false)
                    || (group.origin?.label.lowercased().contains(q) ?? false)
                    || (group.lineage?.rootCommand.lowercased().contains(q) ?? false)
                    || group.reserved.contains { $0.name.contains(q) || String($0.port).contains(q) }
                if headerMatch { return group }
                let ports = group.ports.filter { String($0.port).contains(q) || $0.command.lowercased().contains(q) }
                let reserved = group.reserved.filter { $0.name.contains(q) || String($0.port).contains(q) }
                guard !ports.isEmpty || !reserved.isEmpty else { return nil }
                var copy = group
                copy.ports = ports
                copy.reserved = reserved
                return copy
            }
        }

        sections.leftBehind = filter(sections.leftBehind)
        sections.projects = filter(sections.projects)
        sections.containers = filter(sections.containers)
        sections.other = filter(sections.other)
        sections.reserved = sections.reserved.filter {
            $0.name.contains(q) || String($0.port).contains(q) || $0.projectName.lowercased().contains(q)
        }
        sections.stopped = sections.stopped.filter { $0.name.lowercased().contains(q) || $0.image.lowercased().contains(q) }
        return sections
    }

    private func buildRows(_ sections: DashboardSections) -> [(id: String, ref: RowRef)] {
        var rows: [(id: String, ref: RowRef)] = []
        for group in sections.leftBehind + sections.projects + sections.other {
            for port in group.ports { rows.append((GroupCard.rowID(group, port), .port(port))) }
            for lease in group.reserved { rows.append((GroupCard.reservedID(lease), .reserved(lease))) }
        }
        for group in sections.containers {
            guard let container = group.container else { continue }
            if group.ports.isEmpty {
                rows.append((group.id, .container(container)))
            } else {
                for port in group.ports { rows.append((GroupCard.rowID(group, port), .containerPort(container, port.port))) }
            }
        }
        if stoppedExpanded {
            for container in sections.stopped {
                rows.append(("docker:\(container.id)", .container(container)))
            }
        }
        for lease in sections.reserved {
            rows.append((GroupCard.reservedID(lease), .reserved(lease)))
        }
        return rows
    }
}

private struct ReservedLeaseCard: View {
    @Environment(AppState.self) private var state
    let lease: PortLease

    var body: some View {
        GroupCard(group: DashboardGroup(
            id: "lease:\(lease.id)",
                kind: .project(ProjectInfo(
                directory: URL(fileURLWithPath: lease.directory),
                name: lease.projectName,
                kind: .generic
            )),
            ports: [],
            reserved: [lease]
        ))
    }
}

// MARK: - Left behind

private struct RemoteMacsSection: View {
    @Environment(AppState.self) private var state
    let peers: [RemotePeer]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Other Macs", count: peers.count)
            ForEach(peers) { peer in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(peer.name)
                            .font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                        Text(peer.snapshot.map { "\($0.leftovers.count) left behind" } ?? (peer.lastError ?? "…"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let leftovers = peer.snapshot?.leftovers, !leftovers.isEmpty {
                        ForEach(leftovers) { listener in
                            remoteRow(peer: peer, listener: listener)
                        }
                    } else if peer.lastError == nil {
                        Text("Nothing left behind on that Mac.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func remoteRow(peer: RemotePeer, listener: RemoteListenerDTO) -> some View {
        let id = "remote:\(peer.deviceID):\(listener.port)"
        let armed = state.pendingStopID == id
        return HStack(spacing: 8) {
            Text(":\(listener.port)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            Text(listener.project ?? listener.command)
                .font(.system(size: 12))
                .lineLimit(1)
            if listener.lan {
                Chip(text: "LAN", tint: .orange)
            }
            Spacer()
            Button {
                state.requestRemoteStop(peer: peer, listener: listener)
            } label: {
                Text(armed ? (listener.lan ? "LAN?" : "Stop?") : "Stop")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(armed ? .orange : .secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Header for servers nobody is looking after any more, with a one-shot cleanup.
private struct LeftBehindHeader: View {
    @Environment(AppState.self) private var state
    let groups: [DashboardGroup]
    let memory: UInt64

    private var isArmed: Bool { state.pendingStopID == AppState.leftBehindStopID }

    private var summary: String {
        let orphaned = groups.filter { $0.lineage?.isOrphaned == true }.count
        let gone = groups.count - orphaned
        var parts: [String] = []
        if orphaned > 0 { parts.append("parent exited") }
        if gone > 0 { parts.append("folder deleted") }
        var text = parts.joined(separator: " · ")
        if memory >= 32 * 1024 * 1024 {
            text += " · holding \(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory))"
        }
        return text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "person.slash.fill")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.orange)
            Text("LEFT BEHIND")
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.orange)
            Text("\(groups.count)")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.orange.opacity(0.7))
            Text(summary)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
            Spacer(minLength: 6)
            Button {
                state.requestStopAllLeftBehind()
            } label: {
                Text(isArmed ? "Stop all?" : "Stop all")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(isArmed ? .white : .orange)
                    .padding(.horizontal, 8)
                    .frame(height: 19)
                    .background(isArmed ? Color.red : Color.orange.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(isArmed ? "Click again to stop every left-behind process tree" : "Stop every left-behind server and its process tree")
            .animation(.snappy(duration: 0.18), value: isArmed)
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

// MARK: - Welcome

private struct WelcomeCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Portkeep")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Everything listening on your Mac, one keystroke away.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    state.dismissWelcome()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 14) {
                hint(HotKey.displayString, "open anywhere")
                hint("↑↓", "navigate")
                hint("⏎", "open")
                hint("⌘⌫", "stop")
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.16), Color.accentColor.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5))
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Keycap(text: key)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

// MARK: - Footer

private struct FooterBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 8) {
            if let error = state.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .help(error)
            }

            Spacer()

            HStack(spacing: 4) {
                Keycap(text: "↑↓")
                Keycap(text: "⏎")
                Keycap(text: "⌘⌫")
            }
            .opacity(0.8)
            .help("↑↓ navigate · ⏎ open · ⌘C copy URL · ⌘⌫ stop · esc close")

            Group {
                if state.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 24, height: 22)
                } else {
                    RowButton(symbol: "arrow.clockwise", help: "Refresh (⌘R)") {
                        Task { await state.refresh() }
                    }
                }
            }

            RowButton(symbol: "gearshape", help: "Settings (⌘,)") {
                state.openSettingsWindow?()
            }

            RowButton(symbol: "power", help: "Quit Portkeep (⌘Q)") {
                state.quit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
