import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Owns the status item and the floating panel; the glue between AppKit's
/// menu bar and the SwiftUI panel content.
@MainActor
final class StatusBarController: NSObject {
    /// Visible width of the glass panel.
    static let panelWidth: CGFloat = 420
    private static let panelGap: CGFloat = 6
    /// Transparent margin around the visible panel (hosts the drop shadow).
    private static var margin: CGFloat { PanelRootView.shadowMargin }
    private static var windowWidth: CGFloat { panelWidth + margin * 2 }

    private let state: AppState
    private let statusItem: NSStatusItem
    private let panel: FloatingPanel
    private let hostingView: NSHostingView<AnyView>

    private var outsideClickMonitor: Any?
    private var insideClickMonitor: Any?
    private var keyMonitor: Any?
    private var spaceObserver: NSObjectProtocol?
    private var observationTask: Task<Void, Never>?
    /// Window height including the shadow margin.
    private var desiredHeight: CGFloat = 200 + PanelRootView.shadowMargin * 2

    private(set) var isShown = false

    init(state: AppState) {
        self.state = state
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 200 + Self.margin * 2))

        let root = PanelRootView()
            .environment(state)
        hostingView = NSHostingView(rootView: AnyView(root))
        hostingView.sizingOptions = []
        super.init()

        panel.contentView = hostingView
        configureStatusItem()

        state.dismissPanel = { [weak self] in self?.hide() }
        state.openSettingsWindow = { [weak self] in self?.openSettings() }

        installPreferredHeightObserver()
        observeMenuBarCount()
    }

    // MARK: - Status item

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let image = NSImage(systemSymbolName: "point.3.filled.connected.trianglepath.dotted", accessibilityDescription: "Portside")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image
        let count = state.menuBarCount
        button.title = (state.settings.showCountInMenuBar && count > 0) ? " \(count)" : ""
        button.toolTip = count == 1 ? "1 dev port listening" : "\(count) dev ports listening"
    }

    private func observeMenuBarCount() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = self.state.menuBarCount
                        _ = self.state.settings.showCountInMenuBar
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { return }
                self.updateStatusItem()
            }
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            toggle()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh", action: #selector(refreshAction), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(settingsAction), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Portside", action: #selector(quitAction), keyEquivalent: "q").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshAction() { Task { await state.refresh() } }
    @objc private func settingsAction() { openSettings() }
    @objc private func quitAction() { state.quit() }

    // MARK: - Show / hide

    func toggle() {
        isShown ? hide() : show()
    }

    func show() {
        guard !isShown else { return }
        isShown = true
        statusItem.button?.highlight(true)

        let target = targetFrame(height: desiredHeight)
        var start = target
        start.origin.y += 8
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }

        installMonitors()
        state.panelDidAppear()
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        statusItem.button?.highlight(false)
        removeMonitors()
        state.panelDidDisappear()

        var end = panel.frame
        end.origin.y += 6
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(end, display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isShown else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    // MARK: - Geometry

    /// Window frame for a window of `height` (which includes the margins), such
    /// that the *visible* panel is centred under the status item with a small gap.
    private func targetFrame(height: CGFloat) -> NSRect {
        let width = Self.windowWidth
        let margin = Self.margin
        guard let button = statusItem.button, let buttonWindow = button.window else {
            let screen = NSScreen.main?.visibleFrame ?? .zero
            return NSRect(x: screen.midX - width / 2, y: screen.maxY - height + margin, width: width, height: height)
        }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? buttonFrame

        var x = buttonFrame.midX - width / 2
        x = min(max(x, visible.minX + 8 - margin), visible.maxX - width - 8 + margin)
        let y = buttonFrame.minY - Self.panelGap - height + margin
        return NSRect(x: x, y: max(y, visible.minY + 8 - margin), width: width, height: height)
    }

    /// The visible panel's rect in window coordinates.
    private var visibleContentRect: NSRect {
        panel.frame.insetBy(dx: Self.margin, dy: Self.margin).offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
    }

    private func installPreferredHeightObserver() {
        // The SwiftUI root reports its ideal height through a notification;
        // we animate the window to match, keeping the top edge anchored.
        NotificationCenter.default.addObserver(forName: .panelPreferredHeightDidChange, object: nil, queue: .main) { [weak self] note in
            guard let height = note.userInfo?["height"] as? CGFloat else { return }
            Task { @MainActor in self?.applyHeight(height) }
        }
    }

    private func applyHeight(_ height: CGFloat) {
        let clamped = max(120 + Self.margin * 2, height)
        guard abs(clamped - desiredHeight) > 0.5 else { return }
        desiredHeight = clamped
        guard isShown else { return }
        let target = targetFrame(height: clamped)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    // MARK: - Monitors

    private func installMonitors() {
        removeMonitors()

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.state.isPinned else { return }
                self.hide()
            }
        }

        // Clicks inside our own app but outside the visible panel: another of
        // our windows, or the transparent shadow margin around the glass.
        insideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, !self.state.isPinned else { return event }
            if event.window === self.panel {
                if !self.visibleContentRect.contains(event.locationInWindow) {
                    self.hide()
                    return nil
                }
            } else if event.window !== self.statusItem.button?.window {
                self.hide()
            }
            return event
        }

        // Switching Spaces or full-screen apps should dismiss the panel.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.state.isPinned else { return }
                self.hide()
            }
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func removeMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let insideClickMonitor { NSEvent.removeMonitor(insideClickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        outsideClickMonitor = nil
        insideClickMonitor = nil
        keyMonitor = nil
        self.spaceObserver = nil
    }

    /// Returns true if the event was consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch Int(event.keyCode) {
        case kVK_DownArrow:
            state.moveSelection(by: 1); return true
        case kVK_UpArrow:
            state.moveSelection(by: -1); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if state.showPaywall { return false }
            state.activateSelection(); return true
        case kVK_Escape:
            if state.showPaywall { state.showPaywall = false; return true }
            if state.pendingStopID != nil { state.cancelPendingStop(); return true }
            if !state.query.isEmpty { state.query = ""; return true }
            hide(); return true
        case kVK_Delete where command:
            state.stopSelection(); return true
        default:
            break
        }

        guard command else { return false }
        switch key {
        case "c" where state.query.isEmpty && state.selectedRowID != nil:
            state.copySelection(); return true
        case "r":
            Task { await state.refresh() }; return true
        case ",":
            openSettings(); return true
        case "q":
            state.quit(); return true
        case "p":
            state.isPinned.toggle(); return true
        default:
            return false
        }
    }

    // MARK: - Settings

    func openSettings() {
        hide()
        NSApp.activate(ignoringOtherApps: true)
        // SettingsLink does this under the hood; works for SwiftUI `Settings` scenes on macOS 14+.
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}

extension Notification.Name {
    static let panelPreferredHeightDidChange = Notification.Name("PortsidePanelPreferredHeightDidChange")
}
