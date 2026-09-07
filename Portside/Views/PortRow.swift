import SwiftUI

struct PortRow: View {
    @Environment(AppState.self) private var state
    let port: ListeningPort

    @State private var hovering = false

    private var project: ProjectInfo? { state.projects[port.pid] }
    private var container: DockerContainer? { port.isDockerProxy ? state.container(publishing: port.port) : nil }

    private var symbol: String {
        if container != nil || port.isDockerProxy { return "shippingbox.fill" }
        if let project { return project.kind.symbol }
        if AppSettings.isSystemProcess(port.command) { return "apple.logo" }
        return "terminal.fill"
    }

    private var title: String {
        container?.name ?? project?.name ?? port.command
    }

    private var subtitle: String {
        if let container { return "Docker · \(container.image)" }
        if let project { return "\(project.kind.label) · \(port.command) · pid \(port.pid)" }
        return "pid \(port.pid)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(":\(port.port)")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !port.isLocalOnly {
                        Chip(text: "LAN", tint: .orange)
                            .help("Listening on all interfaces — reachable from other devices on your network")
                    }
                }
            }

            Spacer(minLength: 4)

            if hovering {
                actions
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { state.open(port) }
        .contextMenu { menu }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var actions: some View {
        HStack(spacing: 2) {
            RowButton(symbol: "safari", help: "Open in browser") { state.open(port) }
            RowButton(symbol: "doc.on.doc", help: "Copy URL") { state.copyURL(of: port) }
            if project != nil {
                RowButton(symbol: "folder", help: "Reveal project in Finder") { state.revealProject(for: port) }
            }
            if !port.isDockerProxy {
                RowButton(symbol: "xmark.circle", help: "Stop process (Pro)", tint: .red) { state.terminate(port) }
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Open http://localhost:\(port.port)") { state.open(port) }
        Button("Copy URL") { state.copyURL(of: port) }
        if let project {
            Button("Reveal \(project.name) in Finder") { state.revealProject(for: port) }
        }
        if !port.isDockerProxy {
            Divider()
            Button("Stop \(port.command) (SIGTERM)") { state.terminate(port) }
            Button("Force kill (SIGKILL)") { state.terminate(port, force: true) }
        }
        Divider()
        Text("Bound to \(port.addresses.joined(separator: ", "))")
    }
}

struct RowButton: View {
    let symbol: String
    let help: String
    var tint: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
