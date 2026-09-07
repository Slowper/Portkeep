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
        didSet { defaults.set(showDocker, forKey: Keys.showDocker) }
    }

    /// Probe ports over HTTP to show status codes and latency.
    var probeHealth: Bool {
        didSet { defaults.set(probeHealth, forKey: Keys.probeHealth) }
    }

    var showCountInMenuBar: Bool {
        didSet { defaults.set(showCountInMenuBar, forKey: Keys.showCountInMenuBar) }
    }

    var hotKeyEnabled: Bool {
        didSet { defaults.set(hotKeyEnabled, forKey: Keys.hotKeyEnabled) }
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

    init(defaults: UserDefaults = .standard) {
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
        ])
        refreshInterval = defaults.double(forKey: Keys.refreshInterval)
        hideSystemProcesses = defaults.bool(forKey: Keys.hideSystemProcesses)
        showDocker = defaults.bool(forKey: Keys.showDocker)
        probeHealth = defaults.bool(forKey: Keys.probeHealth)
        showCountInMenuBar = defaults.bool(forKey: Keys.showCountInMenuBar)
        hotKeyEnabled = defaults.bool(forKey: Keys.hotKeyEnabled)
        preferredEditor = defaults.string(forKey: Keys.preferredEditor) ?? "auto"
        preferredTerminal = defaults.string(forKey: Keys.preferredTerminal) ?? "auto"
        hasSeenWelcome = defaults.bool(forKey: Keys.hasSeenWelcome)
    }

    /// Process-name prefixes that are macOS plumbing, not something a developer started.
    static let systemProcessPrefixes: [String] = [
        "rapportd", "ControlCenter", "sharingd", "launchd", "identityservicesd",
        "mDNSResponder", "AirPlayXPCHelper", "cupsd", "remoted", "netbiosd",
        "AMPDeviceDiscover", "UserEventAgent", "bluetoothd", "Music", "Finder",
        "Cursor Helper", "Code Helper", "Electron Helper",
    ]

    static func isSystemProcess(_ command: String) -> Bool {
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
    }
}
