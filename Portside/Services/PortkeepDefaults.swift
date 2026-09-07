import Foundation

/// Shared preference domain for the app, CLI, and MDM.
/// Jamf / Kandji must push this domain — `com.sajidpalagiri.portkeep.cli` is ignored.
enum PortkeepDefaults {
    static let domain = "com.sajidpalagiri.portkeep"

    static var suite: UserDefaults {
        UserDefaults(suiteName: domain) ?? .standard
    }
}

/// Keys IT can force. Forced keys appear locked in Settings (`defaults.objectIsForced`).
enum ManagedKey {
    static let showDocker = "ShowDocker"
    static let hotKeyEnabled = "HotKeyEnabled"
    static let probeHealth = "ProbeHealth"
    static let showCountInMenuBar = "ShowCountInMenuBar"
    static let autoUpdate = "AutomaticallyCheckForUpdates"
    static let orgLicense = "OrgLicense"
    static let orgName = "OrgName"
    static let orgSeats = "OrgSeats"
    static let remoteSharing = "RemoteSharingEnabled"

    static let all: [(key: String, meaning: String)] = [
        (PolicyKey.enabled, "Refuse dangerous stops"),
        (PolicyKey.requireLANConfirm, "Confirm before stopping LAN / 0.0.0.0 binds"),
        (PolicyKey.allowOutsideHome, "Allow stops outside the home folder"),
        (PolicyKey.allowProtectedStop, "Allow stopping postgres / redis / ollama (break-glass)"),
        (PolicyKey.allowedRoots, "Extra folders stops may touch (array of paths)"),
        (PolicyKey.protectedNames, "Extra process names that must not be killed"),
        (showDocker, "Show Docker containers in the panel"),
        (hotKeyEnabled, "Global shortcut ⌃⌥P"),
        (probeHealth, "HTTP-probe localhost ports"),
        (showCountInMenuBar, "Show the listening-port count in the menu bar"),
        (autoUpdate, "Daily Sparkle update check"),
        (orgLicense, "Forced org / personal license key"),
        (orgName, "Organization display name"),
        (orgSeats, "Purchased seat count (informational if the key already encodes it)"),
        (remoteSharing, "Advertise this Mac on the LAN so other Portkeeps can see leftovers"),
    ]
}
