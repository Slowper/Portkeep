import AppKit
import Observation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private(set) var statusBar: StatusBarController?
    private var hotKeyObservation: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusBarController(state: state)
        statusBar = controller

        HotKey.shared.onTrigger = { [weak controller] in controller?.toggle() }
        syncHotKey()
        observeHotKeySetting()

        if !state.settings.hasSeenWelcome {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                controller.show()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func syncHotKey() {
        if state.settings.hotKeyEnabled {
            HotKey.shared.register()
        } else {
            HotKey.shared.unregister()
        }
    }

    private func observeHotKeySetting() {
        hotKeyObservation?.cancel()
        hotKeyObservation = Task { [weak self] in
            while let self, !Task.isCancelled {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = self.state.settings.hotKeyEnabled
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { return }
                self.syncHotKey()
            }
        }
    }
}
