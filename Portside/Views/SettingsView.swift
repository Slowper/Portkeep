import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        @Bindable var settings = state.settings

        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Picker("Refresh while open", selection: $settings.refreshInterval) {
                    Text("Every second").tag(1.0)
                    Text("Every 3 seconds").tag(3.0)
                    Text("Every 5 seconds").tag(5.0)
                    Text("Every 10 seconds").tag(10.0)
                }
                .onChange(of: settings.refreshInterval) { _, _ in
                    state.settingsDidChange()
                }
            }

            Section("Ports") {
                Toggle("Hide macOS system processes", isOn: $settings.hideSystemProcesses)
                Toggle("Show Docker tab", isOn: $settings.showDocker)
                    .onChange(of: settings.showDocker) { _, _ in
                        Task { await state.refresh() }
                    }
            }

            Section("License") {
                switch state.license.status {
                case .licensed(let key):
                    LabeledContent("Status", value: "Pro · …\(key.suffix(5))")
                    Button("Deactivate this Mac", role: .destructive) {
                        state.license.deactivate()
                    }
                case .trial(let days):
                    LabeledContent("Status", value: "Trial · \(days) days left")
                case .expired:
                    LabeledContent("Status", value: "Trial ended")
                }
            }

            Section {
                LabeledContent("Version", value: Bundle.main.versionString)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

extension Bundle {
    var versionString: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
