import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            WorkspaceSettings()
                .tabItem { Label("Workspace", systemImage: "rectangle.3.group") }
            LicenseSettings()
                .tabItem { Label("License", systemImage: "key") }
        }
        .frame(width: 480)
        .environment(state)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppState.self) private var state

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        @Bindable var settings = state.settings

        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let launchAtLoginError {
                    Text(launchAtLoginError).font(.caption).foregroundStyle(.red)
                }

                Toggle(isOn: $settings.hotKeyEnabled) {
                    HStack {
                        Text("Global shortcut")
                        Spacer()
                        Keycap(text: HotKey.displayString)
                    }
                }

                Toggle("Show port count in menu bar", isOn: $settings.showCountInMenuBar)
            } header: {
                Text("Behaviour")
            }

            Section {
                Picker("Refresh while open", selection: $settings.refreshInterval) {
                    Text("Every second").tag(1.0)
                    Text("Every 3 seconds").tag(3.0)
                    Text("Every 5 seconds").tag(5.0)
                    Text("Every 10 seconds").tag(10.0)
                }
                .onChange(of: settings.refreshInterval) { _, _ in state.settingsDidChange() }

                Toggle(isOn: $settings.probeHealth) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Probe ports over HTTP")
                        Text("Shows status code and latency for each port. Uses a GET request to localhost.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: settings.probeHealth) { _, _ in state.settingsDidChange() }
            } header: {
                Text("Scanning")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
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

// MARK: - Workspace

private struct WorkspaceSettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var settings = state.settings
        let editors = EditorLauncher.installedEditors
        let terminals = EditorLauncher.installedTerminals

        Form {
            Section {
                Toggle(isOn: $settings.hideSystemProcesses) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hide macOS system processes")
                        Text("ControlCenter, rapportd, sharingd and other Apple daemons that always hold ports.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: settings.hideSystemProcesses) { _, _ in state.settingsDidChange() }

                Toggle("Show Docker containers", isOn: $settings.showDocker)
                    .onChange(of: settings.showDocker) { _, _ in state.settingsDidChange() }
            } header: {
                Text("What to show")
            }

            Section {
                Picker("Open projects in", selection: $settings.preferredEditor) {
                    Text("Automatic").tag("auto")
                    if !editors.isEmpty {
                        Divider()
                        ForEach(editors) { Text($0.name).tag($0.id) }
                    }
                }
                Picker("Terminal", selection: $settings.preferredTerminal) {
                    Text("Automatic").tag("auto")
                    if !terminals.isEmpty {
                        Divider()
                        ForEach(terminals) { Text($0.name).tag($0.id) }
                    }
                }
            } header: {
                Text("Tools")
            } footer: {
                Text("Automatic picks the first installed app: \(editors.first?.name ?? "none found") and \(terminals.first?.name ?? "Terminal").")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
    }
}

// MARK: - License

private struct LicenseSettings: View {
    @Environment(AppState.self) private var state

    @State private var key = ""
    @State private var isActivating = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                switch state.license.status {
                case .licensed(let licensed):
                    LabeledContent("Status") {
                        Label("Pro", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                    LabeledContent("Key", value: "•••••-•••••-\(licensed.suffix(5))")
                    Button("Deactivate this Mac", role: .destructive) { state.license.deactivate() }
                case .trial(let days):
                    LabeledContent("Status", value: "Trial · \(days) day\(days == 1 ? "" : "s") left")
                case .expired:
                    LabeledContent("Status", value: "Trial ended")
                }
            }

            if !state.license.isLicensed {
                Section {
                    TextField("License key", text: $key, prompt: Text("PSD-XXXXX-XXXXX-XXXXX"))
                        .font(.system(.body, design: .monospaced))
                        .onSubmit(activate)
                    HStack {
                        Link("Buy Portside Pro", destination: LicenseManager.purchaseURL)
                        Spacer()
                        Button(action: activate) {
                            if isActivating { ProgressView().controlSize(.small) } else { Text("Activate") }
                        }
                        .disabled(key.isEmpty || isActivating)
                    }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Activate")
                }
            }

            Section {
                LabeledContent("Version", value: Bundle.main.versionString)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
    }

    private func activate() {
        guard !key.isEmpty, !isActivating else { return }
        isActivating = true
        error = nil
        Task {
            defer { isActivating = false }
            do {
                try await state.license.activate(key: key)
                key = ""
            } catch {
                self.error = error.localizedDescription
            }
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
