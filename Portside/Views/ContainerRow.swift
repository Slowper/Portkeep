import SwiftUI

struct ContainerRow: View {
    @Environment(AppState.self) private var state
    let container: DockerContainer

    @State private var hovering = false

    private var isBusy: Bool { state.pendingDockerActions.contains(container.id) }

    private var stateColor: Color {
        if container.isRunning { return .green }
        if container.isPaused { return .yellow }
        return .secondary
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(container.name)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ForEach(container.publishedPorts.prefix(3), id: \.self) { port in
                        Chip(text: ":\(port)")
                    }
                }
                Text("\(container.image) · \(container.status)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if isBusy {
                ProgressView().controlSize(.small)
            } else if hovering {
                actions.transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if let first = container.publishedPorts.first, container.isRunning {
                RowButton(symbol: "safari", help: "Open localhost:\(first)") {
                    if let url = URL(string: "http://localhost:\(first)") { NSWorkspace.shared.open(url) }
                }
            }
            if container.isRunning {
                RowButton(symbol: "arrow.clockwise", help: "Restart (Pro)") { state.perform(.restart, on: container) }
                RowButton(symbol: "stop.circle", help: "Stop (Pro)", tint: .red) { state.perform(.stop, on: container) }
            } else {
                RowButton(symbol: "play.circle", help: "Start (Pro)", tint: .green) { state.perform(.start, on: container) }
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        if container.isRunning {
            Button("Restart") { state.perform(.restart, on: container) }
            Button("Stop") { state.perform(.stop, on: container) }
        } else {
            Button("Start") { state.perform(.start, on: container) }
        }
        Divider()
        Button("Copy container ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(container.shortID, forType: .string)
        }
        Text(container.ports.isEmpty ? "No published ports" : container.ports)
    }
}
