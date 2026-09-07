import AppKit
import SwiftUI

/// Owns the Settings window. SwiftUI's `Settings` scene does not appear for
/// `LSUIElement` menu-bar apps — `showSettingsWindow:` is a no-op there.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()
    static let openNotification = Notification.Name("com.sajidpalagiri.portkeep.openSettings")

    private var hosting: NSHostingView<AnyView>?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Portkeep Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 480)
        window.identifier = NSUserInterfaceItemIdentifier("PortkeepSettings")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(state: AppState) {
        let root = AnyView(
            SettingsView()
                .environment(state)
                .frame(minWidth: 640, minHeight: 480)
        )
        if let hosting {
            hosting.rootView = root
        } else {
            let view = NSHostingView(rootView: root)
            view.sizingOptions = [.minSize]
            hosting = view
            window?.contentView = view
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.setContentSize(NSSize(width: 720, height: 560))
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            let other = NSApp.windows.contains {
                $0 !== self.window && $0.isVisible && $0.canBecomeKey && !($0 is FloatingPanel)
            }
            if !other {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
