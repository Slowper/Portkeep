import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

private enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general, workspace, agents, devices, policy, audit, license

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .workspace: "Workspace"
        case .agents: "Agents"
        case .devices: "Devices"
        case .policy: "Policy"
        case .audit: "Audit"
        case .license: "License"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .workspace: "rectangle.3.group"
        case .agents: "cpu"
        case .devices: "laptopcomputer.and.iphone"
        case .policy: "lock.shield"
        case .audit: "list.clipboard"
        case .license: "key"
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var pane: SettingsPane = .general

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsPane.allCases, selection: $pane) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(width: 168)

            Divider()

            Group {
                switch pane {
                case .general: GeneralSettings()
                case .workspace: WorkspaceSettings()
                case .agents: AgentSettings()
                case .devices: DeviceSettings()
                case .policy: PolicySettings()
                case .audit: AuditSettings()
                case .license: LicenseSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 640, minHeight: 480)
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
                .disabled(settings.isLocked(ManagedKey.hotKeyEnabled, user: "hotKeyEnabled"))

                Toggle("Show port count in menu bar", isOn: $settings.showCountInMenuBar)
                    .disabled(settings.isLocked(ManagedKey.showCountInMenuBar, user: "showCountInMenuBar"))
            } header: {
                Text("Behaviour")
            }

            Section {
                Button("Check for Updates…") {
                    AppUpdates.checkForUpdates()
                }
                Toggle("Automatically check for updates", isOn: autoUpdateBinding)
                    .disabled(AppUpdates.updatesAreManaged)
                Text("Like macOS Software Update: Portkeep checks once a day, then you confirm the install. The check only fetches version metadata from \(Product.websiteHost). Ports, processes, and project paths never leave this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Privacy", destination: Product.privacyURL)
                    .font(.caption)
            } header: {
                Text("Updates")
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
                .disabled(settings.isLocked(ManagedKey.probeHealth, user: "probeHealth"))
            } header: {
                Text("Scanning")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
    }

    private var autoUpdateBinding: Binding<Bool> {
        Binding(
            get: { AppUpdates.automaticallyChecksForUpdates },
            set: { AppUpdates.automaticallyChecksForUpdates = $0 }
        )
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
                    .disabled(settings.isLocked(ManagedKey.showDocker, user: "showDocker"))
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

// MARK: - Agents

private struct AgentSettings: View {
    @State private var cliInstalled = CLIInstall.isOnPATH()
    @State private var cursorInstalled = MCPInstall.isInstalled(in: .cursor)
    @State private var claudeInstalled = MCPInstall.isInstalled(in: .claudeCode)
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("CLI") {
                    Text(cliInstalled ? CLIInstall.installedURL()?.path ?? "Installed" : "Not on PATH")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if cliInstalled {
                    Button("Remove from PATH") {
                        run {
                            try CLIInstall.uninstall()
                            cliInstalled = false
                            message = "Removed the CLI from PATH."
                        }
                    }
                } else {
                    Button("Install `portkeep` to ~/.local/bin") {
                        run {
                            let url = try CLIInstall.install()
                            cliInstalled = true
                            message = "Installed to \(url.path)"
                        }
                    }
                }
            } header: {
                Text("Command line")
            } footer: {
                Text("Agents and shells call `portkeep alloc web` and `portkeep who 3000`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                hostRow(
                    title: "Cursor",
                    installed: cursorInstalled,
                    add: {
                        try MCPInstall.install(into: .cursor)
                        cursorInstalled = true
                        cliInstalled = CLIInstall.isOnPATH()
                        message = "Added to Cursor. Restart Cursor to load it."
                    },
                    remove: {
                        try MCPInstall.remove(from: .cursor)
                        cursorInstalled = false
                        message = "Removed from Cursor."
                    }
                )
                hostRow(
                    title: "Claude Code",
                    installed: claudeInstalled,
                    add: {
                        try MCPInstall.install(into: .claudeCode)
                        claudeInstalled = true
                        cliInstalled = CLIInstall.isOnPATH()
                        message = "Added to Claude Code. Restart Claude Code to load it."
                    },
                    remove: {
                        try MCPInstall.remove(from: .claudeCode)
                        claudeInstalled = false
                        message = "Removed from Claude Code."
                    }
                )
            } header: {
                Text("MCP")
            } footer: {
                Text("Writes `portkeep mcp` into ~/.cursor/mcp.json and ~/.claude.json. Other servers are left alone. Restart the host after adding.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Copy AGENTS.md snippet") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(MCPInstall.snippet, forType: .string)
                    message = "Copied. Paste it into AGENTS.md or CLAUDE.md."
                }
                Button("Write AGENTS.md to a folder…") {
                    writeSnippet()
                }
            } header: {
                Text("Repo snippet")
            } footer: {
                Text("Tells agents to call `alloc` before starting a dev server, and `who` on EADDRINUSE.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message {
                Section {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
        .onAppear {
            cliInstalled = CLIInstall.isOnPATH()
            cursorInstalled = MCPInstall.isInstalled(in: .cursor)
            claudeInstalled = MCPInstall.isInstalled(in: .claudeCode)
        }
    }

    private func hostRow(title: String, installed: Bool, add: @escaping () throws -> Void, remove: @escaping () throws -> Void) -> some View {
        LabeledContent(title) {
            HStack {
                Text(installed ? "Installed" : "Not added")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if installed {
                    Button("Remove") { run(remove) }
                        .controlSize(.small)
                } else {
                    Button("Add") { run(add) }
                        .controlSize(.small)
                }
            }
        }
    }

    private func writeSnippet() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Write"
        panel.message = "Portkeep will create or append AGENTS.md in this folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run {
            let written = try MCPInstall.writeSnippet(to: url)
            message = "Wrote \(written.path)"
        }
    }

    private func run(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Devices

private struct DeviceSettings: View {
    @Environment(AppState.self) private var state
    @State private var pin = RemotePIN.load() ?? ""

    var body: some View {
        @Bindable var settings = state.settings
        Form {
            Section {
                Toggle("Share this Mac on the local network", isOn: $settings.remoteSharingEnabled)
                    .disabled(settings.isLocked(ManagedKey.remoteSharing, user: "remoteSharingEnabled"))
                    .onChange(of: settings.remoteSharingEnabled) { _, enabled in
                        if enabled { pin = RemotePIN.ensure() }
                        state.settingsDidChange()
                    }
                if let error = state.remote.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("My other Macs")
            } footer: {
                Text("Leftover servers on your other Portkeep Macs show up in the panel. Traffic stays on this LAN. Nothing is uploaded. Turn this on on every Mac you own, and use the same PIN.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.remoteSharingEnabled {
                Section {
                    LabeledContent("PIN") {
                        Text(pin.isEmpty ? "—" : pin)
                            .font(.system(.body, design: .monospaced))
                    }
                    Button("Copy PIN") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pin, forType: .string)
                    }
                    Button("New PIN") {
                        pin = RemotePIN.replace()
                        state.settingsDidChange()
                    }
                } header: {
                    Text("Pairing")
                } footer: {
                    Text("The other Mac must use this exact PIN. IT can force RemoteSharingEnabled off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    if state.remote.peers.isEmpty {
                        Text("No other Portkeep Macs on this network yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(state.remote.peers) { peer in
                            LabeledContent(peer.name) {
                                Text(peer.snapshot.map { "\($0.leftovers.count) left behind" } ?? (peer.lastError ?? "…"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Refresh") {
                        Task { await state.remote.refreshPeers() }
                    }
                } header: {
                    Text("Seen")
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
        .onAppear { pin = RemotePIN.load() ?? "" }
    }
}

// MARK: - Policy

private struct PolicySettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var settings = state.settings
        Form {
            Section {
                Toggle("Enforce stop policy", isOn: $settings.policyEnabled)
                    .disabled(settings.isManaged(PolicyKey.enabled))
                Toggle("Confirm before stopping LAN / 0.0.0.0 binds", isOn: $settings.policyRequireLANConfirm)
                    .disabled(settings.isManaged(PolicyKey.requireLANConfirm))
                Toggle("Allow stops outside the home folder", isOn: $settings.policyAllowOutsideHome)
                    .disabled(settings.isManaged(PolicyKey.allowOutsideHome))
                Toggle("Allow protected infrastructure (break-glass)", isOn: $settings.policyAllowProtectedStop)
                    .disabled(settings.isManaged(PolicyKey.allowProtectedStop))
            } header: {
                Text("Stops")
            } footer: {
                Text("Postgres, Redis, Docker, Ollama and other known services are never killed. Stops stay inside your home folder plus any allowed roots. LAN binds need a second confirm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Always allowed") {
                    Text("~/").foregroundStyle(.secondary)
                }
                ForEach(settings.policyAllowedRoots, id: \.self) { root in
                    LabeledContent("Allowed") {
                        HStack {
                            Text(root)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if !settings.isManaged(PolicyKey.allowedRoots) {
                                Button("Remove", role: .destructive) {
                                    settings.policyAllowedRoots.removeAll { $0 == root }
                                    state.settingsDidChange()
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
                if !settings.isManaged(PolicyKey.allowedRoots) {
                    Button("Add folder…") { addRoot() }
                }
            } header: {
                Text("Allowed folders")
            } footer: {
                Text("Jamf / Kandji: domain com.sajidpalagiri.portkeep. Run `portkeep mdm` on a Mac to see which keys are locked. Sample profile is in the pkg folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
        .onChange(of: settings.policyEnabled) { _, _ in state.settingsDidChange() }
        .onChange(of: settings.policyRequireLANConfirm) { _, _ in state.settingsDidChange() }
        .onChange(of: settings.policyAllowOutsideHome) { _, _ in state.settingsDidChange() }
        .onChange(of: settings.policyAllowProtectedStop) { _, _ in state.settingsDidChange() }
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Allow"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        if !state.settings.policyAllowedRoots.contains(path) {
            state.settings.policyAllowedRoots.append(path)
            state.settingsDidChange()
        }
    }
}

// MARK: - Audit

private struct AuditSettings: View {
    @State private var events: [AuditEvent] = []
    @State private var exportError: String?

    var body: some View {
        Form {
            Section {
                if events.isEmpty {
                    Text("No events yet. Stops, allocations, releases, and policy denials are written here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.line)
                                .font(.system(.caption, design: .monospaced))
                            Text("\(event.source.rawValue) · \(event.user)@\(event.host)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                Text("Recent")
            } footer: {
                Text("Append-only JSONL at ~/.portkeep/audit.jsonl. Nothing is uploaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Log file") {
                    Text(Audit.url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Reveal in Finder") {
                    if FileManager.default.fileExists(atPath: Audit.url.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([Audit.url])
                    } else {
                        NSWorkspace.shared.open(Audit.url.deletingLastPathComponent())
                    }
                }
                Button("Export…") { exportLog() }
                if let exportError {
                    Text(exportError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("File")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
        .onAppear { events = Audit.recent(limit: 40) }
    }

    private func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "portkeep-audit.jsonl"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Audit.export(to: url)
            exportError = nil
        } catch {
            exportError = error.localizedDescription
        }
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
                    if !state.license.orgIsManaged {
                        Button("Deactivate this Mac", role: .destructive) { state.license.deactivate() }
                    }
                case .organization(let seat):
                    LabeledContent("Status") {
                        Label("Organization", systemImage: "building.2.fill").foregroundStyle(.green)
                    }
                    LabeledContent("Org", value: seat.org)
                    LabeledContent("Seats", value: "\(seat.seats) purchased")
                    LabeledContent("This Mac", value: "\(seat.user) · \(seat.host)")
                    LabeledContent("Device", value: String(seat.deviceID.suffix(8)))
                    if !state.license.orgIsManaged {
                        Button("Release this seat", role: .destructive) { state.license.deactivate() }
                    } else {
                        Text("Assigned by your organization. This seat cannot be removed here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .trial(let days):
                    LabeledContent("Status", value: "Trial · \(days) day\(days == 1 ? "" : "s") left")
                case .expired:
                    LabeledContent("Status", value: "Trial ended")
                }
            } footer: {
                Text("Personal key: PKP-XXXXX-XXXXX-XXXXX (this person, their Macs). Org key: PKO-ACME-10-XXXXX-XXXXX (ten seats). IT can force OrgLicense on domain com.sajidpalagiri.portkeep.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !state.license.isLicensed {
                Section {
                    TextField("License key", text: $key, prompt: Text("PKP-… or PKO-…"))
                        .font(.system(.body, design: .monospaced))
                        .onSubmit(activate)
                    HStack {
                        Link("Buy Portkeep Pro", destination: LicenseManager.purchaseURL)
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
