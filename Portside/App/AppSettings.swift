import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    /// Seconds between scans while the panel is open.
    var refreshInterval: Double {
        didSet { defaults.set(refreshInterval, forKey: Keys.refreshInterval) }
    }

    /// Hide Apple daemons (rapportd, ControlCenter, ...) that always hold ports.
    var hideSystemProcesses: Bool {
        didSet { defaults.set(hideSystemProcesses, forKey: Keys.hideSystemProcesses) }
    }

    var showDocker: Bool {
        didSet { write(showDocker, forKey: Keys.showDocker, managed: ManagedKey.showDocker) }
    }

    /// Probe ports over HTTP to show status codes and latency.
    var probeHealth: Bool {
        didSet { write(probeHealth, forKey: Keys.probeHealth, managed: ManagedKey.probeHealth) }
    }

    var showCountInMenuBar: Bool {
        didSet { write(showCountInMenuBar, forKey: Keys.showCountInMenuBar, managed: ManagedKey.showCountInMenuBar) }
    }

    var hotKeyEnabled: Bool {
        didSet { write(hotKeyEnabled, forKey: Keys.hotKeyEnabled, managed: ManagedKey.hotKeyEnabled) }
    }

    /// Bundle identifier of the preferred editor, or "auto".
    var preferredEditor: String {
        didSet { defaults.set(preferredEditor, forKey: Keys.preferredEditor) }
    }

    var preferredTerminal: String {
        didSet { defaults.set(preferredTerminal, forKey: Keys.preferredTerminal) }
    }

    var hasSeenWelcome: Bool {
        didSet { defaults.set(hasSeenWelcome, forKey: Keys.hasSeenWelcome) }
    }

    var remoteSharingEnabled: Bool {
        didSet { write(remoteSharingEnabled, forKey: Keys.remoteSharingEnabled, managed: ManagedKey.remoteSharing) }
    }

    var policyEnabled: Bool {
        didSet { write(policyEnabled, forKey: PolicyKey.enabled) }
    }
    var policyRequireLANConfirm: Bool {
        didSet { write(policyRequireLANConfirm, forKey: PolicyKey.requireLANConfirm) }
    }
    var policyAllowOutsideHome: Bool {
        didSet { write(policyAllowOutsideHome, forKey: PolicyKey.allowOutsideHome) }
    }
    var policyAllowProtectedStop: Bool {
        didSet { write(policyAllowProtectedStop, forKey: PolicyKey.allowProtectedStop) }
    }
    var policyAllowedRoots: [String] {
        didSet { write(policyAllowedRoots, forKey: PolicyKey.allowedRoots) }
    }

    func isManaged(_ key: String) -> Bool {
        defaults.objectIsForced(forKey: key)
    }

    func isLocked(_ mdm: String, user: String? = nil) -> Bool {
        if isManaged(mdm) { return true }
        if let user { return isManaged(user) }
        return false
    }

    init(defaults: UserDefaults = PortkeepDefaults.suite) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.refreshInterval: 3.0,
            Keys.hideSystemProcesses: true,
            Keys.showDocker: true,
            Keys.probeHealth: true,
            Keys.showCountInMenuBar: true,
            Keys.hotKeyEnabled: true,
            Keys.preferredEditor: "auto",
            Keys.preferredTerminal: "auto",
            Keys.hasSeenWelcome: false,
            Keys.remoteSharingEnabled: false,
            PolicyKey.enabled: true,
            PolicyKey.requireLANConfirm: true,
            PolicyKey.allowOutsideHome: false,
            PolicyKey.allowProtectedStop: false,
        ])
        refreshInterval = defaults.double(forKey: Keys.refreshInterval)
        hideSystemProcesses = defaults.bool(forKey: Keys.hideSystemProcesses)
        showDocker = Self.readBool(defaults, mdm: ManagedKey.showDocker, user: Keys.showDocker, fallback: true)
        probeHealth = Self.readBool(defaults, mdm: ManagedKey.probeHealth, user: Keys.probeHealth, fallback: true)
        showCountInMenuBar = Self.readBool(defaults, mdm: ManagedKey.showCountInMenuBar, user: Keys.showCountInMenuBar, fallback: true)
        hotKeyEnabled = Self.readBool(defaults, mdm: ManagedKey.hotKeyEnabled, user: Keys.hotKeyEnabled, fallback: true)
        preferredEditor = defaults.string(forKey: Keys.preferredEditor) ?? "auto"
        preferredTerminal = defaults.string(forKey: Keys.preferredTerminal) ?? "auto"
        hasSeenWelcome = defaults.bool(forKey: Keys.hasSeenWelcome)
        remoteSharingEnabled = Self.readBool(defaults, mdm: ManagedKey.remoteSharing, user: Keys.remoteSharingEnabled, fallback: false)
        policyEnabled = defaults.object(forKey: PolicyKey.enabled) as? Bool ?? true
        policyRequireLANConfirm = defaults.object(forKey: PolicyKey.requireLANConfirm) as? Bool ?? true
        policyAllowOutsideHome = defaults.bool(forKey: PolicyKey.allowOutsideHome)
        policyAllowProtectedStop = defaults.bool(forKey: PolicyKey.allowProtectedStop)
        policyAllowedRoots = defaults.stringArray(forKey: PolicyKey.allowedRoots) ?? []
    }

    private func write<T>(_ value: T, forKey key: String, managed extra: String? = nil) {
        if isManaged(key) { return }
        if let extra, isManaged(extra) { return }
        defaults.set(value, forKey: key)
    }

    private static func readBool(_ defaults: UserDefaults, mdm: String, user: String, fallback: Bool) -> Bool {
        if defaults.object(forKey: mdm) != nil { return defaults.bool(forKey: mdm) }
        if defaults.object(forKey: user) != nil { return defaults.bool(forKey: user) }
        return fallback
    }

    /// Process-name prefixes that are macOS plumbing, not something a developer started.
    nonisolated static let systemProcessPrefixes: [String] = [
        "rapportd", "ControlCenter", "sharingd", "launchd", "identityservicesd",
        "mDNSResponder", "AirPlayXPCHelper", "cupsd", "remoted", "netbiosd",
        "AMPDeviceDiscover", "UserEventAgent", "bluetoothd", "Music", "Finder",
        "Cursor Helper", "Code Helper", "Electron Helper",
    ]

    nonisolated static func isSystemProcess(_ command: String) -> Bool {
        let lower = command.lowercased()
        return systemProcessPrefixes.contains { lower.hasPrefix($0.lowercased()) }
    }

    private enum Keys {
        static let refreshInterval = "refreshInterval"
        static let hideSystemProcesses = "hideSystemProcesses"
        static let showDocker = "showDocker"
        static let probeHealth = "probeHealth"
        static let showCountInMenuBar = "showCountInMenuBar"
        static let hotKeyEnabled = "hotKeyEnabled"
        static let preferredEditor = "preferredEditor"
        static let preferredTerminal = "preferredTerminal"
        static let hasSeenWelcome = "hasSeenWelcome"
        static let remoteSharingEnabled = "remoteSharingEnabled"
    }
}
