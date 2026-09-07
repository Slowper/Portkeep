import SwiftUI

struct PaywallView: View {
    @Environment(AppState.self) private var state

    @State private var key = ""
    @State private var isActivating = false
    @State private var error: String?

    private var license: LicenseManager { state.license }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button {
                    state.showPaywall = false
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                Text("Portside Pro")
                    .font(.title2.weight(.bold))
                Spacer()
            }

            statusLine

            VStack(alignment: .leading, spacing: 10) {
                feature("xmark.circle", "Stop and force-kill any process from the menu bar")
                feature("shippingbox", "Start, stop and restart Docker containers")
                feature("folder", "Project detection: see which repo owns each port")
                feature("bolt", "Live refresh while the panel is open")
            }

            if license.isLicensed {
                Button("Deactivate this Mac", role: .destructive) {
                    license.deactivate()
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Have a license key?")
                        .font(.subheadline.weight(.medium))
                    HStack {
                        TextField("PSD-XXXXX-XXXXX-XXXXX", text: $key)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onSubmit(activate)
                        Button(action: activate) {
                            if isActivating {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Activate")
                            }
                        }
                        .disabled(key.isEmpty || isActivating)
                    }
                    if let error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Link(destination: LicenseManager.purchaseURL) {
                    HStack {
                        Text("Get Portside Pro")
                        Spacer()
                        Text("$6 / month · $49 / year")
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.up.right")
                    }
                    .padding(10)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            Spacer()
        }
        .padding(16)
    }

    private var statusLine: some View {
        Group {
            switch license.status {
            case .licensed(let key):
                Label("Licensed · \(String(key.suffix(5)))", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            case .trial(let days):
                Label("\(days) day\(days == 1 ? "" : "s") left in your free trial", systemImage: "clock")
                    .foregroundStyle(.secondary)
            case .expired:
                Label("Your trial has ended. Viewing ports is still free.", systemImage: "lock")
                    .foregroundStyle(.orange)
            }
        }
        .font(.callout)
    }

    private func feature(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            Text(text)
        }
        .font(.callout)
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
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
