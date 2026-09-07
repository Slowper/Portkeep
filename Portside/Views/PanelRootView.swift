import SwiftUI

struct PanelRootView: View {
    @Environment(AppState.self) private var state
    @FocusState private var searchFocused: Bool
    @State private var listContentHeight: CGFloat = 0

    private let maxListHeight: CGFloat = 470

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            SearchBar(focused: $searchFocused)
            Divider().opacity(0.6)

            if state.showPaywall {
                PaywallView()
            } else {
                list
            }

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
        .onChange(of: state.showPaywall) { _, showing in
            if !showing { searchFocused = true }
        }
    }

    // MARK: - List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ListContent()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .reportHeight { listContentHeight = $0 }
            }
            .scrollIndicators(.automatic)
            .frame(height: min(max(listContentHeight, 96), maxListHeight))
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
            IconTile(symbol: "point.3.filled.connected.trianglepath.dotted", tint: Color.accentColor, size: 22)
            Text("Portside")
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
            } else if filtered.isEmpty && !state.showWelcome {
                emptyState
            } else {
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
                if headerMatch { return group }
                let ports = group.ports.filter { String($0.port).contains(q) || $0.command.lowercased().contains(q) }
                guard !ports.isEmpty else { return nil }
                var copy = group
                copy.ports = ports
                return copy
            }
        }

        sections.projects = filter(sections.projects)
        sections.containers = filter(sections.containers)
        sections.other = filter(sections.other)
        sections.stopped = sections.stopped.filter { $0.name.lowercased().contains(q) || $0.image.lowercased().contains(q) }
        return sections
    }

    private func buildRows(_ sections: DashboardSections) -> [(id: String, ref: RowRef)] {
        var rows: [(id: String, ref: RowRef)] = []
        for group in sections.projects + sections.other {
            for port in group.ports { rows.append((GroupCard.rowID(group, port), .port(port))) }
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
        return rows
    }
}

// MARK: - Welcome

private struct WelcomeCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Portside")
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
            LicenseBadge()

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

            RowButton(symbol: "power", help: "Quit Portside (⌘Q)") {
                state.quit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

struct LicenseBadge: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Button {
            state.showPaywall.toggle()
        } label: {
            switch state.license.status {
            case .licensed:
                Chip(text: "PRO", tint: .accentColor, filled: true)
            case .trial(let days):
                Chip(text: "Trial · \(days)d", tint: days <= 3 ? .orange : .secondary)
            case .expired:
                Chip(text: "Upgrade", tint: .accentColor, filled: true)
            }
        }
        .buttonStyle(.plain)
        .help(state.showPaywall ? "Back" : "Portside Pro")
    }
}
