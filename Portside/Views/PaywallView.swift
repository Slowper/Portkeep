import SwiftUI

struct PaywallView: View {
    @Environment(AppState.self) private var state

    private enum Plan: Hashable { case monthly, yearly }

    @State private var plan: Plan = .yearly
    @State private var showKeyEntry = false
    @State private var key = ""
    @State private var isActivating = false
    @State private var error: String?

    private var license: LicenseManager { state.license }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            hero

            VStack(alignment: .leading, spacing: 9) {
                feature("xmark.circle.fill", "Stop or force-kill any process", "Right from the panel, with a two-click safety.")
                feature("shippingbox.fill", "Control Docker containers", "Start, stop and restart without leaving your editor.")
                feature("keyboard.fill", "Global hotkey & keyboard flow", "\(HotKey.displayString) anywhere, ↑↓ ⏎ ⌘⌫ inside.")
                feature("waveform.path.ecg", "Live health probing", "See 200 · 12ms instead of guessing which port is alive.")
            }

            if license.isLicensed {
                licensedFooter
            } else {
                purchase
                keyEntry
            }
        }
        .padding(14)
        .frame(width: StatusBarController.panelWidth)
    }

    // MARK: - Pieces

    private var hero: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                state.showPaywall = false
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Back (esc)")

            VStack(alignment: .leading, spacing: 4) {
                Text("Portside Pro")
                    .font(.system(size: 17, weight: .bold))
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(statusTint)
            }
            Spacer()
            IconTile(symbol: "bolt.fill", tint: Color.accentColor, size: 38)
        }
    }

    private var statusText: String {
        switch license.status {
        case .licensed(let key): "Licensed · key ending \(key.suffix(5))"
        case .trial(let days): "\(days) day\(days == 1 ? "" : "s") left in your free trial"
        case .expired: "Trial ended — viewing ports stays free forever"
        }
    }

    private var statusTint: Color {
        switch license.status {
        case .licensed: .green
        case .trial(let days): days <= 3 ? .orange : .secondary
        case .expired: .orange
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20, height: 20)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }

    private var purchase: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                planButton(.monthly, title: "Monthly", price: "$6", note: "per month")
                planButton(.yearly, title: "Yearly", price: "$49", note: "save 32%")
            }

            Link(destination: LicenseManager.purchaseURL) {
                HStack {
                    Text("Continue to checkout")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(
                    LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.8)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            Text("One license covers all your Macs. Cancel anytime.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    private func planButton(_ value: Plan, title: String, price: String, note: String) -> some View {
        let selected = plan == value
        return Button {
            withAnimation(.snappy(duration: 0.18)) { plan = value }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if value == .yearly {
                        Chip(text: "BEST", tint: .green, filled: true)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(price).font(.system(size: 17, weight: .bold, design: .rounded))
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { showKeyEntry.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(showKeyEntry ? 90 : 0))
                    Text("Already have a license key?")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if showKeyEntry {
                HStack(spacing: 6) {
                    TextField("PSD-XXXXX-XXXXX-XXXXX", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit(activate)
                    Button(action: activate) {
                        Group {
                            if isActivating {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Activate")
                            }
                        }
                        .frame(minWidth: 60)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.isEmpty || isActivating)
                }
                if let error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var licensedFooter: some View {
        HStack {
            Label("Thanks for supporting Portside", systemImage: "heart.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Deactivate this Mac", role: .destructive) {
                license.deactivate()
            }
            .controlSize(.small)
        }
    }

    private func activate() {
        guard !key.isEmpty, !isActivating else { return }
        isActivating = true
        error = nil
        Task {
            defer { isActivating = false }
            do {
                try await license.activate(key: key)
                key = ""
                state.showToast("Portside Pro activated", symbol: "checkmark.seal.fill")
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
