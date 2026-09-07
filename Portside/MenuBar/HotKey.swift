import AppKit
import Carbon.HIToolbox

/// Global keyboard shortcut via Carbon. Unlike NSEvent global monitors this
/// works without Accessibility permission and actually consumes the key.
@MainActor
final class HotKey {
    static let shared = HotKey()

    /// Default: ⌃⌥P
    static let defaultKeyCode = UInt32(kVK_ANSI_P)
    static let defaultModifiers = UInt32(controlKey | optionKey)
    static let displayString = "⌃⌥P"

    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    func register() {
        unregister()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in HotKey.shared.onTrigger?() }
            return noErr
        }, 1, &eventType, nil, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: 0x504B_4550 /* 'PKEP' */, id: 1)
        RegisterEventHotKey(Self.defaultKeyCode, Self.defaultModifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}
