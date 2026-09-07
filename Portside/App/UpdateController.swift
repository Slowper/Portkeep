import Foundation
@preconcurrency import Sparkle

/// Sparkle updater. Background checks are on; install still goes through the
/// standard “Check for Updates…” sheet, same shape as macOS Software Update.
@MainActor
enum AppUpdates {
    private(set) static var controller: SPUStandardUpdaterController?

    static func start() {
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        if PortkeepDefaults.suite.objectIsForced(forKey: ManagedKey.autoUpdate) {
            controller?.updater.automaticallyChecksForUpdates = PortkeepDefaults.suite.bool(forKey: ManagedKey.autoUpdate)
        }
    }

    static func checkForUpdates() {
        start()
        controller?.checkForUpdates(nil)
    }

    static var automaticallyChecksForUpdates: Bool {
        get {
            if PortkeepDefaults.suite.objectIsForced(forKey: ManagedKey.autoUpdate) {
                return PortkeepDefaults.suite.bool(forKey: ManagedKey.autoUpdate)
            }
            return controller?.updater.automaticallyChecksForUpdates ?? true
        }
        set {
            guard !PortkeepDefaults.suite.objectIsForced(forKey: ManagedKey.autoUpdate) else { return }
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    static var updatesAreManaged: Bool {
        PortkeepDefaults.suite.objectIsForced(forKey: ManagedKey.autoUpdate)
    }
}
