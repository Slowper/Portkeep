import AppKit
import SwiftUI

// MARK: - Window chrome

/// Native vibrancy for the borderless panel.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// Panel background: Liquid Glass on macOS 26+, vibrancy material before that.
struct PanelChrome: ViewModifier {
    static let radius: CGFloat = 18

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
    }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .clipShape(shape)
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(VisualEffectView())
                .clipShape(shape)
                .overlay {
                    shape
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                        .blendMode(.plusLighter)
                }
                .overlay {
                    shape.strokeBorder(.black.opacity(0.25), lineWidth: 0.5)
                }
        }
    }
}

/// True when the panel is drawn with Liquid Glass; inner surfaces adapt.
enum GlassSupport {
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

/// Reports a view's height whenever it changes.
struct HeightReporter: ViewModifier {
    let onChange: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size.height, initial: true) { _, height in
                        onChange(height)
                    }
            }
        }
    }
}

extension View {
    func panelChrome() -> some View { modifier(PanelChrome()) }
    func reportHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View { modifier(HeightReporter(onChange: onChange)) }
}

// MARK: - Atoms

struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.95), tint.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                }
            Image(systemName: symbol)
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
        }
        .frame(width: size, height: size)
    }
}

struct Chip: View {
    let text: String
    var tint: Color = .secondary
    var filled = false

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(filled ? 1 : 0.14), in: Capsule())
            .foregroundStyle(filled ? .white : tint)
            .fixedSize()
    }
}

struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(height: 17)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            )
            .fixedSize()
    }
}

struct PulsingDot: View {
    var color: Color = .green
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: 10, height: 10)
                .scaleEffect(pulse ? 1.6 : 0.8)
                .opacity(pulse ? 0 : 0.8)
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
        }
        .frame(width: 10, height: 10)
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

struct HealthPill: View {
    let result: ProbeResult?

    private var color: Color {
        guard let result else { return .secondary }
        switch result.kind {
        case .http(let code):
            if code < 400 { return .green }
            if code < 500 { return .orange }
            return .red
        case .tcp: return .secondary
        case .unreachable: return .red
        }
    }

    private var label: String {
        guard let result else { return "…" }
        switch result.kind {
        case .http(let code): return "\(code) · \(result.latencyMs)ms"
        case .tcp: return "TCP"
        case .unreachable: return "no reply"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
        .fixedSize()
        .help(helpText)
        .animation(.snappy(duration: 0.2), value: label)
    }

    private var helpText: String {
        guard let result else { return "Checking…" }
        switch result.kind {
        case .http(let code): return "HTTP \(code) from GET / in \(result.latencyMs)ms"
        case .tcp: return "Accepts connections but isn't HTTP (database, gRPC, …)"
        case .unreachable: return "Listening, but nothing answered"
        }
    }
}

struct RowButton: View {
    let symbol: String
    let help: String
    var tint: Color = .secondary
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? tint : tint.opacity(0.85))
                .frame(width: 24, height: 22)
                .background(hovering ? tint.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Destructive action that needs two clicks: first arms it, second fires.
struct ArmedStopButton: View {
    let isArmed: Bool
    var idleSymbol = "xmark.circle"
    var idleHelp = "Stop"
    var armedLabel = "Stop?"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isArmed {
                Text(armedLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Color.red, in: Capsule())
            } else {
                Image(systemName: idleSymbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red.opacity(0.85))
                    .frame(width: 24, height: 22)
            }
        }
        .buttonStyle(.plain)
        .help(isArmed ? "Click again to confirm" : idleHelp)
        .animation(.snappy(duration: 0.18), value: isArmed)
    }
}

struct SectionHeader: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            if let count {
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .semibold))
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 28)
    }
}

struct ToastView: View {
    let toast: AppState.Toast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol)
                .font(.system(size: 12, weight: .semibold))
            Text(toast.text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(white: 0.12).opacity(0.94), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .padding(.bottom, 52)
        .frame(maxWidth: 360)
    }
}
