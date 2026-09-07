import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openSettings) private var openSettings

    private enum Tab: Hashable { case ports, docker }

    @State private var tab: Tab = .ports
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            if state.showPaywall {
                PaywallView()
            } else {
                header
                Divider()
                content
            }
            Divider()
            footer
        }
        .frame(width: 400, height: 520)
        .background(.regularMaterial)
        .onAppear { state.panelDidAppear() }
        .onDisappear { state.panelDidDisappear() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter by port, name or process", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            if state.settings.showDocker {
                Picker("", selection: $tab) {
                    Text("Ports · \(state.visiblePorts.count)").tag(Tab.ports)
                    Text("Docker · \(state.containers.filter(\.isRunning).count)").tag(Tab.docker)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .padding(12)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let showDockerTab = state.settings.showDocker && tab == .docker
        ScrollView {
            LazyVStack(spacing: 2) {
                if showDockerTab {
                    dockerList
                } else {
                    portList
                }
            }
            .padding(8)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var portList: some View {
        let ports = filteredPorts
        if ports.isEmpty {
            EmptyState(
                symbol: state.visiblePorts.isEmpty ? "antenna.radiowaves.left.and.right.slash" : "magnifyingglass",
                title: state.visiblePorts.isEmpty ? "Nothing listening" : "No matches",
                message: state.visiblePorts.isEmpty
                    ? "Start a dev server, database or container and it will show up here."
                    : "Nothing matches “\(query)”."
            )
        } else {
            ForEach(ports) { port in
                PortRow(port: port)
            }
        }
    }

    @ViewBuilder
    private var dockerList: some View {
        switch state.dockerAvailability {
        case .unknown:
            EmptyState(symbol: "shippingbox", title: "Checking Docker…", message: "")
        case .notInstalled:
            EmptyState(
                symbol: "shippingbox",
                title: "Docker not found",
                message: "Install Docker Desktop or OrbStack and Portside will pick it up automatically."
            )
        case .daemonNotRunning:
            EmptyState(
                symbol: "shippingbox",
                title: "Docker isn't running",
                message: "Start Docker Desktop or OrbStack to see your containers."
            )
        case .failed(let message):
            EmptyState(symbol: "exclamationmark.triangle", title: "Docker error", message: message)
        case .available:
            let containers = filteredContainers
            if containers.isEmpty {
                EmptyState(
                    symbol: "shippingbox",
                    title: state.containers.isEmpty ? "No containers" : "No matches",
                    message: state.containers.isEmpty ? "Run a container and it will show up here." : "Nothing matches “\(query)”."
                )
            } else {
                ForEach(containers) { container in
                    ContainerRow(container: container)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            LicenseBadge()

            if let error = state.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(error)
            }

            Spacer()

            if state.isRefreshing {
                ProgressView().controlSize(.mini)
            } else {
                Button {
                    Task { await state.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }

            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")

            Button {
                state.quit()
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit Portside")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Filtering

    private var filteredPorts: [ListeningPort] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return state.visiblePorts }
        return state.visiblePorts.filter { port in
            String(port.port).contains(q)
                || port.command.lowercased().contains(q)
                || (state.projects[port.pid]?.name.lowercased().contains(q) ?? false)
                || (state.container(publishing: port.port)?.name.lowercased().contains(q) ?? false)
        }
    }

    private var filteredContainers: [DockerContainer] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return state.containers }
        return state.containers.filter {
            $0.name.lowercased().contains(q)
                || $0.image.lowercased().contains(q)
                || $0.publishedPorts.contains { String($0).contains(q) }
        }
    }
}

// MARK: - Shared bits

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            if !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .padding(.horizontal, 24)
    }
}

struct Chip: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
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
                Chip(text: "Pro", tint: .accentColor)
            case .trial(let days):
                Chip(text: "Trial · \(days)d left", tint: days <= 3 ? .orange : .secondary)
            case .expired:
                Chip(text: "Trial ended", tint: .red)
            }
        }
        .buttonStyle(.plain)
        .help("Portside Pro")
    }
}
