import SwiftUI

@main
struct PortkeepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Real Settings UI is an NSWindow we own. A SwiftUI Settings scene
        // never appears for an LSUIElement menu-bar app.
        Settings {
            EmptyView()
        }
    }
}
