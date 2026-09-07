import AppKit

struct ExternalApp: Identifiable, Hashable, Sendable {
    let id: String   // bundle identifier
    let name: String
}

/// Opens project folders in the developer's editor and terminal of choice.
@MainActor
enum EditorLauncher {
    static let knownEditors: [ExternalApp] = [
        ExternalApp(id: "com.todesktop.230313mzl4w4u92", name: "Cursor"),
        ExternalApp(id: "com.microsoft.VSCode", name: "Visual Studio Code"),
        ExternalApp(id: "dev.zed.Zed", name: "Zed"),
        ExternalApp(id: "com.jetbrains.WebStorm", name: "WebStorm"),
        ExternalApp(id: "com.jetbrains.intellij", name: "IntelliJ IDEA"),
        ExternalApp(id: "com.sublimetext.4", name: "Sublime Text"),
        ExternalApp(id: "com.panic.Nova", name: "Nova"),
        ExternalApp(id: "com.apple.dt.Xcode", name: "Xcode"),
    ]

    static let knownTerminals: [ExternalApp] = [
        ExternalApp(id: "com.mitchellh.ghostty", name: "Ghostty"),
        ExternalApp(id: "dev.warp.Warp-Stable", name: "Warp"),
        ExternalApp(id: "com.googlecode.iterm2", name: "iTerm"),
        ExternalApp(id: "net.kovidgoyal.kitty", name: "kitty"),
        ExternalApp(id: "io.alacritty", name: "Alacritty"),
        ExternalApp(id: "com.apple.Terminal", name: "Terminal"),
    ]

    static func installed(from candidates: [ExternalApp]) -> [ExternalApp] {
        candidates.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }

    static var installedEditors: [ExternalApp] { installed(from: knownEditors) }
    static var installedTerminals: [ExternalApp] { installed(from: knownTerminals) }

    /// Resolves the preferred app, falling back to the first installed candidate.
    static func resolve(preferred: String, among candidates: [ExternalApp]) -> ExternalApp? {
        if preferred != "auto", let match = candidates.first(where: { $0.id == preferred }),
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: match.id) != nil {
            return match
        }
        return installed(from: candidates).first
    }

    static func open(_ directory: URL, with app: ExternalApp) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([directory], withApplicationAt: appURL, configuration: config)
    }
}
