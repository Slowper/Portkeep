import Foundation

enum CLIInstallError: LocalizedError {
    case binaryMissing
    case destinationUnwritable(URL)

    var errorDescription: String? {
        switch self {
        case .binaryMissing:
            "Couldn't find the \(Product.cliName) binary. Rebuild the app, then try again."
        case .destinationUnwritable(let url):
            "Can't write to \(url.path). Create the folder or pick another destination."
        }
    }
}

/// Copies `portkeep` onto the user's PATH so agents and shells can call it.
enum CLIInstall {
    static let binaryName = Product.cliName

    static var defaultDestination: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".local/bin/\(binaryName)")
    }

    static func installedURL() -> URL? {
        let fm = FileManager.default
        let candidates = [
            defaultDestination,
            URL(fileURLWithPath: "/opt/homebrew/bin/\(binaryName)"),
            URL(fileURLWithPath: "/usr/local/bin/\(binaryName)"),
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    static func isOnPATH() -> Bool {
        installedURL() != nil
    }

    /// The CLI binary next to this process, or inside Portkeep.app.
    static func bundledBinary() -> URL? {
        let fm = FileManager.default
        if let fromArg = bundledFromLaunchPath() { return fromArg }

        let bundle = Bundle.main.bundleURL
        let helpers = bundle.appendingPathComponent("Contents/Helpers/\(binaryName)")
        if fm.isExecutableFile(atPath: helpers.path) { return helpers }
        let insideApp = bundle.appendingPathComponent("Contents/MacOS/\(binaryName)")
        if fm.isExecutableFile(atPath: insideApp.path), insideApp.lastPathComponent != Bundle.main.executableURL?.lastPathComponent {
            return insideApp
        }

        let sibling = bundle.deletingLastPathComponent().appendingPathComponent(binaryName)
        if fm.isExecutableFile(atPath: sibling.path) { return sibling }
        return nil
    }

    static func install(to destination: URL = defaultDestination) throws -> URL {
        guard let source = bundledBinary() else { throw CLIInstallError.binaryMissing }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        do {
            try fm.copyItem(at: source, to: destination)
        } catch {
            throw CLIInstallError.destinationUnwritable(destination)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return destination
    }

    static func uninstall() throws {
        guard let url = installedURL() else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func bundledFromLaunchPath() -> URL? {
        let launch = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let name = launch.lastPathComponent
        if name == binaryName, FileManager.default.isExecutableFile(atPath: launch.path) {
            return launch
        }
        return nil
    }
}
