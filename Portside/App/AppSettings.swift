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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.refreshInterval: 3.0,
            Keys.hideSystemProcesses: true,
            Keys.showDocker: true,
        ])
        refreshInterval = defaults.double(forKey: Keys.refreshInterval)
        hideSystemProcesses = defaults.bool(forKey: Keys.hideSystemProcesses)
        showDocker = defaults.bool(forKey: Keys.showDocker)
    }

    /// Process-name prefixes that are macOS plumbing, not something a developer started.
    static let systemProcessPrefixes: [String] = [
        "rapportd", "ControlCenter", "sharingd", "launchd", "identityservicesd",
        "mDNSResponder", "AirPlayXPCHelper", "cupsd", "remoted", "netbiosd",
        "AMPDeviceDiscover", "UserEventAgent", "bluetoothd", "Music", "Finder",
    ]

    static func isSystemProcess(_ command: String) -> Bool {
        let lower = command.lowercased()
        return systemProcessPrefixes.contains { lower.hasPrefix($0.lowercased()) }
    }

    private enum Keys {
        static let refreshInterval = "refreshInterval"
        static let hideSystemProcesses = "hideSystemProcesses"
        static let showDocker = "showDocker"
    }
}
