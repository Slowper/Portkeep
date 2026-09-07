import SwiftUI

@main
struct PortsideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The menu bar item and panel are managed by StatusBarController.
        // SwiftUI only owns the Settings window.
        Settings {
            SettingsView()
                .environment(delegate.state)
        }
    }
}
